#!/system/bin/sh
# ============================================================
#  no_bigcore_feat.sh —— 关掉 aether 的「动态提核到 8-9」功能
# ------------------------------------------------------------
#  目标（与用户规则一致）：保留 aether 全部能力，唯一改动 = 非游戏/非不接管
#        的应用永不升到 8-9 超大核。游戏 / 不接管(none) 仍可用 8-9。
#
#  依据 exp_features.sh 真机实验结论：
#        aether 把线程提到 8-9 的开关主要是 load_aware（按负载提核）与
#        render_guard（渲染线程往大核提）。关掉二者 → 独占 8-9 线程归零。
#        而 auto-for-none 是「不接管应用自动上 8-9」的正当通道，必须保留；
#        ebpf 是引擎底座，必须保留（全关则引擎失效、游戏也落不了核）。
#
#  foreground 开关（已实证为真凶）：它把「前台应用的渲染/UI 线程」动态提到 8-9，
#        与 threads.json 的 comm 8-9 规则（仅游戏使用，共 131 处，全部游戏包）
#        是两回事。关掉 foreground 只禁非游戏前台提 8-9，不影响游戏走 comm 8-9。
#        （已用 final834 实测 + threads.json 解析交叉验证：comm 8-9 全是游戏包）
#
#  用法：
#        no_bigcore_feat.sh apply    关提核开关（幂等，service 启动时调用）
#        no_bigcore_feat.sh watch    看护：开关被改回 true 则重关（guard 每轮调）
#        no_bigcore_feat.sh status   打印当前 5 开关状态
#        no_bigcore_feat.sh restore  恢复默认（全 true）
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
AETHER_CTL="$MODDIR/Scripts/4+4+2/O3/aether/aether_ctl.sh"
STATE_DIR="${STATE_DIR:-/data/adb/O3CPUSet}"
MARK="$STATE_DIR/no_bigcore.feat"

# 关掉所有「动态/前台提核到 8-9」的开关。游戏的 comm 8-9 静态规则不动。
DO_FOREGROUND=1

log_quiet() { :; }
[ -f "$MODDIR/lib/util.sh" ] && . "$MODDIR/lib/util.sh" 2>/dev/null
command -v log_quiet >/dev/null 2>&1 || log_quiet(){ :; }

[ -f "$AETHER_CTL" ] || { echo "ERR 找不到 $AETHER_CTL"; exit 1; }

# 要关闭的提核开关
OFF_SW="load_aware render_guard"
[ "$DO_FOREGROUND" = "1" ] && OFF_SW="$OFF_SW foreground"
# 必须保留的开关（强制开）
ON_SW="ebpf auto-for-none"

# 读取当前某开关值（true/false）
feat_val() {
    sh "$AETHER_CTL" feat "$1" 2>/dev/null | grep -oiE '(true|false)' | head -1
}

# 关闭提核开关 / 保持必须开启的开关。返回 0=无变更 1=有变更（需 restart）
apply_off() {
    local changed=0 s v
    for s in $OFF_SW; do
        v=$(feat_val "$s")
        if [ "$v" != "false" ]; then
            sh "$AETHER_CTL" feat "$s" false >/dev/null 2>&1
            log_quiet "no_bigcore: $s -> false"
            changed=1
        fi
    done
    for s in $ON_SW; do
        v=$(feat_val "$s")
        if [ "$v" != "true" ]; then
            sh "$AETHER_CTL" feat "$s" true >/dev/null 2>&1
            log_quiet "no_bigcore: $s -> true（保持）"
            changed=1
        fi
    done
    [ "$changed" = "1" ] && touch "$MARK"
    return $changed
}

# feat 改完必须 restart 引擎才生效（aether_ctl feat 文案: 重启引擎后生效）
restart_aether() {
    sh "$AETHER_CTL" restart >/dev/null 2>&1
    log_quiet "no_bigcore: 已 restart aether 使配置生效"
}

cmd_apply() {
    if apply_off; then
        echo "OK 配置已是目标态，无需重启"
    else
        restart_aether
        echo "OK 已关闭提核开关: $OFF_SW（保留: $ON_SW），引擎已重启生效"
    fi
}

cmd_watch() {
    # 仅当标记存在（曾应用过）才看护；幂等：无变更不重启，开销极低
    [ -f "$MARK" ] || return 0
    if ! apply_off; then
        restart_aether
    fi
}

cmd_status() {
    echo "== aether 开关状态 =="
    for s in ebpf auto-for-none foreground load_aware render_guard; do
        printf "  %-14s = %s\n" "$s" "$(feat_val "$s")"
    done
    echo "（提核已禁: $OFF_SW | 保留: $ON_SW）"
}

cmd_restore() {
    for s in ebpf auto-for-none foreground load_aware render_guard; do
        sh "$AETHER_CTL" feat "$s" true >/dev/null 2>&1
    done
    rm -f "$MARK"
    echo "OK 已恢复全部开关为 true（撤销 8-9 限制）"
}

case "$1" in
    apply)   cmd_apply ;;
    watch)   cmd_watch ;;
    status)  cmd_status ;;
    restore) cmd_restore ;;
    *) echo "usage: no_bigcore_feat.sh apply|watch|status|restore" ;;
esac
