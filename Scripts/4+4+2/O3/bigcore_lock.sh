#!/system/bin/sh
# ============================================================
#  bigcore_lock —— 常态锁掉超大核 8-9，仅「游戏 / 不接管」应用放行
# ------------------------------------------------------------
#  【为什么需要它】
#    舰长引擎（aether-optext）会把前台应用的渲染线程「保护性提升」到 8-9，
#    实测普通应用（小红书 95 次 / 小爱 57 次 / B站 52 次 …）也被提升，
#    日用纯耗电。引擎的该行为是二进制内硬编码，无法通过 features 关闭
#    （实测关掉全部 5 个特性后 8-9 组仍有残留进程）。
#
#  【为什么必须是「组级 + 周期清扫」，不能只迁进程】
#    v18.3.2 起改成「把前台进程迁进自有锁核组」，实测**失效**：
#      · 引擎的落核是**逐线程** cgroup 迁移（写 /dev/cpuset/OptExt/<g>/tasks），
#        不是 taskset —— 进程在 locked 组里，它的线程照样被引擎单独拎去 8-9；
#      · 收窄 OptExt 子组的 cpus 会被引擎**重建**（实测 mtime 持续变化）；
#      · 收窄 /dev/cpuset 根组失败（rc=1，子组占着 8-9，cpuset 要求 child⊆parent）；
#      · bind-mount 冻结 OptExt 无效（引擎另建了名为 cpus/mems 的组）。
#    ⇒ 唯一稳的做法：**接受「引擎会写 8-9」，但我们周期性把 8-9 组里的线程
#      扫回来。** 白名单外的应用在线程进入 8-9 后 ≤1 个 tick 被拉回 0-7；
#      白名单内（游戏/不接管）不动。
#
#  【策略（用户 2026-10-10 定，v18.3.6 修订）】
#    · **只拦「独占超大核」**：线程 Cpus_allowed_list 只含 8/9（8 / 9 / 8-9）
#      → 扫回 OptExt/0-7
#    · 混合形态（4-9 / 0-9 / 0-3,8-9 / 2-9）→ **一律放过**
#      （用户原话：「艇长的生核如果是增加 8~9 核，比如线程还是 4~9 → 没问题，
#        可以不用解决。但如果是这个线程只使用 8 到 9 核心，那就绝对不可以。」）
#    · 白名单（游戏 / 不接管）→ 独占也放行
#    · 内核线程 / 无 cmdline → 一律保留（单核算力线程，动不得）
#    · 系统关键进程 → 不锁（SKIP_EXACT / 系统路径），避免误伤
#
#  【v18.3.5 的过度执行（已修）】
#    v18.3.5 的判据是「所在组的 cpus 含 8/9」，把混合形态也扫了 ——
#    实测 4096 个混合线程被反复扫回，白烧 CPU 且砍掉了引擎
#    「中核 ∪ 超大核」的合理分配。v18.3.6 改成看线程**自己**的亲和性。
#
#  【开销】
#    · 前台变化：迁进程（幂等，已在目标组则不发命令）
#    · 每 tick（5s）：扫一遍 OptExt 里含 8/9 的组的 tasks，白名单外的写回 0-7。
#      用「读快照 + 只写需要写的」实现，稳态下几乎零写入。
#
#  用法: bigcore_lock.sh            按当前前台应用执行一次（守护每 WORK 轮调用）
#        bigcore_lock.sh sweep       只做 8-9 组清扫（守护每 tick 调用）
#        bigcore_lock.sh status     打印自有组与成员（只读）
#        bigcore_lock.sh release    解组：成员迁回系统组并删组（卸载/停用时用）
#        bigcore_lock.sh <pkg>      对指定包执行一次（调试用）
#  关闭: touch $STATE_DIR/allow_bigcore
#  离线测试覆写: CG_ROOT / STATE_DIR / TMPD
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
. "$MODDIR/lib/util.sh"

CG_ROOT="${CG_ROOT:-/dev/cpuset}"
ST="${STATE_DIR:-/data/adb/O3CPUSet}"
TARGET="${TARGET:-/sdcard/Android/Aether}"   # 舰长配置目录（gamelist 在这）
OUR="O3CPUSet"                      # 自有组名（与引擎的 OptExt 区分）
LOCK="$CG_ROOT/$OUR/locked"         # 锁核组：cpus=0-7
SAFE="$CG_ROOT/OptExt/0-7"          # 引擎侧的安全落点（不含 8/9）
LOG="$ST/bigcore_lock.log"
OFF="$ST/allow_bigcore"
BIG="${BIG_CORES:-8-9}"             # 被锁的超大核
TOP_CORES="${TOP_CORES:-0-7}"       # 锁核组允许的核位

