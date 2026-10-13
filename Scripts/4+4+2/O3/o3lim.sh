#!/system/bin/sh
# ============================================================
#  o3lim.sh —— AppOpt 配置「管理区」生成器（O3 适配 · 语义核心版）
# ------------------------------------------------------------
#  架构（v19）：
#    · 线程引擎 = AppOpt 原生二进制（-w 开自带网页 127.0.0.1:8889）
#    · 唯一真值文件 = $CONF（applist.conf，AppOpt 原生格式）
#    · 分工不重叠：
#        - AppOpt 自带网页（8889）：用户全权编辑（块语法/通配线程/游戏大核），
#          写在「管理区」之外，本脚本永不触碰。
#        - 本脚本 / 我方 WebUI：只维护「管理区」那一段（注释标记包裹），
#          负责「应用→模式」的包级核位 + 未配置应用默认档 backfill + 8-9 闸门。
#    · 语义核心（AppOpt 原生）：e-core=小核(0-3) / p-core=中核(4-7)
#      / hp-core=大核(8-9) / all-core=全部。换设备不用改规则。
#    · 核位映射（O3 4+4+2）：
#        省电 powersave  → e-core          (0-3)
#        流畅 balance    → p-core          (4-7)
#        性能 performance→ e-core,p-core   (0-7)
#        极速 fast / none→ 不写（交系统调度，含 8-9 但引擎不强制）
#        游戏 game       → hp-core         (8-9)
# ============================================================
MODDIR="${MODDIR:-/data/adb/modules/O3CPUSet}"
STATE_DIR="${STATE_DIR:-/data/adb/O3CPUSet}"
CONF="$STATE_DIR/applist.conf"
UCONF="$STATE_DIR/o3lim.user.conf"
GAMELIST="$STATE_DIR/../Aether/gamelist"
ALLOW="$STATE_DIR/o3lim.allow"
LOG="$STATE_DIR/o3lim.log"

MARK_BEGIN="# ==== O3CPUSet-MANAGED-BEGIN ===="
MARK_END="# ==== O3CPUSet-MANAGED-END ===="

# 用户自定义游戏名单可能存在的位置（兼容历史路径）
GAMELIST_PATHS="$STATE_DIR/gamelist /sdcard/Android/Aether/gamelist"

log_quiet() { echo "$(date +%H:%M:%S) $*" >> "$LOG" 2>/dev/null; }

# ---------- 模式 → 语义核心（O3 4+4+2）----------
#   ⚠ v19.0.5 起 gen 的各来源已全部内联为单次 awk（见 gen_managed_section），
#     本函数与 is_allowed / core_has_big / _sect_put 仅作文档与外部查阅保留，
#     不再参与生成链路。
mode_to_core() {
  case "$1" in
    powersave)   echo "e-core" ;;
    balance)     echo "p-core" ;;
    performance) echo "e-core,p-core" ;;
    game)        echo "hp-core" ;;
    fast|none|"") echo "" ;;   # 不接管
    *)           echo "" ;;
  esac
}
# 语义核心 → 是否含大核（闸门判据）
core_has_big() { case "$1" in *hp-core*|*8*|*9*) return 0 ;; *) return 1 ;; esac; }

# ---------- OVR 覆盖（pkg<TAB>角色档）→ 语义核心 ----------
#   来源：① 模块内置种子 $MODDIR/Config/aether_overrides.tsv（出厂默认，如小红书=省电）
#         ② 运行时用户自定义 $STATE_DIR/aether_overrides.tsv（WebUI/前端 set 写入）
#   优先级：低于 WebUI 的 game_assign/app_assign（用户显式选择仍生效），
#           高于 threads.json 兜底源与默认 backfill（p-core）。
#   ★ 小红书等「省电」应用靠这里稳定落到 e-core(0-3)，不再依赖 aether_ctl deploy 是否跑过。
emit_ovr() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'\t' -v ALLOWF="$ALLOW" '
    BEGIN { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
    $1 ~ /^[a-zA-Z0-9._:]+$/ && $1 !~ /\*/ {
      role=$2; gsub(/[\r \t]/,"",role)
      core=""
      if (role=="powersave")        core="e-core"
      else if (role=="balance")     core="p-core"
      else if (role=="performance") core="e-core,p-core"
      else if (role=="game"||role=="fast") core="hp-core"
      else if (role=="none"||role=="") core=""
      if (core=="") next
      # 8-9 闸门：核位含 hp-core 且包非放行 → 收敛为 p-core
      if (core ~ /hp-core/ && !($1 in allow)) {
        gsub(/hp-core,?/,"",core); sub(/,$/,"",core)
        if (core=="") core="p-core"
      }
      print $1 "=" core
    }' "$f" 2>/dev/null </dev/null
}

