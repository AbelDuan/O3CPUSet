#!/system/bin/sh
# ============================================================
#  KernelSU 动作按钮 —— 打开 AppOpt 自带线程管理网页（v19）
#    点一下：
#      ① 保证 AppOpt 引擎在跑（没跑就拉起，含自带网页）
#      ② 保证 applist.conf 管理区是最新的（o3lim gen）
#      ③ 打开 AppOpt 自带网页 http://127.0.0.1:8889
#    —— 线程精细规则（块语法/通配线程/游戏大核）全部在这个网页里管；
#       我们的 KSU WebUI（webui 按钮）管频率 + 模式总览，两者联动同一份 applist.conf。
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

# ① 引擎没跑就拉起（含 -w 自带网页）
if ! pgrep -f AppOpt >/dev/null 2>&1; then
    if [ -x "$APPOPT" ]; then
        sh "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" boot >/dev/null 2>&1
        ( cd "$APPOPT_DIR" && nohup ./AppOpt -w -c "$CONF" -b O3CPUSet -s 2 </dev/null >> "$LOG_FILE" 2>&1 & )
        sleep 1
        echo "✅ 已拉起线程引擎 AppOpt（自带网页已开）"
    else
        echo "⚠️ 未找到 AppOpt 引擎，仍尝试打开网页"
    fi
else
    echo "✅ 线程引擎 AppOpt 运行中"
fi

# ② 刷新管理区（把我方 WebUI 的模式定义同步进 applist.conf）
sh "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" gen >/dev/null 2>&1

# ③ 打开自带网页（浏览器可达 127.0.0.1，模块进程监听本机回环）
if command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
    echo "🌐 已打开 AppOpt 线程管理网页：$URL"
else
    echo "🌐 请在浏览器打开：$URL"
fi

echo "ℹ️ 线程规则在 AppOpt 网页管；频率/模式在我们的 WebUI 管（同一份 applist.conf 联动）"
exit 0
