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
MANAGE="$STATE_DIR/.o3lim.manage"
LOG="$STATE_DIR/o3lim.log"

MARK_BEGIN="# ==== O3CPUSet-MANAGED-BEGIN ===="
MARK_END="# ==== O3CPUSet-MANAGED-END ===="

# 用户自定义游戏名单可能存在的位置（兼容历史路径）
GAMELIST_PATHS="$STATE_DIR/gamelist /sdcard/Android/Aether/gamelist"

log_quiet() { echo "$(date +%H:%M:%S) $*" >> "$LOG" 2>/dev/null; }

# ---------- 模式 → 语义核心（O3 4+4+2）----------
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
is_allowed() { [ -s "$ALLOW" ] && grep -qx "$1" "$ALLOW" 2>/dev/null </dev/null; }

# ---------- 纳管名单：只管「有界面的应用」+ 已有规则 ----------
build_manage_list() {
  : > "$MANAGE"
  [ -f "$STATE_DIR/webui/pkg_labels.tsv" ] && cut -f1 "$STATE_DIR/webui/pkg_labels.tsv" 2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/webui/app_freq.tsv" ]  && cut -f1 "$STATE_DIR/webui/app_freq.tsv"  2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/webui/app_assign.tsv" ] && cut -f1 "$STATE_DIR/webui/app_assign.tsv" 2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/webui/game_assign.tsv" ] && cut -f1 "$STATE_DIR/webui/game_assign.tsv" 2>/dev/null >> "$MANAGE"
  [ -f "$STATE_DIR/apprules.tsv" ]        && cut -f1 "$STATE_DIR/apprules.tsv"        2>/dev/null >> "$MANAGE"
  grep -v '^$' "$MANAGE" 2>/dev/null | sort -u > "${MANAGE}.t"
  mv "${MANAGE}.t" "$MANAGE" 2>/dev/null
}

# ---------- 管理区写入器 ----------
#  设计：不做「逐行 grep 删除」，只**顺序追加**到文件；最后由 cmd_gen 用一次 awk
#  按「包名唯一、保留最后一条」去重（后写=高优先）。这样彻底避免在 while-read
#  循环里 spawn 子进程（实测：在循环里跑 grep 会因继承 FD/管道的 stdin 而阻塞）。
_sect_put() {   # $1=目标文件 $2=规则行
  [ -n "$2" ] && printf '%s\n' "$2" >> "$1"
}
# 从只读来源文件里逐行取「pkg<TAB>...」的第一列，回调输出（用 awk 一次性完成，
# 避免 shell while-read 里 spawn 命令）
_emit_col1() {  # $1=文件 $2=输出到 stdout 的前缀模板（"p=%s" 形式用 printf）
  awk -F'\t' 'NF>=1 && $1!="" && $1!~/^#/{print $1}' "$1" 2>/dev/null </dev/null | sort -u
}