# ---------- 放行判据（gamelist + 用户自定义 + apprules 含 8/9）----------
build_allow() {
  : > "$ALLOW"
  for g in $GAMELIST_PATHS; do
    [ -f "$g" ] && grep -v '^[[:space:]]*$' "$g" 2>/dev/null | grep -v '^#' >> "$ALLOW"
  done
  if [ -f "$STATE_DIR/apprules.tsv" ]; then
    awk -F'\t' 'NF>=2 && $2 ~ /[89]/{print $1}' "$STATE_DIR/apprules.tsv" >> "$ALLOW" 2>/dev/null
  fi
  if [ -f "$UCONF" ]; then
    sed -n 's/^{\?\([^{=]*\)[{=].*/\1/p' "$UCONF" 2>/dev/null | grep -v '^#' >> "$ALLOW"
  fi
  grep -v '^$' "$ALLOW" 2>/dev/null | sort -u > "${ALLOW}.t"
  mv "${ALLOW}.t" "$ALLOW" 2>/dev/null
}
# ---------- 纳管名单（v19.0.5 起停用）----------
#   旧版 backfill 用它把兜底限制在「有界面的应用」，v19 起兜底源改为
#   `pm list packages -3`（权威第三方包列表），本表已无人消费 ——
#   实测它每次 gen 白烧 8 次 fork（5×cut + grep + sort + mv），故整体移除。

# ---------- 管理区写入器 ----------
#  设计（v19.0.5 起）：每个来源用**单次 awk**直接 append 到 $out，全过程零
#  while-read 循环、零循环内 grep —— 旧实现的「逐行 is_allowed」是 gen 的头号耗时。
#  最终仍由 cmd_gen 用一次 awk 按「包名唯一、保留最后一条」去重（后写=高优先）。
_emit_col1() {  # $1=文件；取第一列 pkg 名（sort -u）
  awk -F'\t' 'NF>=1 && $1!="" && $1!~/^#/{print $1}' "$1" 2>/dev/null </dev/null | sort -u
}

