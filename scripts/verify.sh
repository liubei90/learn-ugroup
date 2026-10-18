#!/usr/bin/env bash
# learn-ugroup 质量门禁
# 用法：
#   bash scripts/verify.sh          # 全量：文档检查 + 全部 lab + 环境自检
#   bash scripts/verify.sh --fast   # 只跑宿主 lab（跳过依赖 docker 的 lab）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
SKIP=0
ok()   { printf 'ok    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIP=$((SKIP + 1)); }
section() { printf '\n== %s ==\n' "$*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
section "1. 文档结构与内容"

declare -A MIN_LINES=(
  ["docs/00-学习方法与环境准备.md"]=180
  ["docs/01-权限模型全景.md"]=500
  ["docs/02-用户与组数据库.md"]=380
  ["docs/03-文件权限与ACL.md"]=500
  ["docs/04-进程凭证与权限检查.md"]=380
  ["docs/05-提权与降权机制.md"]=500
  ["docs/06-命名空间与uid映射.md"]=380
  ["docs/07-Docker用户与权限实战.md"]=500
  ["docs/08-Nginx用户与权限实战.md"]=500
  ["docs/09-权限排障手册.md"]=380
  ["docs/10-账户安全基线与审计.md"]=380
  ["docs/11-速查表与命令索引.md"]=300
)

DOCS=(
  "docs/00-学习方法与环境准备.md"
  "docs/01-权限模型全景.md"
  "docs/02-用户与组数据库.md"
  "docs/03-文件权限与ACL.md"
  "docs/04-进程凭证与权限检查.md"
  "docs/05-提权与降权机制.md"
  "docs/06-命名空间与uid映射.md"
  "docs/07-Docker用户与权限实战.md"
  "docs/08-Nginx用户与权限实战.md"
  "docs/09-权限排障手册.md"
  "docs/10-账户安全基线与审计.md"
  "docs/11-速查表与命令索引.md"
)

HEADINGS=(
  "## 一、先建立直觉"
  "## 二、"
  "## 三、动手验证"
  "## 四、常见误解"
  "## 五、速查表"
  "## 六、延伸阅读"
)

check_links() {
  local f="$1" dir link target raw
  dir="$(dirname "$f")"
  while IFS= read -r raw; do
    link="${raw#](}"
    link="${link%)}"
    case "$link" in
      http://*|https://*|mailto:*|'#'*|'') continue ;;
    esac
    target="${link%%#*}"
    [ -z "$target" ] && continue
    if [ ! -e "$dir/$target" ] && [ ! -e "$target" ]; then
      bad "$f 的链接不存在：$link"
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null || true)
}

for f in "${DOCS[@]}"; do
  if [ ! -f "$f" ]; then bad "缺少文档：$f"; continue; fi

  head1="$(head -n 1 "$f")"
  case "$head1" in
    "# "*) ok "$f 标题" ;;
    *) bad "$f 首行不是一级标题" ;;
  esac

  grep -q '^> \*\*一句话总结\*\*' "$f" && ok "$f 一句话总结" || bad "$f 缺少「一句话总结」"
  grep -q '^> \*\*本机验证\*\*' "$f" && ok "$f 本机验证标注" || bad "$f 缺少「本机验证」标注"
  grep -q '^| 项目 | 内容 |' "$f" && ok "$f 元信息表" || bad "$f 缺少元信息表"

  for h in "${HEADINGS[@]}"; do
    grep -qF "$h" "$f" || bad "$f 缺少标题：$h"
  done

  if grep -nE 'TODO|TBD|FIXME|占位符|lorem ipsum' "$f" >/dev/null 2>&1; then
    bad "$f 含有 TODO/TBD/占位符"
  else
    ok "$f 无占位符"
  fi

  lines="$(wc -l < "$f")"
  min="${MIN_LINES[$f]:-0}"
  if [ "$lines" -ge "$min" ]; then
    ok "$f 行数 $lines >= $min"
  else
    bad "$f 行数 $lines < $min（内容不完整）"
  fi

  fences="$(grep -c '^```' "$f" || true)"
  if [ $((fences % 2)) -eq 0 ]; then
    ok "$f 代码块闭合（$fences 个围栏）"
  else
    bad "$f 代码块未闭合（$fences 个围栏）"
  fi

  check_links "$f"
done