# ---------- 生成「管理区」内容（扁平文件式；同一包名唯一，后写覆盖先写）----------
#  优先级（低 → 高）：threads.json < apprules.tsv < game_assign < app_assign(我方WebUI)
#  所有外部命令显式 </dev/null，防止 toybox 子进程继承管道 stdin 后阻塞。
gen_managed_section() {
  local out="$1"
  local pkg mask mode gmode core
  : > "$out"

  # ③ 最低优先：threads.json 的历史核位（数字）→ 语义核心
  local THREADS="/sdcard/Android/Aether/threads.json"
  if [ -f "$THREADS" ]; then
    awk '
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
    /"packages"[ \t]*:[ \t]*\[/ { in_pk=1; npkg=0; next }
    in_pk && /^[ \t]*\]/ { in_pk=0; next }
    in_pk { q=trimq($0); if(q!="") pkg[npkg++]=q; next }
    /"other"[ \t]*:[ \t]*"/ { v=$0; sub(/^[^:]*:[ \t]*/,"",v); om=trimq(v)
      if (om != "" && om != "other") for(i=0;i<npkg;i++){
        if (pkg[i] ~ /\*/) continue          # ⚠ 含 * 的通配伪包名：AppOpt 精确匹配不会命中，丢弃
        s=tosem(om); if(s!="") print pkg[i] "=" s } om=""; next }
    /^[ \t]*\}/ { npkg=0 }
    ' "$THREADS" 2>/dev/null </dev/null | sort -u > "${out}.th1"
    # ★ 8-9 闸门：threads.json 派生的核位含 hp-core 且包非放行 → 收敛 p-core
    #   （历史 threads.json 里存在 `pkg:*` 通配 + 0-3,4-7,8-9 的条目，
    #     会把普通应用/子进程漏到 8-9 —— 用户明确要求普通应用不得上 8-9）
    if [ -s "${out}.th1" ]; then
      awk -v ALLOWF="$ALLOW" '
        BEGIN { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
        {
          line=$0; p=line; sub(/=.*$/,"",p)
          v=line; sub(/^[^=]*=/,"",v)
          if (v ~ /hp-core/ && !(p in allow)) {
            gsub(/hp-core,?/,"",v); sub(/,$/,"",v); if (v=="") v="p-core"
          }
          print p "=" v
        }
      ' "${out}.th1" > "${out}.th1g" 2>/dev/null
      mv -f "${out}.th1g" "${out}.th1" 2>/dev/null
    fi
    while IFS= read -r line; do _sect_put "$out" "$line"; done < "${out}.th1"
    rm -f "${out}.th1"

    # threads.json 的 comm 线程规则（pkg{thread}=core）保留（不参与包级覆盖）
    awk '
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
      s=""; if(hasE) s="e-core"; if(hasP) s=(s==""?"":"")"p-core"; if(hasH) s=(s==""?"":s",")"hp-core";
      return s;
    }
    /"packages"[ \t]*:[ \t]*\[/ { in_pk=1; npkg=0; next }
    in_pk && /^[ \t]*\]/ { in_pk=0; next }
    in_pk { q=trimq($0); if(q!="") pkg[npkg++]=q; next }
    /"comm"[ \t]*:[ \t]*\{/ { in_comm=1; next }
    in_comm && /^[ \t]*\}/ { in_comm=0; next }
    in_comm && /"[0-9][0-9,-]*"[ \t]*:[ \t]*\[/ { cm=trimq($0); in_arr=1; next }
    in_arr && /^[ \t]*\]/ { in_arr=0; next }
    in_arr { q=trimq($0); if(q!="") for(i=0;i<npkg;i++){ if (pkg[i] ~ /\*/) continue; s=tosem(cm); if(s!="") print pkg[i] "{" q "}=" s } next }
    /^[ \t]*\}/ { npkg=0 }
    ' "$THREADS" 2>/dev/null </dev/null | sort -u > "${out}.th2"
    # 线程规则同样过 8-9 闸门（非放行包不得含 hp-core）
    if [ -s "${out}.th2" ]; then
      awk -v ALLOWF="$ALLOW" '
        BEGIN { while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF) }
        {
          line=$0
          pk=line; sub(/\{.*$/,"",pk)
          v=line; sub(/^[^=]*=/,"",v)
          if (v ~ /hp-core/ && !(pk in allow)) {
            gsub(/hp-core,?/,"",v); sub(/,$/,"",v)
            if (v=="") v="p-core"
            sub(/=.*$/,"",line); line=line "=" v
          }
          print line
        }
      ' "${out}.th2" >> "$out" 2>/dev/null
      rm -f "${out}.th2"
    fi
  fi

  # ② apprules.tsv（历史真值：pkg<TAB>核位）→ 语义核心
  if [ -f "$STATE_DIR/apprules.tsv" ]; then
    cut -f1,2 "$STATE_DIR/apprules.tsv" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^#' | grep -E '^[^	]+	[0-9]' | sort -u > "${out}.r"
    while IFS='	' read -r pkg mask; do
      [ -z "$pkg" ] && continue
      # ⚠ 0-9 / all → 不接管（不写规则，交系统调度）；只有纯 8-9 才是 hp-core
      case "$mask" in
        0-9|all|all-core) continue ;;
        0-3)             _sect_put "$out" "${pkg}=e-core" ;;
        4-7)             _sect_put "$out" "${pkg}=p-core" ;;
        0-7|0-3,4-7|0-5) _sect_put "$out" "${pkg}=e-core,p-core" ;;
        8-9|8,9)         if is_allowed "$pkg"; then _sect_put "$out" "${pkg}=hp-core"; else _sect_put "$out" "${pkg}=p-core"; fi ;;
        *8-9*|*8,9*)     if is_allowed "$pkg"; then _sect_put "$out" "${pkg}=hp-core"; else _sect_put "$out" "${pkg}=p-core"; fi ;;
        *)               _sect_put "$out" "${pkg}=p-core" ;;
      esac
    done < "${out}.r"
    rm -f "${out}.r"
  fi

  # ②b 覆盖档（OVR 风格：模块内置种子 + 运行时用户自定义）→ 语义核心
  #    优先级低于 WebUI 的 game_assign/app_assign，高于 threads.json 兜底与默认 backfill。
  #    ★ 小红书等「省电」应用在此稳定落 e-core(0-3)，不再依赖 aether_ctl deploy 是否跑过。
  emit_ovr "$MODDIR/Config/aether_overrides.tsv" >> "$out"
  emit_ovr "$STATE_DIR/aether_overrides.tsv"    >> "$out"

  # ① 高优先：游戏表 game_assign.tsv（pkg<TAB>mode）→ 按其模式映射
  #    游戏档 performance/game/空 → hp-core（8-9 定死大核）；balance → p-core；powersave → e-core
  if [ -f "$STATE_DIR/webui/game_assign.tsv" ]; then
    cut -f1,2 "$STATE_DIR/webui/game_assign.tsv" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^#' | sort -u > "${out}.g"
    while IFS='	' read -r pkg gmode; do
      [ -z "$pkg" ] && continue
      case "$gmode" in
        ""|game|performance|fast) core="hp-core" ;;
        balance)                  core="p-core" ;;
        powersave)                core="e-core" ;;
        none)                     continue ;;
        *)                        core="hp-core" ;;
      esac
      # 闸门：hp-core 仅放行包可用
      if [ "$core" = "hp-core" ] && ! is_allowed "$pkg"; then core="p-core"; fi
      _sect_put "$out" "${pkg}=${core}"
    done < "${out}.g"
    rm -f "${out}.g"
  fi

  # ① 最高优先：我方 WebUI「应用」页分配的模式（pkg<TAB>mode）
  if [ -f "$STATE_DIR/webui/app_assign.tsv" ]; then
    cut -f1,2 "$STATE_DIR/webui/app_assign.tsv" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^#' | sort -u > "${out}.a"
    while IFS='	' read -r pkg mode; do
      [ -z "$pkg" ] && continue
      case "$mode" in
        auto|"") continue ;;
      esac
      core=$(mode_to_core "$mode")
      # 游戏（放行包）在「性能/极速」档 → 定死大核 hp-core（8-9，契合游戏需求）
      if is_allowed "$pkg"; then
        case "$mode" in performance|fast|game) core="hp-core" ;; esac
      fi
      if [ -z "$core" ]; then
        # 极速/none → 不接管：标记删除（去重阶段丢弃 __REMOVE__）
        _sect_put "$out" "${pkg}=__REMOVE__"
        continue
      fi
      # 闸门：hp-core 仅放行包可用
      if [ "$core" = "hp-core" ] && ! is_allowed "$pkg"; then core="p-core"; fi
      _sect_put "$out" "${pkg}=${core}"
    done < "${out}.a"
    rm -f "${out}.a"
  fi
}

