#!/system/bin/sh
# ============================================================
#  卸载（v18 · 模块自有）：停守护、把线程从 cgroup 组释放、
#  并把 CPU 频率上限恢复成硬件上限（放开 QoS 上下限）
#  ★ 线程模块已切换为 o3lim：卸载时 restore 释放自有 cpuset 组
#    （不再需要恢复 aether 提核开关 —— aether 已停用）
# ============================================================
MODDIR="${0%/*}"
. "$MODDIR/lib/util.sh"

uninstall_module() {
    until [ -d "/data/data" ]; do sleep 5; done
    # ★ 先释放 o3lim 自有 cpuset 组（必须在杀守护之前）
    if [ -f "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" ]; then
        sh "$MODDIR/Scripts/4+4+2/O3/o3lim.sh" restore >/dev/null 2>&1
    fi

    pkill -f "O3/guard\.sh" 2>/dev/null
    pkill -f "O3/camera_freq_guard\.sh" 2>/dev/null
    pkill -f "O3/pinwatch" 2>/dev/null
    pkill -f "O3/pinwatch\.sh" 2>/dev/null
    sleep 1
    rm -f "${STATE_DIR}/unlocked" "${STATE_DIR}/locked" "${STATE_DIR}/qos_cleared" "${STATE_DIR}/src.mark" 2>/dev/null

    restore_stock_freq
}

cd / || cd /data
uninstall_module >/dev/null 2>&1

echo "✅ 已停止调度守护；线程已释放（o3lim 自有组已清理）；CPU 频率上限已恢复（不限频）"
echo "（模块目录会在重启后由管理器清理）"
