# Aether OptExt "无动态升核" 复刻版 · 交付说明

## 一、这个是什么

对 `AbelDuan/O3CPUSet` 模块里的**舰长线程引擎**（`aether-optext`，预编译 Rust/AArch64 ELF，aya-0.14.0 + eBPF）做的**最小二进制 patch**：唯一区别是**去掉"自主动态升核到 8/9 超大核"**。

- 原版：`aether-optext`（SHA256 `d9153c58…`）
- 复刻版：`aether-optext-nobig`（SHA256 `693fe35a…`）

其余行为（eBPF、规则解析、cpuset 分组、`game`/`none` 角色、拓扑分层、频率、WebUI）**完全一致**。

---

## 二、被去掉的行为（逆向定位）

原版二进制的 `.rodata` 里有这条日志（`@0x11e88`）：

```
safety: render thread '?' (pkg ?) promoted to perf cores ? (was ?)
safety: pkg ? target ? -> ? (min_cpus=?)
```

它由**负载感知升核器**打印，函数位于 `.text` 的 `0x6a180~0x6ab00`，控制流：

```asm
0x6a5e4   ldrb  w8, [x22, #0x39c]        ; 读取包级布尔（升核总闸）
0x6a5e8   tbz   w8, #0, #0x6a724         ; ← patch 点 1：闸门开则继续，否则跳过
0x6a5ec   ldp   x0, x1, [sp, #0x1a0]     ; render 线程名
0x6a5f0   bl    0x6aad0                  ; 判据：是否渲染线程
0x6a5f4   cbz   w0, #0x6a724
0x6a5f8   bl    0x71c00                  ; 计算核位
0x6a6cc   → 打印 "promoted to perf cores"
…
0x6a860   ldrb  w8, [x22, #0x39c]        ; 第二处同闸门
0x6a864   tbz   w8, #0, #0x6a888         ; ← patch 点 2
0x6a86c   bl    0x6aad0
0x6a874   bl    0x69088                  ; 真正下发 sched_setaffinity
```

**patch 内容**（共 6 字节，全部在 `.text` 内）：

| 虚拟地址 | 原指令 | 原编码 | 改为 | 新编码 |
|---|---|---|---|---|
| `0x6a5e8` | `tbz w8,#0,#0x6a724` | `e8 09 00 36` | `b #0x6a724` | `4f 00 00 14` |
| `0x6a864` | `tbz w8,#0,#0x6a888` | `28 01 00 36` | `b #0x6a888` | `09 00 00 14` |

效果：两道闸门**恒判定为"关闭"** → 引擎永不进入动态升核块 → 核位回落到规则/拓扑原本计算出的集合。

---

## 三、保留的行为（未动）

| 功能 | 状态 |
|---|---|
| `game` 角色主线程/最重线程 → `{hp_core}` = 8-9 | ✅ 保留（显式规则，非动态提升） |
| `none` 放行 → `{all_core}` = 0-9 | ✅ 保留 |
| 拓扑分层 `E=0-3 / P1=4-7 / HP=8-9 / ALL=0-9` | ✅ 保留 |
| eBPF 事件驱动、进程/线程发现、cpuset 分组 | ✅ 保留 |
| `min_cpus` 下限检查、blacklist 清扫 | ✅ 保留 |
| WebUI / `aether_ctl.sh` 全部子命令 | ✅ 保留 |
| 频率 PM QoS（`CL_P="8 9"`） | ✅ 保留（与落核无关） |

---

## 四、安装

```sh
# 1. push 复刻版（保留原版为 .orig，便于回滚）
adb push aether-optext-nobig /data/local/tmp/
adb shell su -c 'cp /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext \
                     /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext.orig'
adb shell su -c 'cp /data/local/tmp/aether-optext-nobig \
                     /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext'
adb shell su -c 'chmod 0755 /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext'
adb shell su -c 'chown 0:0 /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext'

# 2. 重启引擎
adb shell su -c 'sh /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether_ctl.sh restart'
```

> 注：`customize.sh` 在升级时会覆盖该二进制。若你要长期保留复刻版，
> 把 `aether-optext-nobig` 放进仓库同目录，并在 `customize.sh` 的 chmod 段之后
> 加一行 `cp -f "$MODPATH/Scripts/4+4+2/O3/aether/aether-optext-nobig" \
>        "$MODPATH/Scripts/4+4+2/O3/aether/aether-optext"`。

---

## 五、验证（真机）

```sh
# 跑一个游戏/重载应用后看日志，应不再出现 promoted
adb shell su -c 'grep -c "promoted to perf cores" /data/adb/O3CPUSet/aether.log'
# 期望：0

# 放行应用仍应看到 0-9（你要保留的）
adb shell su -c 'cat /proc/$(pgrep -f com.tencent.mm | head -1)/status | grep Cpus_allowed_list'
```

---

## 六、回滚

```sh
adb shell su -c 'cp /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext.orig \
                     /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether-optext'
adb shell su -c 'sh /data/adb/modules/O3CPUSet/Scripts/4+4+2/O3/aether/aether_ctl.sh restart'
```