# ---------------------------------------------------------------------------
section "2. README 与工程文件"

for f in README.md Makefile scripts/env-check.sh scripts/verify.sh .gitignore; do
  [ -e "$f" ] && ok "存在 $f" || bad "缺少 $f"
done

if [ -f README.md ]; then
  for h in "## 这套教程解决什么问题" "## 30 秒快速开始" "## 文档导览" "## 实验导览" "## 环境与已知限制"; do
    grep -qF "$h" README.md && ok "README 含「$h」" || bad "README 缺少「$h」"
  done
  check_links README.md
fi

if [ -f Makefile ]; then
  for t in env test check list clean help; do
    grep -qE "^$t:" Makefile && ok "Makefile 有 $t 目标" || bad "Makefile 缺少 $t 目标"
  done
fi

# ---------------------------------------------------------------------------
section "3. 实验脚本"

LABS=(
  "labs/01-permission-model"
  "labs/02-acl"
  "labs/03-userns-subuid"
  "labs/04-setuid-caps"
  "labs/05-docker-uid"
  "labs/06-nginx-perm"
  "labs/07-drills"
)
DOCKER_LABS=" labs/04-setuid-caps labs/05-docker-uid labs/06-nginx-perm labs/07-drills "

for lab in "${LABS[@]}"; do
  if [ ! -d "$lab" ]; then bad "缺少实验目录：$lab"; continue; fi
  [ -f "$lab/README.md" ] && ok "$lab/README.md" || bad "$lab 缺少 README.md"
  if [ ! -f "$lab/run.sh" ]; then bad "$lab 缺少 run.sh"; continue; fi

  if grep -qE '^#!' "$lab/run.sh"; then ok "$lab/run.sh 有 shebang"; else bad "$lab/run.sh 缺 shebang"; fi
  if grep -qF 'set -' "$lab/run.sh"; then ok "$lab/run.sh 有 set -u/-e"; else skip "$lab/run.sh 未见 set -u/-e（人工确认）"; fi
  if [ -f "$lab/README.md" ]; then
    grep -qE 'PASS [0-9]+ ?/ ?FAIL [0-9]+' "$lab/README.md" && ok "$lab/README.md 含 PASS 汇总" \
      || skip "$lab/README.md 未见 PASS 汇总（人工确认）"
    check_links "$lab/README.md"
  fi

  if [ "$FAST" -eq 1 ] && [[ "$DOCKER_LABS" == *" $lab "* ]]; then
    skip "$lab 运行（--fast 跳过 docker 实验）"
    continue
  fi

  out="$TMPD/$(echo "$lab" | tr '/' '_').log"
  if timeout 900 bash "$lab/run.sh" >"$out" 2>&1; then
    if grep -qE 'PASS [0-9]+ ?/ ?FAIL [0-9]+' "$out"; then
      summary="$(grep -oE 'PASS [0-9]+ ?/ ?FAIL [0-9]+' "$out" | tail -n 1)"
      failed_n="$(echo "$summary" | grep -oE 'FAIL [0-9]+' | grep -oE '[0-9]+')"
      if [ "${failed_n:-0}" -eq 0 ]; then
        ok "$lab 运行通过（$summary）"
      else
        bad "$lab 运行有失败断言（$summary）"
      fi
    elif grep -q 'SKIP' "$out"; then
      skip "$lab 因环境缺失 SKIP"
    else
      bad "$lab 运行退出 0 但缺少 PASS 汇总"
    fi
  else
    bad "$lab 运行失败（退出码非 0），日志：$out"
    sed -n '1,20p' "$out" | sed 's/^/       /'
  fi
done

# ---------------------------------------------------------------------------
section "4. 环境自检脚本"

if [ -f scripts/env-check.sh ]; then
  out="$TMPD/env-check.log"
  if timeout 300 bash scripts/env-check.sh >"$out" 2>&1; then
    ok "scripts/env-check.sh 退出 0"
  else
    bad "scripts/env-check.sh 退出码非 0"
    tail -n 20 "$out" | sed 's/^/       /'
  fi
else
  bad "缺少 scripts/env-check.sh"
fi

# ---------------------------------------------------------------------------
section "汇总"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\n质量门禁未通过：%d 项失败\n' "$FAIL"
  exit 1
fi
printf '\n质量门禁通过\n'
