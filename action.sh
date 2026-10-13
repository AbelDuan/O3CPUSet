#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 打开 AppOpt 自带线程管理网页（v19）
#    点一下：
#      ① 保证 AppOpt 引擎在跑（没跑就拉起，含自带网页）
#      ② 保证 applist.conf 管理区是最新的（staleness 检查，陈旧才 o3lim gen）
#      ③ 打开 AppOpt 自带网页 http://127.0.0.1:8889
#    —— 线程精细规则（块语法/通配线程/游戏大核）全部在这个网页里管；
#       我们的 KSU WebUI（webui 按钮）管频率 + 模式总览，两者联动同一份 applist.conf。
#
#  ★ v19.0.5：修「点执行按钮要等很久才能进网页」。
#    根因：旧版②无条件跑 `o3lim.sh gen`（实测 0.2~1.2s，含 pm/线程表/去重全套），
#    而我方 WebUI 每次保存时**已经同步过** applist.conf —— 这一步几乎总是白跑。
#    改法：staleness 检查 —— 只有当输入文件比 applist.conf 新时才重跑 gen。
#    另：引擎没跑时，启动后**轮询 8889 端口就绪**再开浏览器（替代固定 sleep 1），
#    端口起了才开页，不会出现「浏览器开了、页面 404/转圈」。
# ============================================================
MODDIR="${0%/*}"
export MODDIR
. "$MODDIR/lib/util.sh"

# ---------- 访问即自愈：合并 KSU 待更新副本（免重启）----------
selfheal_pending_update 2>/dev/null

APPOPT_DIR="$MODDIR/Scripts/4+4+2/O3"
APPOPT="$APPOPT_DIR/AppOpt"
CONF="$STATE_DIR/applist.conf"
URL="http://127.0.0.1:8889"

# 8889 端口是否已监听（AppOpt -w 的网页）；比 pgrep 更贴近「网页能不能开」。
#   ⚠ 必须精确匹配 127.0.0.1:22B9 的 LISTEN(0A) 行：直接 grep '22B9' 会把设备
#     「连接外部 8889」的 ESTABLISHED 行也算进来，误判引擎在跑。
port_up() {
  awk '$2=="0100007F:22B9" && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp 2>/dev/null
}

# ① 引擎没跑就拉起（含 -w 自带网页）
if port_up; then
    echo "✅ 线程引擎 AppOpt 运行中（8889 已监听）"
elif [ -x "$APPOPT" ]; then
    sh "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" boot >/dev/null 2>&1
    ( cd "$APPOPT_DIR" && nohup ./AppOpt -w -c "$CONF" -b O3CPUSet -s 2 </dev/null >> "$LOG_FILE" 2>&1 & )
    # 等端口就绪再开浏览器（最多 ~3s；sleep 不支持小数时退化为快轮询，仍有上限）
    i=0
    while [ $i -lt 30 ]; do
        port_up && break
        sleep 0.1 2>/dev/null || sleep 0 2>/dev/null || :
        i=$((i+1))
    done
    echo "✅ 已拉起线程引擎 AppOpt（自带网页已开）"
else
    echo "⚠️ 未找到 AppOpt 引擎，仍尝试打开网页"
fi

# ② 刷新管理区（staleness：仅当输入比 applist.conf 新才重跑 gen）
#    判定输入 = 我方 WebUI 的三张表 + OVR 覆盖表 + apprules + threads.json
#    （AppOpt 8889 网页的规则在「未管理段」，本就不由 gen 生成，无需触发）
NEED_GEN=0
[ -s "$CONF" ] || NEED_GEN=1
if [ "$NEED_GEN" = "0" ]; then
  for f in "$STATE_DIR/webui/app_assign.tsv" "$STATE_DIR/webui/game_assign.tsv" \
           "$STATE_DIR/webui/app_freq.tsv" "$STATE_DIR/webui/pkg_labels.tsv" \
           "$STATE_DIR/aether_overrides.tsv" "$MODDIR/Config/aether_overrides.tsv" \
           "$STATE_DIR/apprules.tsv" /sdcard/Android/Aether/threads.json; do
    [ -f "$f" ] && [ "$f" -nt "$CONF" ] && { NEED_GEN=1; break; }
  done
fi
if [ "$NEED_GEN" = "1" ]; then
  sh "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" gen >/dev/null 2>&1
  echo "🔄 管理区已刷新（检测到配置变化）"
else
  echo "✅ 管理区已是最新（WebUI 保存时已同步，无需刷新）"
fi

# ③ 打开自带网页（浏览器可达 127.0.0.1，模块进程监听本机回环）
if command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
    echo "🌐 已打开 AppOpt 线程管理网页：$URL"
else
    echo "🌐 请在浏览器打开：$URL"
fi

echo "ℹ️ 线程规则在 AppOpt 网页管；频率/模式在我们的 WebUI 管（同一份 applist.conf 联动）"
exit 0
