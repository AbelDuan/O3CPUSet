#!/system/bin/sh
# ============================================================
#  开机自启（玄戒O3 · Abel 调度工具箱 · v19 · AppOpt 引擎版）
#  ★ 线程模块已切换到 AppOpt 原生引擎（v2.2.6 Rust 版）：
#    · 引擎：Scripts/4+4+2/O3/AppOpt（-w 开自带网页 127.0.0.1:8889）
#    · 唯一真值：$STATE_DIR/applist.conf（AppOpt 原生格式 + 语义核心）
#    · o3lim.sh：只维护 applist.conf 的「管理区」段（应用→模式 + 默认档 + 8-9 闸门）
#    · 精细线程规则（块语法/通配/游戏大核）由 AppOpt 网页(8889)全权管理
#    · AppOpt.json：mode=2 纯 /proc 模式（无 eBPF 自作主张提核）、web_enable=true
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

# 3) 线程模块 —— AppOpt 引擎
#    · o3lim.sh boot/gen：生成 applist.conf 的「管理区」段（按 O3 语义核心）
#    · AppOpt -w -c applist.conf -b O3CPUSet：原生二进制落核 + 开自带网页
if [ -f "$AETHER_DIR_SCRIPT" ]; then
    sh "$AETHER_DIR_SCRIPT" boot >> "$LOG_FILE" 2>&1
    log "· 线程配置已生成（o3lim boot，applist.conf 管理区）"
fi
# AppOpt.json 就位（若模块目录里的模板被改过，以模块目录为准；否则引擎自动落盘）
if [ -f "$APPOPT_JSON" ]; then
    cp -f "$APPOPT_JSON" "${MODDIR}/Scripts/4+4+2/O3/AppOpt.json" 2>/dev/null
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
