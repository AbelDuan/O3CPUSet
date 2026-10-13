#!/system/bin/sh
# ============================================================
#  开机自启（玄戒O3 · Abel 调度工具箱 · v19 · AppOpt 引擎版）
#  ★ 线程模块已切换到 AppOpt 原生引擎（v2.2.6 Rust 版）：
#    · 引擎：Scripts/4+4+2/O3/AppOpt（-w 开自带网页 127.0.0.1:8889）
#    · 唯一真值：$STATE_DIR/applist.conf（AppOpt 原生格式 + 语义核心）
#    · o3lim.sh：只维护 applist.conf 的「管理区」段（应用→模式 + 默认档 + 8-9 闸门）
#    · 精细线程规则（块语法/通配/游戏大核）由 AppOpt 网页(8889)全权管理
#    · AppOpt.json：mode=0 自动（eBPF 事件驱动优先，不可用回退 /proc 轮询）、web_enable=true
#    · 语义核心按 O3(4+4+2) 自动映射：e-core=0-3 / p-core=4-7 / hp-core=8-9
#    · 频率侧不变（apply_freq.sh / guard.sh 与线程引擎解耦）
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

cd / || cd /data
until [ -d "/data/data" ] || [ -d "/data/user/0" ]; do sleep 5; done
mkdir -p "$STATE_DIR" "$TMPD" 2>/dev/null

AETHER_DIR_SCRIPT="$MODDIR/Scripts/4+4+2/O3/o3lim.sh"
APPOPT="$MODDIR/Scripts/4+4+2/O3/AppOpt"
APPOPT_JSON="$MODDIR/Scripts/4+4+2/O3/AppOpt.json"
CONF="$STATE_DIR/applist.conf"

# 等 boot 完成（自带网页/拓扑探测需要系统就绪；参考 AppOpt 官方 service 行为）
_i=9
until [ "$(getprop sys.boot_completed)" = "1" ] || [ "$_i" -le 0 ]; do _i=$((_i-1)); sleep 3; done

log "⚡ 玄戒O3 调度工具箱 service 启动（v19 · 线程引擎=AppOpt）"

SCHEME=$(active_scheme)
[ -z "$SCHEME" ] && SCHEME="sweet_bal"

# 1) 频率接管
current_mode_read 2>/dev/null
sh "$MODDIR/Scripts/4+4+2/O3/apply_freq.sh" --mode "${CUR_MODE:-balance}" >> "$LOG_FILE" 2>&1
log "· 频率已按模式[${CUR_MODE:-balance}]下发（QoS）"

# 2) 平台调优脚本
PC="${MODDIR}/Config/4+4+2/O3/${SCHEME}/powercfg.sh"
if [ -f "$PC" ]; then
    sh "$PC" >> "$LOG_FILE" 2>&1
    log "· powercfg.sh 已执行（方案 $SCHEME）"
fi

# 2b) 线程基准部署：把「模板 + 用户自定义覆盖」按真机拓扑展开成 threads.json，
#     供 o3lim.sh 的 ③ 兜底源消费（含小红书=省电等出厂默认）。
#     ⚠ 必须跑：否则 o3lim 只读得到陈旧/缺失的 threads.json，普通应用会漏到默认 p-core(4-7)。
#     已安装设备若缺运行时 OVR，这里顺手播种一次（模块内置种子 Config/aether_overrides.tsv）。
if [ ! -f "$STATE_DIR/aether_overrides.tsv" ] && [ -f "$MODDIR/Config/aether_overrides.tsv" ]; then
    cp -f "$MODDIR/Config/aether_overrides.tsv" "$STATE_DIR/aether_overrides.tsv" 2>/dev/null
    chmod 0666 "$STATE_DIR/aether_overrides.tsv" 2>/dev/null
fi
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
if [ -f "$AETHER_CTL" ]; then
    sh "$AETHER_CTL" deploy >> "$LOG_FILE" 2>&1
    log "· 线程基准已部署（aether_ctl deploy：模板+自定义→threads.json）"
fi

