# v19 架构说明：线程引擎切换到 AppOpt（纯规则驱动）

> 本文档记录 **2026-10-13** 的一次重大架构变更：线程落核引擎从 **Aether（aether-optext）**
> 换成 **[AppOpt](https://gitee.com/sutoliu/AppOptR) v2.2.6**（Rust 源码版）。
>
> 起因：Aether 的二进制里有一条**硬编码的「前台渲染线程保护」**（`safety: render thread
> detected, guard armed` → `promoted to perf cores`），它把前台应用的渲染线程
> **提升到 8-9**，且**无视配置文件里定义的 0-3/4-7**，也无法用任何 features 开关关闭。
> 结果就是「WebUI 里设成省电(0-3)的抖音，实际仍在 4-7/8-9 上跑」。
>
> AppOpt 是**纯规则驱动**：配置写什么核位就落什么核位，没有任何自作主张的提核。
> 这从根本上满足「**所有调整都必须由 WebUI / 配置定义，不能写死**」的要求。

---

## 1. 三层结构（唯一真值 + 双入口）

```
                    ┌──────────────────────────────┐
                    │  applist.conf（唯一真值）      │
                    │  /data/adb/O3CPUSet/applist.conf│
                    └──────────────┬───────────────┘
                          inotify 热重载（改完即生效）
                                   │
                    ┌──────────────▼───────────────┐
                    │  AppOpt 引擎（v2.2.6）        │
                    │  mode=0 自动（eBPF 优先，回退 proc）│
                    │  -w 开自带网页 127.0.0.1:8889  │
                    └───────────────────────────────┘
                                   │ sched_setaffinity + cpuset
                    ┌──────────────▼───────────────┐
                    │  /dev/cpuset/O3CPUSet/<核位>  │
                    │  0-3 / 4-7 / 8-9（按 O3 拓扑）│
                    └───────────────────────────────┘
```

**两个入口，同一份真值，互不打架：**

| 入口 | 位置 | 管什么 |
|---|---|---|
| **AppOpt 自带网页** | 模块「执行」按钮 → `http://127.0.0.1:8889` | 精细线程规则：块语法、通配符、单线程绑定、游戏大核 |
| **我们的 KSU WebUI** | 模块「网页」按钮 → webroot/index.html | 频率档 + 「应用→模式」快捷分配，写入 `applist.conf` 的**管理区段** |

AppOpt 网页写**管理区之外**的内容；我们的 WebUI 只重写**管理区段**（用 ASCII 标记包裹）——
两者永不互相覆盖，天然共存。

> **v19.0.2 联动增强**：`applist.conf` 是两边共用的唯一真值。模块 WebUI 的「应用」页
> 现在**读取 `applist.conf` 里每个包的有效语义核心规则**（反向映射成 省电/流畅/性能）来显示档位，
> 因此**在 8889 网页里改了某应用，模块 WebUI 立即能看到**；反之模块 WebUI 改完经 `o3lim gen`
> 重写管理区段，8889 经 inotify 也能看到。为避免互相踩：
> - `o3lim gen` 的**兜底 `p-core` 不会覆盖 8889 未管理段里已存在的规则**（保留手动档位）；
> - 模块 WebUI 设「不接管(fast/none)」时，会**连 8889 未管理段里的同包规则一并移除**，保证「不接管」真正生效。

---

## 2. O3（4+4+2）语义核心映射

AppOpt 按 `cpufreq` 的 `cpuinfo_max_freq` 升序自动分档，**在 O3 上自动得到**：

| 语义核心 | O3 实际核 | 用途 |
|---|---|---|
| `e-core` | **0-3** | 能效小核（省电） |
| `p-core` | **4-7** | 性能中核（流畅） |
| `hp-core` | **8-9** | 超大核（游戏/重载） |
| `all-core` | 0-9 | 全部 |

**写语义核心而不是写死数字** → 换设备不用改规则，这是「不写死」的关键落地。

### 模式 → 核位（我们的 WebUI 定义）

| 模式 | 规则 | 实际核位 |
|---|---|---|
| 省电 powersave | `pkg=e-core` | 0-3 |
| 流畅 balance | `pkg=p-core` | 4-7 |
| 性能 performance | `pkg=e-core,p-core` | 0-7 |
| 极速 fast / 不接管 none | **不写规则** | 交系统调度（含 8-9 但引擎不强制） |
| 游戏（放行包） | `pkg=hp-core` | 8-9 定死 |

---

## 3. 规则优先级（后写覆盖先写，最终按包名唯一）

`o3lim.sh gen` 按**升序优先级**依次追加，最后用一次 awk 按包名去重（保留最后一条）：

| 优先级 | 来源 | 说明 |
|---|---|---|
| 低 | `threads.json`（历史数据） | 数字核位 → 语义核心转换 |
| ↑ | `apprules.tsv`（历史真值） | `0-9`/`all` → **不接管**；纯 `8-9` → hp-core（仅放行包） |
| ↑ | `webui/game_assign.tsv` | 按记录的档位映射 |
| **高** | `webui/app_assign.tsv` | **我们 WebUI 的权威表**（用户最新意图） |
| **兜底** | `pm list packages -3` 未配置项 | 补 `p-core`（流畅）→ **频率跟随全局 + 线程流畅** |

`fast`/`none` 会**持久化为一条 `fast` 记录**（而非删除），这样它能压过 `apprules` 里的历史规则，
真正做到「不接管」。内部用 `pkg=__REMOVE__` 标记传递删除意图，**最终输出前会被剔除**。

### 3.1 兜底规则（用户明确要求）

**未定义配置的进程 → 频率跟随全局 + 线程用「流畅」**：

| 维度 | 兜底行为 | 实现 |
|---|---|---|
| 频率 | **跟随全局模式** | 不在 `app_freq.tsv` 写档 → `guard.sh` 不改写该应用，保持全局档 |
| 线程 | **流畅（p-core = 中核 4-7）** | `o3lim.sh gen` 对「有界面的第三方应用」补 `pkg=p-core` |

例外：已在管理区有规则的包不覆盖；被标 `__REMOVE__`（用户选「不接管」）的包不补默认。

### 3.2 通配符支持范围（实测 + 源码双证）

| 维度 | 通配 | 依据 |
|---|---|---|
| **线程名** | ✅ `*` `?` `[0-9]` | `rule_match.rs:30` 用 `libc::fnmatch`；实测 `com.coolapk.market{*Thread*}=p-core` 把 `RenderThread`/`LaunchThreadPoo` 都绑到 4-7 |
| **包名** | ❌ **仅精确匹配** | `config.rs:313` `pkgs = HashSet<规则里的字面包名>`；`apply_affinity.rs:104` 用 `.contains()`。实测写通配包名 → API 报 `hit_pkgs:0` |

**由此定策略**：
- **线程级漏网** → 用**一条** `{*Thread*}` 通配覆盖所有含 Thread/thread 的线程名（替代原来的 `{*Thread}` + `{Thread*}` 两条）
- **包级漏网（子进程）** → 包名无法通配，只能**枚举**（`/proc` + 配置文件里的 `:` 进程）

**精简依据（实测冗余）**：
- `{*Thread*}` 已覆盖 `{Thread*}` → 删
- 包级规则本身就把 `binder:xxx` 等绑到同档（实测 `binder:3269_1 = 0-3`）→ `{binder*}` 删
- 结果：每个显式配置的包只多 **1 条**线程规则（原 3 条），总规则 **1480 → 677**

---

## 4. WebUI（三页面：全局 / 应用 / 游戏）

沿用**艇长（Aether）时代的最后一版界面**（UI/布局/功能保持一致），仅剔除艇长独有部分：

| 页面 | 管什么 | 后端通道 |
|---|---|---|
| **全局** | 选方案、选全局模式、编辑四档频率区间；顶部显示「线程引擎 AppOpt 运行中」+ 打开 8889 按钮 | `freqview` / `frequse` / `modeset` / `status` |
| **应用** | 逐应用设「频率档 + 线程档」（省电/流畅/性能/极速），支持搜索/筛选/勾选批量套用、小程序归并 | `appsetbatch` → `app_assign.tsv` → `o3lim gen` |
| **游戏** | 游戏列表，只选频率档（线程固定走 hp-core 大核） | `appsetbatch kind=game` → `game_assign.tsv` |

**已剔除的艇长独有功能**：Aether 线程引擎状态卡与特性开关（ebpf/foreground/load_aware/render_guard）、
线程角色档编辑页、`aetherapps` 数据源（改走本机应用清单）、「跟随艇长」字样（改为「跟随全局」）。

---

## 5. 关键实现细节（踩过的坑）

| 问题 | 现象 | 根因 | 修法 |
|---|---|---|---|
| **gen 卡死** | `o3lim.sh gen` 挂住不返回 | 在 `while read <&3` 循环里 spawn `grep`，toybox grep 继承了循环 FD 的 stdin → 阻塞 | 循环内**不再 spawn grep**；改为纯 shell 追加 + 最后一次性 awk 去重 |
| **段头丢失** | 每次 gen 重复累积、BEGIN 标记消失 | `gen_managed_section` 内部 `: > "$out"` 截断了先写好的段头 | 先调 `gen_managed_section`，**再**拼段头 |
| **`__REMOVE__` 泄漏** | AppOpt 报「29 条规则格式无效」 | 去重 awk 逻辑没把「最后一条是 `__REMOVE__`」的包整条丢弃 | 重写去重：`lastline[p]==i && mark[i]=="K"` 才输出 |
| **读到 0 条规则** | AppOpt 日志间歇出现「共加载 0 条规则」 | 非原子写盘，inotify 在写入中途读到空文件 | **原子发布**：写 `CONF.new` → 校验非空且含 `=` → `mv` 覆盖 |
| **mode 被自行改写** | 手动写 AppOpt.json 后开机发现值变了 | AppOpt 运行时会**自行持久化** mode（8889 页切换即写盘；内核支持 BTF 时 auto→eBPF） | 停引擎 → 写 `AppOpt.json` → 重启；v19.0.5 起模块不再开机覆盖该文件 |
| **极速档不生效** | 设极速后规则仍在（`e-core,p-core`） | 删了 app_assign 记录 → 回落到 `apprules` 的历史规则 | 极速持久化 `fast` 记录压过历史 |
| **★ 改配置后刷新回退默认** | 改应用档位 → 刷新/应用后变回旧值 | **三处断链**：①前端缺 `Api.appsetbatch` 方法（调用 undefined 静默失败）②后端缺 `gamefreq`/`appset`/`appdel` 命令 ③`appfreqapps` 读 `aether_ctl apps` 的**陈旧数据** | ①补齐 `Api` 方法 ②补齐后端命令 ③读回改走本模块自有真值（`app_freq.tsv`/`app_assign.tsv`） |
| **★ 子进程不受管（省电应用仍上 8-9）** | 酷安设省电，主进程 0-3 但 `com.coolapk.market:xg_vip_service` 仍在 0-9/8-9 | AppOpt 包名**精确匹配**（`cfg.pkgs` 是 HashSet），配 `com.coolapk.market` **不会**作用到 `:xg_vip_service` → 子进程留在系统 `top-app`(0-9) | `o3lim gen` **子进程展开**：为每个已配包名的已知子进程补同核位规则（子进程来源 `/proc` + 配置文件） |
| **★ `pkg:*` 通配伪包名漏 hp-core** | 微信/支付宝出现 `com.tencent.mm:*=p-core,hp-core`，小程序子进程被给 8-9 | `threads.json` 里存在**字面量含 `*` 的包名**条目，核位 `0-3,4-7,8-9` → 转成 `p-core,hp-core`，且 threads.json 分支**没有过 8-9 闸门** | ①过滤含 `*` 的伪包名（AppOpt 精确匹配不命中，纯脏数据）②threads.json 派生规则也加 8-9 闸门 |
| **应用页卡「加载中」** | 点「应用」页永远停在加载中 | ①`appfreqapps` 逐包 fork 3 次 → 173 包要 **8 秒** ②`viewAppFreq` 无 try/catch，任一 `await` 抛错 → `renderAppFreq()` 永不执行 | ①重写为**单次 awk**（8s→1s）②三段各加 try/catch，失败也把错误显示在页面上 |
| **小程序归并组消失** | “微信小程序/支付宝小程序”组不见了 | `cmd_appfreqapps` 只列**启动器主包**（`query-activities LAUNCHER`），**不含 `:subprocess`**；而归并组靠同父包的多个子进程识别 | 应用列表**并入子进程**（`/proc` 运行中 + 配置文件里出现过的，过滤 `*`） |

### 5.1 「改配置回退默认」的系统性排查法（已踩两次，务必按此查）

解法是**逐层核对链路两端是否对齐**，而不是猜：

```
前端 Api.<方法>()  ──►  后端 case 注册的命令  ──►  写入的文件  ──►  读回用的文件
    ①缺方法→静默失败      ②缺命令→返回 err       ③没写进去       ④读的是别处（陈旧源）
```

四层自检（全绿才算通）：

```bash
# ① 前端：被调用的 Api 方法是否都有定义（差集必须为空）
node api_check.js
# ② 后端：前端用到的命令是否都在 case 分支注册
sh list_cmds.sh
# ③④ 写入 / 读回是否一致（连续写不同值，读回必须跟着变）
sh test_persist.sh
```

**红线**：任何「读回接口」都**不能**再依赖已停用引擎（`aether_ctl apps`）的数据——
它不随新引擎更新，会把界面永远钉在旧值上，表现就是「刷新后回退」。v19 已全部改走自有真值。

---

## 6. 文件职责

| 文件 | 职责 |
|---|---|
| `Scripts/4+4+2/O3/AppOpt` | 引擎二进制（v2.2.6，arm64，892KB） |
| `Scripts/4+4+2/O3/AppOpt-ebpf` | eBPF 程序（mode=0 自动且内核支持时由引擎加载；mode=2 纯 proc 时不使用） |
| `Scripts/4+4+2/O3/AppOpt.json` | 引擎设置：`mode:0`（自动：eBPF 事件驱动优先，不可用回退 /proc 轮询）、`web_enable:true`、`config_file`、`cpuset_name` |
| `Scripts/4+4+2/O3/o3lim.sh` | 配置生成器：维护 `applist.conf` 的**管理区段**（模式映射 + 默认档 + 8-9 闸门） |
| `service.sh` | 开机拉起 AppOpt（`-w` 开网页）+ 频率接管 + 守护 |
| `action.sh` | 模块「执行」按钮 → 拉起引擎 + 刷新管理区 + 打开 8889 |
| `Scripts/4+4+2/O3/webui.sh` | KSU WebUI 后端：频率档 + 模式分配 → `app_assign.tsv` → `o3lim gen` |
| `webroot/index.html` | KSU WebUI 前端（含「打开 AppOpt 网页」按钮） |
| `Scripts/4+4+2/O3/guard.sh` | 守护：频率兜底 + 引擎保活（aether 的 bigcore_lock 清扫已停用） |

---

## 7. 验证记录（真机 O3）

```
AppOpt: 运行中 (自动模式 mode=0 → 本机实测 eBPF 事件驱动)
8889: LISTEN ✓
/dev/cpuset/O3CPUSet/8-9/tasks = 0          ← 普通应用零 8-9 泄漏
com.tencent.mm   = 4-7 (流畅)               ← 用户意图正确落实
com.coolapk.market = 0-3 (省电)
com.android.camera = 无规则 (不接管)
com.tencent.tmgp.sgame = hp-core (8-9)      ← 游戏定死大核
applist.conf: 1444 条规则 / 重复包 0 / __REMOVE__ 0
热重载: 改 WebUI 模式 → 秒级生效，无需重启引擎
```