[ -f "$OFF" ] && exit 0

logq() { log_quiet "bigcore_lock: $*"; }

# 当前前台包名（与 guard.sh 同口径：跳过 =null 行取第一个非空）
fg_pkg() {
    dumpsys window 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *mCurrentFocus=Window*)
            case "$line" in
              *'=null'*) continue ;;
            esac
            _w=${line#*mCurrentFocus=Window\{}
            _w=${_w#* }          # 去掉 hash
            _w=${_w#* }          # 去掉 u0
            _w=${_w%%/*}
            printf '%s\n' "$_w"; return 0 ;;
        esac
    done | head -1
}

# 该包是否「允许用超大核」：游戏档 / 不接管档 / 规则本身含 8-9
#   判定依据（任一命中即放行）：
#     ① 引擎 OVR 覆盖表里的角色 = game / none
#     ② 舰长 gamelist 成员（引擎认定的游戏）
#     ③ 「允许大核包名表」命中 —— 由 aether_ctl deploy 时预生成，
#        收录所有「规则 cpuset 含 8-9/0-9」的包（如相机的「不接管」= 0-9）。
#        ⚠ 运行时热路径（每次前台变化都跑），绝不做逐块 awk 解析 CFG；
#        查表是 1 次 grep，开销可忽略。
#   ⚠ v18.3.5：③ 的 allow 表是「全量规则表」，天然包含日常应用（相机的
#      「不接管」= 0-9、部分第三方 App 的规则也含 4-9/0-9）。直接用它当
#      白名单会把美团/淘宝/桌面也放上 8-9 —— 实测确实如此（166 条里大部分
#      是日常应用）。因此 ③ 降级为**只在规则明确含 8-9** 时采信，且被
#      游戏名单 + OVR 优先覆盖；同时白名单命中后仍要过「游戏特征」复核。
ALLOW_LIST="$ST/bigcore_allow.txt"

# 该包名是否「像游戏」——用于复核 allow 表命中，防止日常应用被误放行。
#   依据：舰长 gamelist（316 条，引擎自己认定的游戏）是第一权威；
#   其次是包名常见游戏特征（仅作 gamelist 未收录时的兜底）。
GAMELIST="$TARGET/gamelist"
pkg_is_game() {
    local pkg="$1"
    case "$pkg" in
      com.miHoYo.*|com.mihoyo.*|com.HoYoverse.*|com.tencent.tmgp.*|com.tencent.ig*|\
      com.netease.*|com.hypergryph.*|com.papegames.*|com.kurogame.*|com.lilithgames.*|\
      com.supercell.*|com.gameloft.*|com.garena.*|com.bilibili.fatego|com.mojang.*|\
      com.nexon.*|com.cygames.*|jp.co.craftegg.*|com.chillyroom.*|com.hermes.*|\
      com.turbochilli.*|com.neowizgames.*|com.humble.*|com.jiguang.*|com.shenlan.*|\
      com.hottagames.*|com.minitech.*|com.Sunborn.*|com.xd.xdt|com.gamamobi.*|\
      com.idreamsky.*|com.yongshi.*|com.mingzhou.*|com.pwrd.*|com.rekoo.*|\
      com.duoyi.*|com.ztgame.*|com.soulgamechst.*|com.seayoo.*|com.sofunny.*|\
      com.roamingstar.*|com.RoamingStar.*|com.proxima.*|com.tencent.nikke|\
      com.tencent.mf.uam|com.tencent.shootgame|com.levelinfinite.*|com.gof.china|\
      com.axlebolt.*|com.dragonli.*|com.gaijingames.*|com.dfjz.*|com.sqw.cc*|\
      com.hykb.*|com.yinhan.*|com.lanjing.*|com.xuejing.*|com.yingxiong.*|\
      com.pi.czrxd*|com.nd.he.*|com.k7k7.*|com.pubg.*|com.tencent.KiHan|\
      com.tencent.jkchess|com.tencent.lolm|com.tencent.nrc|com.tencent.rmcn|\
      com.tencent.ngr|com.roblox.*|com.qqgame.*|com.dw.*|com.futuremark.*) return 0 ;;
    esac
    return 1
}

allow_big_for() {
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    # ① 用户自定义角色 = game / none → 放行（用户在 WebUI 显式选的，最高优先）
    if [ -s "$OVR" ]; then
        local r
        r=$(awk -F'\t' -v P="$pkg" '$1==P{print $2; exit}' "$OVR" 2>/dev/null)
        case "$r" in game|none) return 0 ;; esac
    fi
    # ② 舰长 gamelist 成员 → 放行（引擎认定的游戏）
    #    ⚠ gamelist 是 **CRLF** 换行，必须剥掉 \r 再比，否则 grep -qx 永远匹配不上。
    if [ -s "$GAMELIST" ]; then
        if tr -d '\r' < "$GAMELIST" 2>/dev/null | grep -qx "$pkg" 2>/dev/null; then return 0; fi
    fi
    # ③ allow 表命中 + 游戏特征复核（防止日常应用被误放行）
    if [ -s "$ALLOW_LIST" ] && grep -qx "$pkg" "$ALLOW_LIST" 2>/dev/null; then
        pkg_is_game "$pkg" && return 0
        return 1
    fi
    return 1
}

ensure_group() {
    [ -d "$LOCK" ] && return 0
    mkdir -p "$LOCK" 2>/dev/null || return 1
    printf '%s' "$TOP_CORES" > "$LOCK/cpus" 2>/dev/null || return 1
    [ -w "$LOCK/mems" ] && printf '0' > "$LOCK/mems" 2>/dev/null
    chmod 0755 "$CG_ROOT/$OUR" 2>/dev/null
    logq "已建锁核组 $OUR/locked（cpus=$TOP_CORES，锁 $BIG）"
    return 0
}

# 把某进程迁进锁核组（幂等：已在组内则不发命令）
lock_pid() {
    local pid="$1"
    [ -d "/proc/$pid" ] || return 0
    local cur
    cur=$(grep cpuset "/proc/$pid/cgroup" 2>/dev/null | cut -d: -f3)
    case "$cur" in "$LOCK"|*"/$OUR/locked") return 0 ;; esac
    printf '%s' "$pid" > "$LOCK/cgroup.procs" 2>/dev/null
}

# 把某进程从锁核组放回系统组（按 oom_score_adj 选 top-app / foreground）
unlock_pid() {
    local pid="$1"
    [ -d "/proc/$pid" ] || return 0
    local cur
    cur=$(grep cpuset "/proc/$pid/cgroup" 2>/dev/null | cut -d: -f3)
    case "$cur" in *"/$OUR/locked") ;; *) return 0 ;; esac
    local adj dest
    adj=$(awk '{print $9}' "/proc/$pid/stat" 2>/dev/null)
    dest="$CG_ROOT/foreground"
    case "$adj" in ''|*[!0-9-]*) ;; *) [ "$adj" -le 100 ] 2>/dev/null && dest="$CG_ROOT/top-app" ;; esac
    [ -w "$dest/cgroup.procs" ] || dest="$CG_ROOT/foreground"
    printf '%s' "$pid" > "$dest/cgroup.procs" 2>/dev/null
}

# 不该被扫的进程（系统关键服务 / 本模块自身 / 引擎）—— 扫它们可能引发异常
# ⚠ v18.3.5：原来用「子串通配」匹配整条 cmdline，实测把
#    `com.xiaomi.xmsf` / `com.miui.securitycenter:ui` 这类普通应用也匹配上了
#    （`*surfaceflinger*` 之类命中不了，但 `*android.hardware*` / `*system_server*`
#    会误伤）。改为**按主进程名精确前缀 + 只对真正的系统路径生效**：
#      · cmdline 含空格分隔多个 argv 的（native 服务）：保持子串通配
#      · 普通 Android 应用（单段包名）：只认「整段等于」or 位于 /system 下的守护
SKIP_WORDS="${SKIP_WORDS:-O3CPUSet aether-optext guard.sh bigcore_lock zn- zn-zygisk zn-daemon zn-companion zn-nsdaemon zygisk lsposed metric_server vd_serv surfaceflinger system_server hwcomposer}"
# 这些是「整段包名必须完全相等」才跳过（避免子串误伤）
SKIP_EXACT="${SKIP_EXACT:-zygote64 zygote zygote32 webview_zygote usap64 sui sui_shell system}"

is_skip() {   # $1=cmdline 第一段（可能是包名，也可能是 native 路径）
    local c="$1" w
    # ① 整段相等
    for w in $SKIP_EXACT; do
        [ "$c" = "$w" ] && return 0
    done
    # ② 系统/vendor 路径下的 native 服务（含空格多 argv）
    case "$c" in
      /system/*|/vendor/*|/apex/*)
        for w in $SKIP_WORDS; do
            case "$c" in *"$w"*) return 0 ;; esac
        done
        return 0 ;;
    esac
    # ③ 本模块自己的脚本路径
    case "$c" in */O3CPUSet/*|*aether-optext*) return 0 ;; esac
    return 1
}

# 收集「前台应用 + 顶层进程」的 pid 集合
target_pids() {
    local fg="$1" pid c
    # ① 前台应用的所有进程（含 :sub 子进程）
    if [ -n "$fg" ]; then
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}
            c=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)
            [ -n "$c" ] || continue
            is_skip "$c" && continue
            case "$c" in
              "$fg"|"$fg":*) echo "$pid" ;;
            esac
        done
    fi
    # ② 顶层进程（top-app 组里的，排除关键服务）
    for pid in $(cat "$CG_ROOT/top-app/cgroup.procs" 2>/dev/null); do
        c=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -1)
        [ -n "$c" ] || continue
        is_skip "$c" && continue
        echo "$pid"
    done | sort -u
}

# ---------- 组级清扫（v18.3.4 核心新增）----------
# 引擎会把**单个线程**迁进 /dev/cpuset/OptExt/<含8或9的组>。
# 进程在不在 locked 组根本拦不住它（实测）。所以这里反过来做清扫。
#
# ⚠⚠ v18.3.6 判据收紧（用户 2026-10-10 明确口径，重要）：
#   「系统本身对 8/9 核调用就比较弱。艇长的生核如果是**增加** 8~9 核 ——
#     比如线程还是 4~9 → 我觉得也没问题，可以不用解决。
#     但如果是变成这个线程**只使用 8 到 9 核心**，那就绝对不可以。」
#   ⇒ 只拦「独占超大核」，混合形态（4-9 / 0-9 / 0-3,8-9 / 2-9）一律放过。
#
#   实测依据（classify2.sh，1s 级全量扫描）：
#     · 独占 8-9 / 单核 8 / 单核 9 = **25 个**
#       —— 其中 18 个是 kthread（kworker/8/9、cpuhp/8、ksoftirqd/8…，
#          单核算力线程本来就是那个样子，**动它们有风险**），
#          真正被引擎独占的应用线程只有 7 个（dshfolk 4 / wangc.bill 2 / 微信 1）
#     · 混合含 8/9 = **4096 个**（0-9 3875 / 4-9 175 / 0-3,8-9 10 / 2-9 1）
#       —— 这正是用户说"没关系"的那部分，v18.3.5 把它们也扫了属于**过度执行**
#          （白扫 CPU，还砍掉了引擎"中核 ∪ 超大核"的合理分配）。
#
# 实现要点：
#   · 只读「线程自己」的 Cpus_allowed_list 判定，不看它所在的 cgroup 组
#     （组含 8/9 但线程实际是 4-9 的情况大量存在）
#   · kthread / 无 cmdline 的进程一律保留（单核算力线程不是我们的目标）
#   · 白名单（游戏 / 不接管）线程原样保留 → 它们本来就该用 8-9
#   · 先读快照再写（边读边改会漏/会重复）
sweep_89() {
    local moved=0 kept=0 d c t pkg a
    local snap="${TMPD}/sweep.snap"
    local dest="$SAFE"
    [ -d "$CG_ROOT/OptExt" ] || return 0
    if [ ! -d "$dest" ]; then
        dest="$LOCK"
        ensure_group || return 0
    fi
    # 遍历 OptExt 里 cpus 含 8/9 的组 —— 那只是"可能藏独占线程"的入口。
    # 真正的判据是线程自己的 Cpus_allowed_list（见下方 case）。
    for d in "$CG_ROOT"/OptExt/*/; do
        [ -d "$d" ] || continue
        c=$(cat "$d/cpus" 2>/dev/null)
        case "$c" in *8*|*9*) ;; *) continue ;; esac
        cp "$d/tasks" "$snap" 2>/dev/null || continue
        while read -r t; do
            [ -n "$t" ] || continue
            [ -d "/proc/$t" ] || continue
            # ① 线程实际亲和性：只有 8 / 9 / 8-9 才算「独占」
            a=$(grep -m1 '^Cpus_allowed_list:' "/proc/$t/status" 2>/dev/null | awk '{print $2}')
            case "$a" in
              8-9|8|9|9-9|8-8) ;;        # 独占超大核 → 继续处理
              *) kept=$((kept+1)); continue ;;   # 混合形态（4-9/0-9/…）→ 放过
            esac
            # ② 取主进程包名（必须用 tgid，见 v18.3.5 的教训）
            local tgid
            tgid=$(awk '{print $1}' "/proc/$t/stat" 2>/dev/null)
            pkg=""
            [ -n "$tgid" ] && [ -d "/proc/$tgid" ] && \
                pkg=$(tr '\0' '\n' < "/proc/$tgid/cmdline" 2>/dev/null | head -1)
            # ③ 内核线程 / 无 cmdline：保留（单核算力线程动不得）
            [ -n "$pkg" ] || { kept=$((kept+1)); continue; }
            pkg=${pkg%%:*}
            if allow_big_for "$pkg" || is_skip "$pkg"; then
                kept=$((kept+1))
                continue
            fi
            printf '%s' "$t" > "$dest/cgroup.procs" 2>/dev/null && moved=$((moved+1))
        done < "$snap"
    done
    [ "$moved" -gt 0 ] && logq "sweep: $moved 个**独占** $BIG 的线程被扫回 $dest（保留 $kept 个混合/白名单/系统线程）"
    echo "$moved $kept"
}

