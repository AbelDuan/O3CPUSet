#!/system/bin/sh
# 把微信 / 支付宝小程序加入应用列表（频率 + 线程），用通配覆盖所有小程序进程
# 幂等：已存在同名条目则跳过
STATE_DIR="/data/adb/O3CPUSet"
APPRULES="$STATE_DIR/apprules.tsv"        # 线程核位：包名<TAB>核位<TAB>友好名
APPFREQ="$STATE_DIR/webui/app_freq.tsv"   # 频率档：包名<TAB>档位
MARK="$STATE_DIR/.miniapps_added"

[ -f "$MARK" ] && { echo "已添加过（$MARK 存在），跳过"; exit 0; }

add_rule() {  # pkg 核位 友好名
  grep -qF "$1	" "$APPRULES" 2>/dev/null || printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$APPRULES"
}
add_freq() {  # pkg 档位
  grep -qF "$1	" "$APPFREQ" 2>/dev/null || printf '%s\t%s\n' "$1" "$2" >> "$APPFREQ"
}

# ---- 微信小程序 ----
# 进程：com.tencent.mm:appbrand0 / appbrand1 / ...（小程序容器，序号递增）
add_rule "com.tencent.mm:appbrand*" "0-3,4-7" "微信小程序"
add_freq "com.tencent.mm:appbrand*" "balance"
# 微信主进程与推送（便于列表里一起定义频率/线程）
add_rule "com.tencent.mm" "0-3" "微信"
add_freq "com.tencent.mm" "balance"
add_rule "com.tencent.mm:push" "0-3" "微信推送"
add_freq "com.tencent.mm:push" "powersave"

# ---- 支付宝小程序 ----
# 实测进程：:tools（小程序容器）、:sandboxed_privilege_process*（沙盒渲染）、:gpu_process
add_rule "com.eg.android.AlipayGphone" "0-3,4-7" "支付宝"
add_freq "com.eg.android.AlipayGphone" "balance"
add_rule "com.eg.android.AlipayGphone:tools" "0-3,4-7" "支付宝小程序"
add_freq "com.eg.android.AlipayGphone:tools" "balance"
add_rule "com.eg.android.AlipayGphone:sandboxed_privilege_process*" "0-3,4-7" "支付宝小程序渲染"
add_freq "com.eg.android.AlipayGphone:sandboxed_privilege_process*" "balance"
add_rule "com.eg.android.AlipayGphone:gpu_process" "0-3,4-7" "支付宝小程序GPU"
add_freq "com.eg.android.AlipayGphone:gpu_process" "balance"
add_rule "com.eg.android.AlipayGphone:push" "0-3" "支付宝推送"
add_freq "com.eg.android.AlipayGphone:push" "powersave"

touch "$MARK"
echo "OK 小程序已加入应用列表"
echo "--- apprules.tsv 新增 ---"; grep -E 'appbrand|AlipayGphone' "$APPRULES" 2>/dev/null
echo "--- app_freq.tsv 新增 ---"; grep -E 'appbrand|AlipayGphone' "$APPFREQ" 2>/dev/null