# 2c) ★ v19.0.6：aether-optext 已废弃（线程引擎统一为 AppOpt），这里做开机自愈清理。
#     背景：v18 时代的 aether-optext 进程会在设备上留下孤儿实例（实测存活 13h+），
#     它按 /sdcard/Android/Aether/threads.json 自建 /dev/cpuset/OptExt/ 组树并与
#     AppOpt 抢同一批线程的 cgroup（一个线程只能属于一个组）→ 表现为「省电应用
#     的 RenderThread 被改到 2-3」「冷启动瞬态核位不回落」等假异常。
#     v19 起所有启动路径已不含 aether start，本段只负责：
#       ① 停掉仍在跑的本模块 aether-optext（含读同一份 -c CFG 的兄弟实例）
#       ② 删除 aether.on 开关，杜绝任何路径再次拉起
#       ③ 移除空的 /dev/cpuset/OptExt 组树（残留线程先迁回根组再删空组）
#     ⚠ 只读 deploy 仍保留（o3lim 的兜底源依赖它生成的 threads.json），不停。
AETHER_BIN="$MODDIR/Scripts/4+4+2/O3/aether/aether-optext"
AETHER_BIN_RE=$(printf '%s' "$AETHER_BIN" | sed 's/[][\.*+?(){}|^$]/\\&/g')
AETHER_CFG="/sdcard/Android/Aether/threads.json"
rm -f "$STATE_DIR/aether.on" 2>/dev/null     # 先摘开关，防止边杀边被拉起
pkill -f "$AETHER_BIN_RE" 2>/dev/null
# 同配置竞争实例：读同一份 -c CFG 但不是本模块二进制的 aether-optext
for _p in $(pgrep -f "aether-optext -c $AETHER_CFG" 2>/dev/null); do
    case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
        *"$AETHER_BIN"*) continue ;;   # 本模块自己，跳过
    esac
    kill "$_p" 2>/dev/null
done
sleep 1
if pgrep -f "$AETHER_BIN_RE" >/dev/null 2>&1; then
    log "⚠ aether-optext 仍有残留（已废弃，建议手动核查）"
else
    log "· aether-optext 已废弃清理完成（无残留进程）"
fi
# 清理 OptExt 组树：先把残留线程迁回根组，再从深处删空组。
# ⚠ 两个实测陷阱：
#   ① 必须**先迁根组自己的 tasks** 再删 —— 只清子组会留下「根组非空」导致 rmdir EBUSY
#      （实测根组残留 87 个线程，子组全空也删不掉）。
#   ② 迁移用 `echo <tid> > /dev/cpuset/tasks`（逐线程）而不是 cgroup.procs ——
#      写 cgroup.procs 传 tid 会迁**整个线程组**，把同进程的兄弟线程一起带跑
#      （实测小红书主进程被整体踢到根组）。
if [ -d /dev/cpuset/OptExt ]; then
    # ① 子组线程先归位
    for _d in /dev/cpuset/OptExt/*/; do
        [ -d "$_d" ] || continue
        for _t in $(cat "$_d/tasks" 2>/dev/null); do
            echo "$_t" > /dev/cpuset/tasks 2>/dev/null
        done
    done
    # ② 根组自身线程归位（关键，漏了这步 rmdir 必然失败）
    for _t in $(cat /dev/cpuset/OptExt/tasks 2>/dev/null); do
        echo "$_t" > /dev/cpuset/tasks 2>/dev/null
    done
    sleep 1
    # ③ 从深到浅删空组
    _i=0
    while [ "$_i" -lt 6 ]; do
        rmdir /dev/cpuset/OptExt/*/ 2>/dev/null
        _i=$((_i+1))
    done
    rmdir /dev/cpuset/OptExt 2>/dev/null
    if [ -d /dev/cpuset/OptExt ]; then
        log "⚠ /dev/cpuset/OptExt 仍有残留线程，未能移除（不影响功能）"
    else
        log "· 已移除废弃的 /dev/cpuset/OptExt 组树"
    fi
fi