case "$1" in
  status)
    echo "锁核组: $LOCK（cpus=$(cat "$LOCK/cpus" 2>/dev/null || echo '未建')）"
    n=$(wc -l < "$LOCK/cgroup.procs" 2>/dev/null | tr -d ' ')
    echo "成员数: ${n:-0}"
    for pid in $(cat "$LOCK/cgroup.procs" 2>/dev/null); do
        [ -d "/proc/$pid" ] || continue
        c=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-46)
        [ -n "$c" ] || continue
        echo "  $pid  $c"
    done
    echo "--- OptExt 各组（cpus 含 8/9 的即被封锁目标）---"
    # ⚠ v18.3.6：这里列出的只是「可能藏独占线程」的入口组，不代表异常。
    #   4-9 / 0-9 / 0-3,8-9 这些**混合形态**是引擎与系统的正常分配，不在封锁范围。
    #   真正的判据是线程自己的 Cpus_allowed_list 是否只含 8/9，用 classify2.sh 看。
    for d in "$CG_ROOT"/OptExt/*/; do
        [ -d "$d" ] || continue
        c=$(cat "$d/cpus" 2>/dev/null)
        case "$c" in *8*|*9*) echo "  ★ $(basename "$d") cpus=$c tasks=$(wc -l < "$d/tasks" 2>/dev/null | tr -d ' ')" ;; esac
    done
    exit 0 ;;
  sweep)
    sweep_89
    exit 0 ;;
  release)
    ensure=none
    if [ -d "$LOCK" ]; then
        for pid in $(cat "$LOCK/cgroup.procs" 2>/dev/null); do unlock_pid "$pid"; done
        rmdir "$LOCK" 2>/dev/null; rmdir "$CG_ROOT/$OUR" 2>/dev/null
        echo "OK 已解组并迁回系统组"
    else
        echo "OK 无需解组"
    fi
    exit 0 ;;
esac

# —— 主流程 ——
FG="${1:-$(fg_pkg)}"
ensure_group || { logq "锁核组建不出来，跳过（退化为不限制）"; exit 0; }

# 无论放行还是锁核，都先做一次组级清扫：
#   · 放行时：清扫会跳过白名单应用（本应用）的线程，只把别人的扫回来
#   · 锁核时：清扫把本应用的线程也扫回来
sweep_89 >/dev/null 2>&1

if allow_big_for "$FG"; then
    # 放行：把该应用从锁核组迁回（其余仍锁）
    if [ -n "$FG" ]; then
        for pid in $(cat "$LOCK/cgroup.procs" 2>/dev/null); do
            c=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -1)
            case "$c" in "$FG"|"$FG":*) unlock_pid "$pid" ;; esac
        done
    fi
    logq "放行 $FG（游戏/不接管）→ 可用 $BIG"
else
    # 锁核：把前台应用与顶层进程迁进锁核组
    n=0
    for pid in $(target_pids "$FG"); do
        cur=$(grep cpuset "/proc/$pid/cgroup" 2>/dev/null | cut -d: -f3)
        case "$cur" in *"/$OUR/locked") continue ;; esac
        lock_pid "$pid" && n=$((n+1))
    done
    [ "$n" -gt 0 ] && logq "锁核 $FG：迁入 $n 个进程（其余进程不受影响）"
fi
exit 0