# ---------- 把管理区写进 $CONF（段外原样保留）----------
cmd_gen() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  build_allow
  build_manage_list

  local sec="${STATE_DIR}/.o3lim.section"
  # ⚠ 必须先让 gen_managed_section 建/清空文件（它内部会 : > "$out"），
  #   再写段头！否则段头会被它截断掉（曾因此丢了 BEGIN 标记 → 每次 gen 都重复累积）。
  gen_managed_section "$sec"

  # ★ 联动：提前抽取「未管理段」（8889 网页写的规则，管理区标记之外的内容）到 $base，
  #   供下方 ① 兜底 backfill 跳过已在 8889 配过的包、② 末尾组装时剥离「不接管」包在 8889 的同包规则。
  local base="${STATE_DIR}/.o3lim.base"
  : > "$base"
  if [ -f "$CONF" ]; then
    sed '/^# ==== O3CPUSet-MANAGED-BEGIN ====$/,/^# ==== O3CPUSet-MANAGED-END ====$/d' "$CONF" > "$base" 2>/dev/null
  fi
  awk 'NF{last=NR} {l[NR]=$0} END{for(i=1;i<=last;i++) print l[i]}' "$base" > "${base}.t" 2>/dev/null
  mv "${base}.t" "$base" 2>/dev/null

  # 段头插到最前：先暂存再拼接
  #   ⚠ 只保留结构标记 MARK_BEGIN/END；不再写「# 说明：本段由模块自动生成」等描述性注释，
  #      否则 AppOpt 8889 网页会把注释行当成规则条目显示出来（用户曾反馈看到「#说明 本模块自动生成」文字）。
  {
    echo "$MARK_BEGIN"
    cat "$sec"
  } > "${sec}.h"
  mv -f "${sec}.h" "$sec" 2>/dev/null

  # ============================================================
  #  兜底规则（用户要求，v19）：
  #    · 未定义配置的进程 → 频率「跟随全局」（不在 app_freq.tsv 里写档 = guard 保持不变
  #      即全局模式）、线程「流畅」(p-core = 中核 4-7)。
  #    · 已在管理区里有规则的包不覆盖；被标 __REMOVE__（不接管）的包不补默认。
  #  实现：对「有界面的第三方应用」逐个补 `pkg=p-core`（仅当尚未有规则）。
  # ============================================================
  pm list packages -3 2>/dev/null </dev/null | cut -d: -f2 > "${sec}.pk"
  sed -n 's/^\([^=]*\)=__REMOVE__$/\1/p' "$sec" 2>/dev/null | sort -u > "${sec}.rm"
  local n_def=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    grep -qF -- "${p}=" "$sec" 2>/dev/null </dev/null && continue
    grep -qF -- "${p}{" "$sec" 2>/dev/null </dev/null && continue
    [ -s "${sec}.rm" ] && grep -qxF -- "$p" "${sec}.rm" 2>/dev/null && continue
    # ★ 联动：8889 未管理段里已存在的包规则（用户/AppOpt 网页手动设的）不补默认，
    #   避免兜底 p-core 覆盖掉 8889 网页里设的 省电/性能 等档位。
    grep -qF -- "${p}=" "$base" 2>/dev/null </dev/null && continue
    is_allowed "$p" && continue
    printf '%s=%s\n' "$p" "p-core" >> "$sec"
    n_def=$((n_def+1))
  done < "${sec}.pk"
  rm -f "${sec}.pk"
  [ "$n_def" -gt 0 ] && log_quiet "gen: 兜底 '流畅(p-core)' 应用 $n_def 个"

  # ★ 去重（放在最后）：同一包名只保留最后一条（最后写=最高优先）；
  #   __REMOVE__ 表示删除该包规则。线程规则 pkg{thread}=core 不参与包级去重。
  awk '
    function ispkg(l) { return (l !~ /^[[:space:]]*#/ && l != "" && index(l,"{")==0 && index(l,"=")>0) }
    {
      lines[NR]=$0
      if (ispkg($0)) {
        p=$0; sub(/=.*$/,"",p)
        v=$0; sub(/^[^=]*=/,"",v)
        pkgof[NR]=p
        mark[NR]=(v=="__REMOVE__") ? "R" : "K"
      }
    }
    END {
      for (i=1;i<=NR;i++) if (i in pkgof) lastline[pkgof[i]]=i
      for (i=1;i<=NR;i++) {
        if (i in pkgof) {
          p=pkgof[i]
          if (lastline[p]!=i) continue
          if (mark[i]=="R") continue
          print lines[i]
        } else print lines[i]
      }
    }
  ' "$sec" > "${sec}.u" 2>/dev/null
  if [ -s "${sec}.u" ]; then mv -f "${sec}.u" "$sec" 2>/dev/null; else rm -f "${sec}.u"; fi
  rm -f "${sec}.rm"

  # ★★ 子进程展开（v19 关键修复）：
  #    AppOpt 的包名匹配是**精确匹配**（cfg.pkgs 是 HashSet），配置 `com.coolapk.market=...`
  #    **不会**作用到 `com.coolapk.market:xg_vip_service` → 子进程仍留在系统 top-app(0-9)
  #    → 表现「省电应用照样上 8-9」。这里为每个已配包名的**已知子进程**补一条同核位规则。
  #    子进程来源：/proc 运行中 + app_freq/app_assign/applist 里出现过的（持久）。
  local subs="${STATE_DIR}/.o3lim.subs"
  {
    for d in /proc/[0-9]*; do
      [ -r "$d/cmdline" ] || continue
      n=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)
      case "$n" in *:*) printf '%s\n' "$n" ;; esac
    done 2>/dev/null
    for f in "$STATE_DIR/webui/app_freq.tsv" "$STATE_DIR/webui/app_assign.tsv" "$CONF"; do
      [ -f "$f" ] && awk -F'[=\t]' '$1 ~ /:/{print $1}' "$f" 2>/dev/null
    done
  # ⚠ 过滤：含 * 的通配伪包名（如 `com.tencent.mm:appbrand*`）不是真进程名，
  #   AppOpt 精确匹配不会命中，写进去只会造成脏数据和误判。
  } | grep -v '^[[:space:]]*$' | grep -v '\*' | sort -u > "$subs"

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
        base=p; sub(/:.*$/,"",base)
        if (p ~ /:/) seen[p]=1
        if (index(line,"{")>0) next
        if (!(base in mode)) mode[base]=v
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

  # ★★ 线程名通配（jazz 风格 · 精简版）：
  #    AppOpt 对**线程名**支持 fnmatch（rule_match.rs 用 libc::fnmatch），包名**只支持精确匹配**
  #    （config.rs: pkgs = HashSet<字面包名>；实测通配包名 hit_pkgs=0），所以：
  #      · 线程级漏网 → 用 `{*Thread*}` 一条通配覆盖 RenderThread / Thread-x / *thread* 全部
  #      · 包级漏网   → 只能靠「子进程枚举」（见上一步）
  #    精简依据（实测）：
  #      · `{*Thread*}` 已同时覆盖原来的 `{*Thread}` 与 `{Thread*}` → 删掉后者
  #      · 包级规则本身就把 binder/其他线程绑到同档（实测 binder:xxx=0-3），
  #        所以 `{binder*}` 冗余 → 删掉
  #    结果：每个「显式配置过」的包只多 1 条线程规则（原 3 条）。
  awk -v ALLOWF="$ALLOW" -v ASSIGNF="$STATE_DIR/webui/app_assign.tsv" -v GAMEF="$STATE_DIR/webui/game_assign.tsv" '
    BEGIN {
      while ((getline a < ALLOWF) > 0) { gsub(/[ \t\r]/,"",a); if (a!="") allow[a]=1 } close(ALLOWF)
      while ((getline b < ASSIGNF) > 0) { split(b,f,"\t"); if (f[1]!="") explicit[f[1]]=1 } close(ASSIGNF)
      while ((getline c < GAMEF) > 0) { split(c,g,"\t"); if (g[1]!="") explicit[g[1]]=1 } close(GAMEF)
    }
    /^[[:space:]]*#/ || $0=="" { print; next }     # ★ 注释/空行原样保留（含 BEGIN 标记！）
    index($0,"{")>0 { print; next }                # 已有的线程规则原样保留
    {
      line=$0; p=line; sub(/=.*$/,"",p); v=line; sub(/^[^=]*=/,"",v)
      print line                                   # 包级兜底规则（含被子进程/线程规则兜不住的部分）
      if (v=="" || v=="__REMOVE__") next
      if (!(p in explicit)) next                   # 线程通配只给显式配置的包（兜底档不加，避免膨胀）
      wt=v
      if (wt ~ /hp-core/ && !(p in allow)) { gsub(/hp-core,?/,"",wt); sub(/,$/,"",wt); if (wt=="") wt="p-core" }
      print p "{*Thread*}=" wt                     # 一条覆盖所有含 Thread/thread 的线程名
    }
  ' "$sec" > "${sec}.tw" 2>/dev/null
  if [ -s "${sec}.tw" ]; then mv -f "${sec}.tw" "$sec" 2>/dev/null; else rm -f "${sec}.tw"; fi

  echo "$MARK_END" >> "$sec"

  # 组装：把未管理段($base，已在 gen 开头从 $CONF 摘出管理区得到，此处复用，不再重读 $CONF)
  #   里的「不接管」包同包规则剥离后，追加新管理段（段外保留）。
  # ★ 联动：模块 WebUI 设「不接管(fast/none)」的包，连 8889 未管理段里的同包规则也一并移除，
  #   否则 8889 的同包规则会盖过「不接管」（8889 段在文件前面、managed 段里该包无规则 → 引擎用 8889 的）。
  #   模块 WebUI 设了具体档位的包无需剥离：managed 段（靠后）会盖过 8889 段，已生效。
  local rmf="${STATE_DIR}/.o3lim.rmbase"; : > "$rmf"
  if [ -f "$STATE_DIR/webui/app_assign.tsv" ]; then
    awk -F'\t' 'NF>=2 && ($2=="fast"||$2=="none"){print $1}' "$STATE_DIR/webui/app_assign.tsv" >> "$rmf" 2>/dev/null
  fi
  if [ -s "$rmf" ]; then
    awk -v RM="$rmf" '
      BEGIN { while((getline r < RM)>0){gsub(/[ \t\r]/,"",r); if(r!="") rm[r]=1} close(RM) }
      { p=$0; sub(/=.*$/,"",p); sub(/\{.*$/,"",p); if (p in rm) next; print }
    ' "$base" > "${base}.r" 2>/dev/null && mv -f "${base}.r" "$base" 2>/dev/null
  fi
  rm -f "$rmf"
  # 去掉 base 尾部多余空行后拼接
  awk 'NF{last=NR} {l[NR]=$0} END{for(i=1;i<=last;i++) print l[i]}' "$base" > "${base}.t" 2>/dev/null
  mv "${base}.t" "$base" 2>/dev/null

  {
    if [ -s "$base" ]; then cat "$base"; echo ""; fi
    cat "$sec"
  } > "${CONF}.new" 2>/dev/null
  # ★ 原子发布：只在 .new 非空且含规则时才 mv 覆盖，避免 AppOpt inotify 读到空文件
  if [ -s "${CONF}.new" ] && grep -q '=' "${CONF}.new" 2>/dev/null; then
    mv -f "${CONF}.new" "$CONF" 2>/dev/null
  else
    rm -f "${CONF}.new" 2>/dev/null
    log_quiet "gen: 结果为空/无规则，放弃覆盖（保留旧配置）"
  fi
  chmod 0666 "$CONF" 2>/dev/null
  rm -f "$sec" "$base"

  echo "OK 已刷新管理区：$(grep -c '=' "$CONF" 2>/dev/null) 条总规则"
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
