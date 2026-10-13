#!/system/bin/sh
# ============================================================
#  bigcore_guard.sh —— 按前台应用动态冻结 OptExt 根组，限制 8-9 超大核
# ------------------------------------------------------------
#  规则（与用户约定一致）：
#        · 游戏        → 解冻 OptExt 根组（effective 恢复 0-9，游戏/none 可上 8-9）
#        · 线程管理里明确定义「不接管(none)」的应用 → 解冻（放行 8-9）
#        · 其余一切（含桌面/输入法/系统UI/未配置/接管非游戏）→ 冻结根组到 0-7
#
#  ⚠ 关键真机事实（final834 实测 + probe_optext 验证）：
#    aether 的自建 OptExt 子树：根组 cpus=0-9，子组各自 cpus（8-9/0-9/0-3,8-9/4-9）。
#    cpuset 的 effective_cpus = 与所有祖先取交集。故**只冻 OptExt 根组 cpus=0-7**，
#    整棵子树的 effective 立即变成 0-7（一次写压住全部，不动 aether 落核逻辑）。
#    解冻根组 → effective 恢复 0-9，游戏/none 正常上 8-9。
#
#  开销（满足「限制 0-7 不增显著开销」底线）：
#    · 稳态：仅一次 cat 比对根组当前值，值未变零写入。
#    · 仅在前台从 free→lock 切换瞬间，才把当前残留 8-9 线程迁回 0-7 一次；
#      lock→free 切换瞬间解冻根组一次。稳定态零动作。
#
#  用法：
#        bigcore_guard.sh guard <前台包名>   进每轮亮屏 tick 调用
#        bigcore_guard.sh restore            解冻并恢复原值（不用重启）
#  关闭：touch $STATE_DIR/allow_bigcore
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
STATE_DIR="${STATE_DIR:-/data/adb/O3CPUSet}"

log_quiet() { :; }
[ -f "$MODDIR/lib/util.sh" ] && . "$MODDIR/lib/util.sh" 2>/dev/null
command -v log_quiet >/dev/null 2>&1 || log_quiet(){ :; }

OPTEXT_ROOT="/dev/cpuset/OptExt"
INTENT="$STATE_DIR/bigcore.intent"
FROZEN_CPUS="0-7"
OPEN_CPUS="0-9"
GAMLIST="/sdcard/Android/Aether/gamelist"
ALLOWLIST="$STATE_DIR/bigcore.allow"
UNFREEZE_MARK="$STATE_DIR/bigcore.unfrozen"

if [ -f "$STATE_DIR/allow_bigcore" ]; then
    echo "SKIP allow_bigcore 存在，跳过 8-9 封锁"
    exit 0
fi

# 根组是否含 8/9
root_has_big() {
    case "$(cat "$OPTEXT_ROOT/cpus" 2>/dev/null)" in *8*|*9*) return 0 ;; *) return 1 ;; esac
}

# ---- 生成放行名单（none 不接管 + 游戏），首建/缓存丢失时调用 ----
build_allowlist() {
    : > "$ALLOWLIST"
    # ① 线程管理中定义为 none（apprules.tsv 的 other 核位含 8/9）
    if [ -f "$STATE_DIR/apprules.tsv" ]; then
        awk -F'\t' 'NF>=2 && $2 ~ /[89]/ {print $1}' "$STATE_DIR/apprules.tsv" >> "$ALLOWLIST" 2>/dev/null
    fi
    # ② 游戏名单
    [ -f "$GAMLIST" ] && cat "$GAMLIST" >> "$ALLOWLIST" 2>/dev/null
    sort -u "$ALLOWLIST" 2>/dev/null -o "$ALLOWLIST"
}

# ---- 前台分类：free（放行）/ lock（冻结）----
fg_classify() {
    local pkg="$1"
    if [ -s "$ALLOWLIST" ] && grep -qx "$pkg" "$ALLOWLIST" 2>/dev/null; then
        echo free; return
    fi
    echo lock
}

# ---- 把当前在 OptExt 含 8/9 组里的线程迁回 0-7（仅切换瞬间跑一次）----
drain_big() {
    local src pf snap t
    for src in 8-9 0-9 0-3,8-9 4-9; do
        pf="$OPTEXT_ROOT/$src/cgroup.procs"
        [ -r "$pf" ] || continue
        snap="/data/local/tmp/_bc_drain"
        cp "$pf" "$snap" 2>/dev/null || continue
        while read -r t; do
            [ -n "$t" ] && [ -d "/proc/$t" ] && \
                echo "0-7" > "$OPTEXT_ROOT/0-7/cgroup.procs" 2>/dev/null
        done < "$snap"
    done
}

cmd_guard() {
    local fg="$1" cls
    # 前台为空（锁屏/抓不到）→ 保持上一轮状态，不误冻也不误解冻
    [ -z "$fg" ] && { log_quiet "bigcore: 前台为空，保持现状"; return 0; }
    [ ! -s "$ALLOWLIST" ] && build_allowlist
    cls=$(fg_classify "$fg")

    if [ "$cls" = "free" ]; then
        # 解冻根组（放行 8-9）。仅在当前是冻结态时才写，避免每轮零意义重写
        if root_has_big; then :; else
            echo "$OPEN_CPUS" > "$OPTEXT_ROOT/cpus" 2>/dev/null
            log_quiet "bigcore: 根组解冻 -> $OPEN_CPUS（前台 $fg 放行 8-9）"
        fi
        rm -f "$UNFREEZE_MARK"
    else
        # 冻结根组到 0-7。仅在当前含 8/9 时才写
        if root_has_big; then
            echo "$FROZEN_CPUS" > "$OPTEXT_ROOT/cpus" 2>/dev/null
            log_quiet "bigcore: 根组冻结 -> $FROZEN_CPUS（前台 $fg 限 0-7）"
            drain_big   # 切换瞬间把残留 8-9 线程迁回一次
        fi
        touch "$UNFREEZE_MARK"
    fi
    echo "$cls" > "$INTENT" 2>/dev/null
}

cmd_restore() {
    echo "$OPEN_CPUS" > "$OPTEXT_ROOT/cpus" 2>/dev/null
    rm -f "$INTENT" "$ALLOWLIST" "$UNFREEZE_MARK"
    echo "OK 已解冻 OptExt 根组到 $OPEN_CPUS（不用重启）"
}

# 开机/首启：默认冻结（除非当前前台就是放行类，由 guard 首轮纠正）
cmd_boot() {
    [ ! -s "$ALLOWLIST" ] && build_allowlist
    echo "$FROZEN_CPUS" > "$OPTEXT_ROOT/cpus" 2>/dev/null
    log_quiet "bigcore: 开机默认冻结 OptExt 根组 -> $FROZEN_CPUS"
}

case "$1" in
    guard) cmd_guard "$2" ;;
    restore) cmd_restore ;;
    boot)  cmd_boot ;;
    *) echo "usage: bigcore_guard.sh guard <fg_pkg> | restore | boot" ;;
esac