# 3) 线程模块 —— AppOpt 引擎
#    · o3lim.sh boot/gen：生成 applist.conf 的「管理区」段（按 O3 语义核心）
#    · AppOpt -w -c applist.conf -b O3CPUSet：原生二进制落核 + 开自带网页
if [ -f "$AETHER_DIR_SCRIPT" ]; then
    sh "$AETHER_DIR_SCRIPT" boot >> "$LOG_FILE" 2>&1
    log "· 线程配置已生成（o3lim boot，applist.conf 管理区）"
    # ★ v19.0.7：service 是开机/自愈的最后一棒，这里再收敛一次（gen 幂等）。
    #   保证任何路径（安装 / 开机 / ksud services 重拉）结束时 applist.conf 都是
    #   去重后的结果 —— 重复条目会让「改了档位不生效」的排查变困难。
    sh "$AETHER_DIR_SCRIPT" gen >> "$LOG_FILE" 2>&1
fi
# AppOpt.json 就位（v19.0.5：只在**缺失**时补默认 mode=0）
#   ⚠ 旧版这里是 `cp -f "$APPOPT_JSON" 自身路径`（src==dst 的空操作），本意想
#     「以模块模板为准」，实际会把引擎运行时写入的工作模式（用户在 8889 页切的
#     eBPF/Proc）在每次开机时打回模板值。现在：模块 zip 自带 mode=0 模板（新装/
#     模块更新即自动=自动模式），运行期由引擎自行读写该文件，开机不覆盖。
if [ ! -f "$APPOPT_JSON" ]; then
    cat > "$APPOPT_JSON" <<'AJSON'
{
  "check_interval": 2,
  "config_file": "/data/adb/O3CPUSet/applist.conf",
  "cpuset_name": "O3CPUSet",
  "mode": 0,
  "web_enable": true
}
AJSON
    chmod 0644 "$APPOPT_JSON" 2>/dev/null
    log "· AppOpt.json 缺失 → 已补默认（mode=0 自动）"
fi
# ★ v19.0.7：保证 8889 网页是开的。
#   现象：刷完模块 AppOpt 在跑但 8889 不 LISTEN，模块「执行」按钮打开网页失败。
#   根因：AppOpt 运行时会**自行持久化**工作模式到 AppOpt.json（在 8889 页切换
#     即写盘），实测把 web_enable 写成了 false；而 v19.0.5 起 service.sh 不再
#     覆盖该文件（为的是不把用户选的 mode 打回默认），于是 false 被永久保留。
#   修法：只补 web_enable=true 这一项，mode / check_interval 一律不动 ——
#     既保住用户对引擎模式的选择，又保证网页永远可达。
if [ -f "$APPOPT_JSON" ] && ! grep -q '"web_enable"[[:space:]]*:[[:space:]]*true' "$APPOPT_JSON" 2>/dev/null; then
    if grep -q '"web_enable"' "$APPOPT_JSON" 2>/dev/null; then
        sed -i -E 's/"web_enable"[[:space:]]*:[[:space:]]*[^,}]*/"web_enable": true/' "$APPOPT_JSON" 2>/dev/null
    else
        sed -i -E 's/^([[:space:]]*)("[a-z_]+":)/\1"web_enable": true,\n\1\2/' "$APPOPT_JSON" 2>/dev/null
    fi
    log "· AppOpt.json 的 web_enable 已补为 true（8889 网页可达）"
fi
if [ -f "$APPOPT" ]; then
    chmod 0755 "$APPOPT" 2>/dev/null
    pkill -f AppOpt 2>/dev/null
    # 工作目录 = 二进制所在目录，AppOpt.json 相对 "./AppOpt.json" 在此目录
    ( cd "$MODDIR/Scripts/4+4+2/O3" && nohup ./AppOpt -w -c "$CONF" -b O3CPUSet -s 2 </dev/null >> "$LOG_FILE" 2>&1 & )
    log "· 线程引擎 AppOpt 已启动（-w 开自带网页 8889 · -c applist.conf · -s 2）"
else
    log "· 未找到 AppOpt 二进制，跳过线程引擎"
fi

# 4) 调度守护 guard.sh（前台识别 + 频率兜底 + 触发 o3lim 增量）
GUARD_SH="$MODDIR/Scripts/4+4+2/O3/guard.sh"
if [ -f "$GUARD_SH" ]; then
    nohup sh "$GUARD_SH" </dev/null >> "$LOG_FILE" 2>&1 &
    log "· 调度守护已拉起（guard.sh pid $!）"
fi

# 5) 模块卡片描述
update_module_desc >/dev/null 2>&1

exit 0