# ---------- 生成「管理区」内容（扁平文件式；同一包名唯一，后写覆盖先写）----------
#  优先级（低 → 高）：threads.json < apprules.tsv < OVR覆盖表 < game_assign < app_assign(我方WebUI)
#  所有外部命令显式 </dev/null，防止 toybox 子进程继承管道 stdin 后阻塞。
#  ★ v19.0.5 性能：四个来源全部改为「单次 awk」产出。
#    旧实现是 while-read 循环里逐行 `is_allowed`（= 每条一次 grep fork），
#    apprules.tsv 393 行 + game/app_assign 73 行 → 450+ 次 fork；
#    threads.json 6844 行还被**完整解析两遍**（包级一趟 + comm 线程一趟）。
#    合并后每来源只剩 1 次 awk，gen 从 ~1.2s 降到 ~0.3s。
gen_managed_section() {
  local out="$1"
  local pkg mask mode gmode core
  # ★ v19.0.5：段头在这里一次写死（echo 是内建，0 fork），
  #   取代旧版「先建段内容 → 再段头+cat 拼接 + mv」（2 次 fork）。
  #   ⚠ 只写结构标记 MARK_BEGIN/END，不写「# 说明：本段由模块自动生成」等描述性注释 ——
  #      AppOpt 8889 网页会把注释行当成规则条目显示（v19.0.4 用户反馈过）。
  echo "$MARK_BEGIN" > "$out"

  # ③ 最低优先：threads.json 的历史核位（数字）→ 语义核心
  #    ★ v19.0.5：**一趟解析**同时产出两类规则（旧代码两趟全量解析）：
  #     · 包级：object 的 "other" 值 → packages[] 每个包（→ OUT1）
  #     · 线程级：comm 块 "0-3": ["Thread-1",...] → pkg{thread}（→ OUT2）
  #    8-9 闸门在同一趟 BEGIN 载入 allow 后内联完成。
  local THREADS="/sdcard/Android/Aether/threads.json"
  if [ -f "$THREADS" ]; then
    awk -v OUT1="${out}.th1" -v OUT2="${out}.th2" -v ALLOWF="$ALLOW" '
    function trimq(s){ if (match(s,/"[^"]*"/)) return substr(s, RSTART+1, RLENGTH-2); return ""; }
    function tosem(v,  a,b,hasE,hasP,hasH,n,i,t,s){
      hasE=0;hasP=0;hasH=0;
      n=split(v,b,",");
      for(i=1;i<=n;i++){ t=b[i];
        if(t ~ /^[0-9]+-[0-9]+$/){ split(t,a,"-");
          if(a[1]<=7 && a[2]>=8) hasH=1;
          if(a[1]<=3) hasE=1;
          if(a[2]>=4 && a[1]<=7) hasP=1; }
        else if(t ~ /^[0-9]+$/){ if(t>=8) hasH=1; else if(t>=4) hasP=1; else hasE=1; } }
      s="";
      if(hasE) s="e-core";
      if(hasP) s=(s==""?"":"")"p-core";
      if(hasH) s=(s==""?"":s",")"hp-core";
      return s;
    }
    function gate(p, v){   # 8-9 闸门：核位含 hp-core 且包非放行 → 收敛
      if (v ~ /hp-core/ && !(p in allow)) {
        gsub(/hp-core,?/,"",v); sub(/,$/,"",v); if (v=="") v="p-core"
      }
      return v
    }
    BEGIN {
      if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
    }
    /"packages"[ \t]*:[ \t]*\[/ { in_pk=1; npkg=0; next }
    in_pk && /^[ \t]*\]/ { in_pk=0; next }
    in_pk { q=trimq($0); if(q!="") pkg[npkg++]=q; next }
    /"comm"[ \t]*:[ \t]*\{/ { in_comm=1; next }
    in_comm && /^[ \t]*\}/ { in_comm=0; next }
    in_comm && /"[0-9][0-9,-]*"[ \t]*:[ \t]*\[/ { cm=trimq($0); in_arr=1; next }
    in_arr && /^[ \t]*\]/ { in_arr=0; next }
    in_arr { q=trimq($0); if(q!="") for(i=0;i<npkg;i++){ if (pkg[i] ~ /\*/) continue; s=tosem(cm); if(s!="") print pkg[i] "{" q "}=" gate(pkg[i], s) > OUT2 } next }
    /"other"[ \t]*:[ \t]*"/ { v=$0; sub(/^[^:]*:[ \t]*/,"",v); om=trimq(v)
      if (om != "" && om != "other") for(i=0;i<npkg;i++){
        if (pkg[i] ~ /\*/) continue          # ⚠ 含 * 的通配伪包名：AppOpt 精确匹配不会命中，丢弃
        s=tosem(om); if(s!="") print pkg[i] "=" gate(pkg[i], s) > OUT1 } om=""; next }
    /^[ \t]*\}/ { npkg=0 }
    ' "$THREADS" 2>/dev/null </dev/null
    # 线程规则（comm）保留原优先级：包级规则在前、线程规则在后（均不参与包级去重）
    [ -s "${out}.th1" ] && { sort -u "${out}.th1" >> "$out"; rm -f "${out}.th1"; }
    [ -s "${out}.th2" ] && { sort -u "${out}.th2" >> "$out"; rm -f "${out}.th2"; }
  fi

  # ② apprules.tsv（历史真值：pkg<TAB>核位）→ 语义核心
  #    ★ v19.0.5：单次 awk（allow 预载入 BEGIN），取代「393 行 × 逐行 grep ALLOW」。
  if [ -f "$STATE_DIR/apprules.tsv" ]; then
    awk -F'\t' -v ALLOWF="$ALLOW" '
    BEGIN { if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) } }
    $1 ~ /^[[:space:]]*$/ || $1 ~ /^#/ { next }
    $2 ~ /^[0-9]/ {
      pkg=$1; mask=$2
      # ⚠ 0-9 / all → 不接管（不写规则，交系统调度）；只有含 8-9 的才可能 hp-core
      if (mask=="0-9" || mask=="all" || mask=="all-core") next
      else if (mask=="0-3") print pkg "=e-core"
      else if (mask=="4-7") print pkg "=p-core"
      else if (mask=="0-7" || mask=="0-3,4-7" || mask=="0-5") print pkg "=e-core,p-core"
      else {
        core = (mask ~ /8-9|8,9/) ? ((pkg in allow) ? "hp-core" : "p-core") : "p-core"
        print pkg "=" core
      }
    }' "$STATE_DIR/apprules.tsv" 2>/dev/null </dev/null | sort -u >> "$out"
  fi

  # ②b 覆盖档（OVR 风格：模块内置种子 + 运行时用户自定义）→ 语义核心
  #    优先级低于 WebUI 的 game_assign/app_assign，高于 threads.json 兜底与默认 backfill。
  #    ★ 小红书等「省电」应用在此稳定落 e-core(0-3)，不再依赖 aether_ctl deploy 是否跑过。
  emit_ovr "$MODDIR/Config/aether_overrides.tsv" >> "$out"
  emit_ovr "$STATE_DIR/aether_overrides.tsv"    >> "$out"

  # ① 高优先：游戏表 game_assign.tsv（pkg<TAB>mode）→ 按其模式映射
  #    游戏档 performance/game/空 → hp-core（8-9 定死大核）；balance → p-core；powersave → e-core
  #    ★ v19.0.5：单次 awk（allow 预载入 BEGIN）。
  if [ -f "$STATE_DIR/webui/game_assign.tsv" ]; then
    awk -F'\t' -v ALLOWF="$ALLOW" '
    BEGIN { if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) } }
    NF>=2 && $1!="" && $1 !~ /^#/ {
      pkg=$1; gmode=$2
      if (gmode=="" || gmode=="game" || gmode=="performance" || gmode=="fast") core="hp-core"
      else if (gmode=="balance") core="p-core"
      else if (gmode=="powersave") core="e-core"
      else if (gmode=="none") next
      else core="hp-core"
      # 闸门：hp-core 仅放行包可用
      if (core=="hp-core" && !(pkg in allow)) core="p-core"
      print pkg "=" core
    }' "$STATE_DIR/webui/game_assign.tsv" 2>/dev/null </dev/null | sort -u >> "$out"
  fi

  # ① 最高优先：我方 WebUI「应用」页分配的模式（pkg<TAB>mode）
  #    ★ v19.0.5：单次 awk（allow 预载入 BEGIN）。
  if [ -f "$STATE_DIR/webui/app_assign.tsv" ]; then
    awk -F'\t' -v ALLOWF="$ALLOW" '
    BEGIN { if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) } }
    NF>=2 && $1!="" && $1 !~ /^#/ {
      pkg=$1; mode=$2
      if (mode=="auto" || mode=="") next
      core=""
      if (mode=="powersave") core="e-core"
      else if (mode=="balance") core="p-core"
      else if (mode=="performance") core="e-core,p-core"
      else if (mode=="game") core="hp-core"
      # 游戏（放行包）在「性能/极速」档 → 定死大核 hp-core（契合游戏需求）
      if ((pkg in allow) && (mode=="performance" || mode=="fast" || mode=="game")) core="hp-core"
      if (core=="") {
        # 极速/none → 不接管：标记删除（去重阶段丢弃 __REMOVE__）
        print pkg "=__REMOVE__"; next
      }
      # 闸门：hp-core 仅放行包可用
      if (core=="hp-core" && !(pkg in allow)) core="p-core"
      print pkg "=" core
    }' "$STATE_DIR/webui/app_assign.tsv" 2>/dev/null </dev/null | sort -u >> "$out"
  fi
}

# ---------- 把管理区写进 $CONF（段外原样保留）----------
cmd_gen() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  build_allow

  local sec="${STATE_DIR}/.o3lim.section"
  gen_managed_section "$sec"

  # ★ 联动：提前抽取「未管理段」（8889 网页写的规则，管理区标记之外的内容）到 $base，
  #   供下方 ① 兜底 backfill 跳过已在 8889 配过的包、② 末尾组装时剥离「不接管」包在 8889 的同包规则。
  #   ★ v19.0.5：sed 摘段 + awk 去尾空行合并为**一趟 awk**（省 1 次 fork）；
  #     段头行（BEGIN/END 标记）与旧版 sed 口径一致：整行删除。
  local base="${STATE_DIR}/.o3lim.base"
  : > "$base"
  if [ -f "$CONF" ]; then
    awk -v B="$MARK_BEGIN" -v E="$MARK_END" '
      $0==B { inm=1; next }
      $0==E { inm=0; next }
      !inm  { l[++n]=$0; if (NF) last=n }
      END   { for (i=1;i<=last;i++) print l[i] }
    ' "$CONF" > "$base" 2>/dev/null
  fi

  # ============================================================
  #  兜底规则（用户要求，v19）：
  #    · 未定义配置的进程 → 频率「跟随全局」（不在 app_freq.tsv 里写档 = guard 保持不变
  #      即全局模式）、线程「流畅」(p-core = 中核 4-7)。
  #    · 已在管理区里有规则的包不覆盖；被标 __REMOVE__（不接管）的包不补默认。
  #  实现：对「有界面的第三方应用」逐个补 `pkg=p-core`（仅当尚未有规则）。
  #  ★ v19.0.5 性能：
  #    ① pm list 带 60s TTL 缓存（冷路径 pm 是 binder 调用，可达数百 ms）；
  #    ② 「已配 / 8889已配 / 不接管 / 放行」四项判定合并为**单次 awk**
  #       （旧实现 181 个包 × 3~4 次 grep fork，是 gen 的头号耗时）。
  #    ③ 判定口径比旧版更严：旧版 grep -qF "${p}=" 是子串匹配（xcom.foo= 会误中
  #       com.foo=），awk 版按「行首 pkg= / pkg{」精确匹配。
  # ============================================================
  local PMLC="${STATE_DIR}/.pmlist.cache"
  if command -v find >/dev/null 2>&1 && [ -s "$PMLC" ] \
     && [ -z "$(find "$PMLC" -mmin +1 2>/dev/null)" ]; then
    cp -f "$PMLC" "${sec}.pk" 2>/dev/null
  else
    pm list packages -3 2>/dev/null </dev/null | cut -d: -f2 > "${sec}.pk" 2>/dev/null
    [ -s "${sec}.pk" ] && cp -f "${sec}.pk" "$PMLC" 2>/dev/null
  fi
  sed -n 's/^\([^=]*\)=__REMOVE__$/\1/p' "$sec" 2>/dev/null | sort -u > "${sec}.rm"
  awk -v SEC="$sec" -v BASE="$base" -v ALLOWF="$ALLOW" -v RMF="${sec}.rm" -v CNTF="${sec}.n" '
    BEGIN {
      if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
      while ((getline r < RMF) > 0) { gsub(/[ \t\r]/,"",r); if (r!="") rm[r]=1 } close(RMF)
      # 管理区已有规则的包（含线程规则 pkg{...} 与子进程规则 pkg:sub）
      while ((getline l < SEC) > 0) {
        if (l ~ /^[[:space:]]*#/ || l=="") continue
        p=l; sub(/=.*$/,"",p); sub(/\{.*$/,"",p); if (p!="") secpkg[p]=1
      } close(SEC)
      # ★ 联动：8889 未管理段里已存在的包规则不补默认，避免兜底覆盖网页里设的档位
      while ((getline l < BASE) > 0) {
        if (l ~ /^[[:space:]]*#/ || l=="") continue
        p=l; sub(/=.*$/,"",p); sub(/\{.*$/,"",p); if (p!="") basepkg[p]=1
      } close(BASE)
    }
    { p=$1; if (p=="") next
      if (p in secpkg)  next
      if (p in rm)      next
      if (p in basepkg) next
      if (p in allow)   next
      print p "=p-core"; n++ }
    END { print n+0 > CNTF }
  ' "${sec}.pk" >> "$sec" 2>/dev/null
  local n_def; n_def=$(cat "${sec}.n" 2>/dev/null); [ -z "$n_def" ] && n_def=0
  rm -f "${sec}.pk" "${sec}.rm" "${sec}.n"
  [ "$n_def" -gt 0 ] && log_quiet "gen: 兜底 '流畅(p-core)' 应用 $n_def 个"

  # ★★ 子进程展开（v19 关键修复）：
  #    AppOpt 的包名匹配是**精确匹配**（cfg.pkgs 是 HashSet），配置 `com.coolapk.market=...`
  #    **不会**作用到 `com.coolapk.market:xg_vip_service` → 子进程仍留在系统 top-app(0-9)
  #    → 表现「省电应用照样上 8-9」。这里为每个已配包名的**已知子进程**补一条同核位规则。
  #    子进程来源：/proc 运行中 + app_freq/app_assign/applist 里出现过的（持久）。
  local subs="${STATE_DIR}/.o3lim.subs"
  local sub_files=""
  local _f
  for _f in "$STATE_DIR/webui/app_freq.tsv" "$STATE_DIR/webui/app_assign.tsv" "$CONF"; do
    [ -f "$_f" ] && sub_files="$sub_files $_f"
  done
  {
    # ★ v19.0.5：一次 `cat | tr` 读完全部 cmdline（旧实现逐 PID fork tr+head，
    #   ~500 进程 ≈ 1000 次 fork；新实现一趟 ~40ms）。
    #   只收「像进程名」且含 ':' 的行（子进程名形如 com.tencent.mm:appbrand0）；
    #   行首字母 + 仅 [A-Za-z0-9._:-] 的过滤顺带排掉参数行（URL 含 / 等）。
    cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' 2>/dev/null \
      | grep -E '^[A-Za-z][A-Za-z0-9._:-]*:' 2>/dev/null
    # 持久来源（历史配置里出现过的子进程名）三个文件合并为**一次 awk**
    [ -n "$sub_files" ] && awk -F'[=\t]' '$1 ~ /:/{print $1}' $sub_files 2>/dev/null
  # ⚠ 过滤：含 * 的通配伪包名（如 `com.tencent.mm:appbrand*`）不是真进程名，
  #   AppOpt 精确匹配不会命中，写进去只会造成脏数据和误判。
  } | grep -v '^[[:space:]]*$' | grep -v '\*' | sort -u > "$subs" 2>/dev/null

  if [ -s "$subs" ]; then
    awk -v SUBS="$subs" -v ALLOWF="$ALLOW" '
      BEGIN {
        while ((getline l < SUBS) > 0) {
          gsub(/[ \t\r]/,"",l); if (l=="") continue
          par = l; sub(/:.*$/,"",par)
          subs[par] = subs[par] (subs[par]==""?"":"\n") l
        }
        close(SUBS)
        if (ALLOWF != "") { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
      }
      /^[[:space:]]*#/ || $0=="" { next }
      {
        line=$0
        p=line; sub(/=.*$/,"",p)
        v=line; sub(/^[^=]*=/,"",v)
        if (p ~ /:/) { seen[p]=1; next }    # 子进程规则只记 seen，不参与 mode
        if (index(line,"{")>0) next
        mode[p]=v                           # 只有包级规则决定扩展核位（后写=高优先，与去重口径一致）
      }
      END {
        for (b in mode) {
          if (mode[b]=="__REMOVE__") continue
          if (!(b in subs)) continue
          # ★ 8-9 闸门：核位含 hp-core 且父包非放行 → 收敛为 p-core（普通应用不上大核）
          v = mode[b]
          if (v ~ /hp-core/ && !(b in allow)) {
            gsub(/hp-core,?/,"",v); sub(/,$/,"",v)
            if (v=="") v="p-core"
          }
          n=split(subs[b], arr, "\n")
          for (i=1;i<=n;i++) {
            s=arr[i]
            if (s=="" || s==b) continue
            if (s in seen) continue
            print s "=" v
          }
        }
      }
    ' "$sec" >> "$sec" 2>/dev/null
    rm -f "$subs"
  fi

  # ★★ 去重 + 线程名通配 + 冗余线程规则剔除（v19.0.5 三合一，一趟 awk 完成）：
  #   【去重】同一包名只保留最后一条（最后写=最高优先）；`pkg=__REMOVE__` 的包整包删除
  #    （含其线程规则 —— 否则「不接管」会被 threads.json 历史 comm 规则打穿）。
  #   【通配】AppOpt 对**线程名**支持 fnmatch（rule_match.rs 用 libc::fnmatch），包名**只支持精确匹配**
  #    （config.rs: pkgs = HashSet<字面包名>；实测通配包名 hit_pkgs=0），所以：
  #      · 线程级漏网 → 用 `{*Thread*}` 一条通配覆盖 RenderThread / Thread-x / *thread* 全部
  #      · 包级漏网   → 只能靠「子进程枚举」（见上一步）
  #    精简依据（实测）：
  #      · `{*Thread*}` 已同时覆盖原来的 `{*Thread}` 与 `{Thread*}` → 删掉后者
  #      · 包级规则本身就把 binder/其他线程绑到同档（实测 binder:xxx=0-3），
  #        所以 `{binder*}` 冗余 → 删掉
  #    结果：每个「显式配置过」的包只多 1 条线程规则（原 3 条）。
  #   【剔冗余】包级规则会把该包**所有线程**绑到同档（正是上面删 {binder*} 的依据）
  #    ⇒「具体线程名」且核位与包级**生效核位相同**的线程规则是纯冗余，只会拖慢引擎
  #    重载、把 8889 网页撑到上千条。实测设备 924 条线程规则里 393 条属于此类。
  #    通配规则（{*Thread*} 等）不动 —— 保留原有语义，不改变任何生效核位。
  awk -v ALLOWF="$ALLOW" -v ASSIGNF="$STATE_DIR/webui/app_assign.tsv" -v GAMEF="$STATE_DIR/webui/game_assign.tsv" '
    BEGIN {
      while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF)
      while ((getline b < ASSIGNF) > 0) { split(b,f,"\t"); if (f[1]!="") explicit[f[1]]=1 } close(ASSIGNF)
      while ((getline c < GAMEF) > 0) { split(c,g,"\t"); if (g[1]!="") explicit[g[1]]=1 } close(GAMEF)
    }
    { lines[NR]=$0
      if ($0 ~ /^[[:space:]]*#/ || $0=="") { special[NR]=1; next }   # 注释/空行（含 BEGIN 标记）原样保留
      if (index($0,"{")>0) {                           # 已有线程规则：记账，END 段判冗余
        pk=$0; sub(/\{.*$/,"",pk)
        v=$0;  sub(/^[^=]*=/,"",v)
        th=$0; sub(/^[^{]*{/,"",th); sub(/\}.*$/,"",th)
        thrpk[NR]=pk; thrval[NR]=v; thrwild[NR]=(th ~ /\*/)?1:0
        next
      }
      pk=$0; sub(/=.*$/,"",pk); v=$0; sub(/^[^=]*=/,"",v)
      lastline[pk]=NR; lastval[pk]=v                   # 去重：同包只保留最后一条
      # 线程通配只给显式配置的包（兜底档不加，避免膨胀）
      # ⚠ v19.0.5：通配值随每条规则更新（末条生效）—— 与去重口径一致，
      #    否则「threads.json 旧值 + 用户后改档」的包会出现 pkg=p-core 但 {*Thread*}=e-core 的撕裂。
      if (v!="" && v!="__REMOVE__" && (pk in explicit)) {
        wt=v
        if (wt ~ /hp-core/ && !(pk in allow)) { gsub(/hp-core,?/,"",wt); sub(/,$/,"",wt); if (wt=="") wt="p-core" }
        wildline[pk]=pk "{*Thread*}=" wt               # 一条覆盖所有含 Thread/thread 的线程名
      }
    }
    END {
      for (i=1;i<=NR;i++) {
        if (i in special) { print lines[i]; continue }   # 注释/空行原样保留（含 BEGIN 标记）
        if (i in thrpk) {
          p=thrpk[i]; v=thrval[i]
          if (p in lastval && lastval[p]=="__REMOVE__") continue              # 不接管的包：线程规则一并删
          if (!thrwild[i] && (p in lastval) && lastval[p]==v) continue        # 冗余线程规则 → 丢弃
          print lines[i]; continue
        }
        p=lines[i]; sub(/=.*$/,"",p)
        if (lastline[p]!=i) continue                    # 去重：同包非末条 → 丢弃
        if (lastval[p]=="__REMOVE__") continue          # 不接管：整包删除
        print lines[i]
        if (p in wildline) { print wildline[p]; delete wildline[p] }
      }
    }' "$sec" > "${sec}.tw" 2>/dev/null
  if [ -s "${sec}.tw" ]; then mv -f "${sec}.tw" "$sec" 2>/dev/null; else rm -f "${sec}.tw"; fi

  echo "$MARK_END" >> "$sec"

  # 组装：把未管理段($base，已在 gen 开头从 $CONF 摘出管理区得到，此处复用，不再重读 $CONF)
  #   里的「不接管」包同包规则剥离后，追加新管理段（段外保留）。
  # ★ 联动：模块 WebUI 设「不接管(fast/none)」的包，连 8889 未管理段里的同包规则也一并移除，
  #   否则 8889 的同包规则会盖过「不接管」（8889 段在文件前面、managed 段里该包无规则 → 引擎用 8889 的）。
  #   模块 WebUI 设了具体档位的包无需剥离：managed 段（靠后）会盖过 8889 段，已生效。
  # ★ v19.0.5：剥离 + 去尾空行 + 拼接 + 计数合并为**一趟 awk**（旧实现 4 次 fork：
  #   rmbase awk + trim awk + grep -q 校验 + grep -c 计数）。
  local rmf="${STATE_DIR}/.o3lim.rmbase"; : > "$rmf"
  [ -f "$STATE_DIR/webui/app_assign.tsv" ] && \
    awk -F'\t' 'NF>=2 && ($2=="fast"||$2=="none"){print $1}' "$STATE_DIR/webui/app_assign.tsv" >> "$rmf" 2>/dev/null
  local cntf="${STATE_DIR}/.o3lim.cnt"
  awk -v RM="$rmf" -v NEW="${CONF}.new" -v CNT="$cntf" -v BASE="$base" '
    BEGIN {
      while ((getline r < RM) > 0) { gsub(/[ \t\r]/,"",r); if (r!="") rm[r]=1 } close(RM)
      nb=0
      while ((getline l < BASE) > 0) {
        p=l; sub(/=.*$/,"",p); sub(/\{.*$/,"",p); if (p in rm) next
        print l > NEW; if (index(l,"=")>0) n++; nb++
      }
      close(BASE)
      if (nb>0) print "" > NEW        # base 非空 → 空行分隔（与旧版 { cat base; echo ""; cat sec } 一致）
    }
    { print > NEW; if (index($0,"=")>0) n++ }
    END { print n+0 > CNT }
  ' "$sec" 2>/dev/null
  rm -f "$rmf"
  local total; total=$(cat "$cntf" 2>/dev/null); [ -z "$total" ] && total=0
  rm -f "$cntf"
  # ★ 原子发布：只在 .new 非空且有规则时才 mv 覆盖，避免 AppOpt inotify 读到空文件
  if [ -s "${CONF}.new" ] && [ "$total" -gt 0 ] 2>/dev/null; then
    mv -f "${CONF}.new" "$CONF" 2>/dev/null
  else
    rm -f "${CONF}.new" 2>/dev/null
    log_quiet "gen: 结果为空/无规则，放弃覆盖（保留旧配置）"
  fi
  chmod 0666 "$CONF" 2>/dev/null
  rm -f "$sec" "$base"

  echo "OK 已刷新管理区：${total} 条总规则"
}

# ---------- boot：确保配置文件存在 ----------
cmd_boot() {
  if [ ! -f "$CONF" ]; then
    # ★ 原子创建（先写 .new 再 mv），避免 AppOpt 在写入中途读到空文件
    #   ⚠ 不写任何描述性注释头：AppOpt 8889 网页会把注释行当成规则条目显示，
    #      曾有用户反馈看到「#说明 本模块自动生成」等字样。结构标记由 cmd_gen 写入。
    : > "${CONF}.new"
    mv -f "${CONF}.new" "$CONF" 2>/dev/null
  fi
  cmd_gen
  log_quiet "boot: applist.conf 管理区就绪"
}

# ---------- restore：停 AppOpt + 清理其 cpuset ----------
cmd_restore() {
  pkill -f AppOpt 2>/dev/null
  local g t
  for g in /dev/cpuset/O3CPUSet/*/ /dev/cpuset/AppOpt/*/; do
    g="${g%/}"
    [ -r "$g/tasks" ] && while read -r t; do
      [ -n "$t" ] && echo "$t" > /dev/cpuset/top-app/tasks 2>/dev/null
    done < "$g/tasks"
  done
  rm -rf /dev/cpuset/O3CPUSet /dev/cpuset/AppOpt 2>/dev/null
  echo "OK restore: AppOpt 已停，其 cpuset 组已清理"
}

cmd_status() {
  echo "=== 配置 ==="
  echo "  文件: $CONF"
  echo "  总规则: $(grep -c '=' "$CONF" 2>/dev/null)  放行: $(wc -l < "$ALLOW" 2>/dev/null)"
  echo "=== AppOpt ==="
  if pgrep -f AppOpt >/dev/null 2>&1; then echo "  运行中"; else echo "  未运行"; fi
  echo "=== 管理区（前 20） ==="
  sed -n "/$(echo "$MARK_BEGIN" | sed 's/[][\\.*^$]/\\&/g')/,/$(echo "$MARK_END" | sed 's/[][\\.*^$]/\\&/g')/p" "$CONF" 2>/dev/null | head -20
  echo "=== 日志尾 ==="; tail -5 "$LOG" 2>/dev/null
}

case "$1" in
  gen)     cmd_gen ;;
  boot)    cmd_boot ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
  *) echo "usage: o3lim.sh gen|boot|restore|status" ;;
esac
