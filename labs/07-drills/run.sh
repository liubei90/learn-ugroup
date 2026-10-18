#!/usr/bin/env bash
# labs/07-drills/run.sh
# 5 个权限故障演练：现象 -> 诊断 -> 根因 -> 修复 -> 断言。--quiz 模式隐藏根因与修复。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP="$LAB_DIR/.tmp"
PREFIX="learnugroup-07-drills-$$"
PASS=0
FAIL=0
QUIZ=0

ok()   { printf 'ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
show() { if [ "$QUIZ" -eq 0 ]; then printf '%s\n' "$*"; fi; }

for arg in "$@"; do
  case "$arg" in
    --quiz) QUIZ=1 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数：$arg（可用 --quiz）" >&2; exit 2 ;;
  esac
done

CNAMES=("${PREFIX}-d1" "${PREFIX}-d1f" "${PREFIX}-d3a" "${PREFIX}-d3b" "${PREFIX}-d4a" "${PREFIX}-d4b" "${PREFIX}-d4c" "${PREFIX}-d5a" "${PREFIX}-d5b")
cleanup() {
  local n
  for n in "${CNAMES[@]}"; do
    docker rm -f "$n" >/dev/null 2>&1 || true
  done
  if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$TMP":/w debian:13 sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
}
rm -rf -- "$TMP"
mkdir -p -- "$TMP"
trap cleanup EXIT

if [ "$QUIZ" -eq 1 ]; then
  printf '%s\n' '【--quiz 模式】只显示现象与断言，根因/修复已隐藏；去掉 --quiz 重跑可看答案。'
fi

section "0. 依赖检查"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "docker 不可用（需要 docker daemon）"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
fi
if ! docker image inspect debian:13 >/dev/null 2>&1; then
  skip "本地没有 debian:13 镜像"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
fi
ok "docker 可用且本地存在 debian:13 镜像"

# ---------------------------------------------------------------------------
section "场景 1：600 文件，另一个 uid 读不到（EACCES）"
printf '现象：容器内 uid 101 读取宿主 600 文件\n'
D1="$TMP/d1"
mkdir -p "$D1"
printf 'DRILL1-OK\n' > "$D1/data.txt"
chmod 600 "$D1/data.txt"
D1_OUT=$(docker run --rm --name "${PREFIX}-d1" -u 101:101 -v "$D1":/d debian:13 \
  sh -c 'ls -ln /d/data.txt; cat /d/data.txt' 2>&1)
D1_RC=$?
printf '%s\n' "$D1_OUT"
printf 'rc=%s\n' "$D1_RC"
show "诊断：ls -ln 看文件的属主/mode；容器内 id 看读取者 uid；cat 的 errno=EACCES。"
show "根因：data.txt 属主 1000、mode 600，uid 101 既非属主也不在属组，other 为 ---。"
show "修复：放宽读权限到 644（或 chown/ACL，见 labs/02、labs/05）。"
if [ "$D1_RC" -ne 0 ]; then
  ok "场景 1：未授权 uid 读取被拒绝"
else
  bad "场景 1：uid 101 竟然读到了 600 文件"
fi
chmod 644 "$D1/data.txt"
D1F_OUT=$(docker run --rm --name "${PREFIX}-d1f" -u 101:101 -v "$D1":/d debian:13 cat /d/data.txt 2>&1)
D1F_RC=$?
printf '修复后 rc=%s 输出: %s\n' "$D1F_RC" "$D1F_OUT"
if [ "$D1F_RC" -eq 0 ] && printf '%s' "$D1F_OUT" | grep -q 'DRILL1-OK'; then
  ok "场景 1：修复后跨 uid 读取成功"
else
  bad "场景 1：修复后仍读取失败"
fi

# ---------------------------------------------------------------------------
section "场景 2：目录缺 x 位，里面 644 文件也读不到"
printf '现象：宿主 cat 一个 mode 600 的目录里的 644 文件\n'
D2="$TMP/d2"
mkdir -p "$D2"
printf 'DRILL2-OK\n' > "$D2/inner.txt"
chmod 644 "$D2/inner.txt"
chmod 600 "$D2"
ls -ldn "$D2"
D2_OUT=$(cat "$D2/inner.txt" 2>&1)
D2_RC=$?
printf '%s\n' "$D2_OUT"
printf 'rc=%s\n' "$D2_RC"
if command -v namei >/dev/null 2>&1; then
  namei -l "$D2/inner.txt"
else
  stat -c 'mode=%a %n' "$D2" "$D2/inner.txt"
fi
show "诊断：用 namei -l（或对路径逐级 stat）看每一级目录的 x 位。"
show "根因：目录 mode 600 没有 x，路径解析无法进入目录；文件自身 644 不起作用。"
show "修复：chmod 700 目录（只给属主 x），之后即可读。"
if [ "$D2_RC" -ne 0 ]; then
  ok "场景 2：目录内文件不可读"
else
  bad "场景 2：目录缺 x 时竟然读到了文件"
fi
chmod 700 "$D2"
D2F_OUT=$(cat "$D2/inner.txt" 2>&1)
D2F_RC=$?
printf '修复后 rc=%s 输出: %s\n' "$D2F_RC" "$D2F_OUT"
if [ "$D2F_RC" -eq 0 ] && printf '%s' "$D2F_OUT" | grep -q 'DRILL2-OK'; then
  ok "场景 2：修复后可读"
else
  bad "场景 2：修复后仍不可读"
fi

# ---------------------------------------------------------------------------
section "场景 3：绑定挂载的宿主目录 uid 不匹配，容器写不进去"
printf '现象：容器 uid 101 往宿主 750 目录写文件\n'
D3="$TMP/d3"
mkdir -p "$D3"
chmod 750 "$D3"
ls -ldn "$D3"
D3_OUT=$(docker run --rm --name "${PREFIX}-d3a" -u 101:101 -v "$D3":/d debian:13 \
  sh -c 'id; touch /d/x' 2>&1)
D3_RC=$?
printf '%s\n' "$D3_OUT"
printf 'rc=%s\n' "$D3_RC"
show "诊断：宿主 ls -ldn 目录、容器内 id 对照 uid/gid；touch 报 EACCES。"
show "根因：目录属主 1000、mode 750，容器 uid 101 无写权限；绑定挂载不改变 inode 属主。"
show "修复：在容器内 chown 101:101 目录（或改 mode/换 -u/用 ACL）。"
if [ "$D3_RC" -ne 0 ]; then
  ok "场景 3：跨 uid 写入被拒绝"
else
  bad "场景 3：uid 101 竟然写入了 750 目录"
fi
docker run --rm --name "${PREFIX}-d3b" -v "$D3":/d debian:13 chown 101:101 /d
D3F_OUT=$(docker run --rm --name "${PREFIX}-d3a" -u 101:101 -v "$D3":/d debian:13 \
  sh -c 'touch /d/x; ls -ln /d/x' 2>&1)
D3F_RC=$?
printf '修复后 rc=%s 输出: %s\n' "$D3F_RC" "$D3F_OUT"
if [ "$D3F_RC" -eq 0 ]; then
  ok "场景 3：修复后可写"
else
  bad "场景 3：修复后仍不可写"
fi

# ---------------------------------------------------------------------------
section "场景 4：sticky 目录（1777）里，uid 101 删不掉别人的文件"
printf '现象：1777 目录里，容器 uid 101 删除宿主文件 / 删除自己的文件\n'
D4="$TMP/d4"
mkdir -p "$D4"
chmod 1777 "$D4"
printf 'host-owned\n' > "$D4/owner-file"
docker run --rm --name "${PREFIX}-d4a" -u 101:101 -v "$D4":/d debian:13 \
  sh -c 'touch /d/other-file; ls -ln /d'
ls -ldn "$D4"
D4A_OUT=$(docker run --rm --name "${PREFIX}-d4b" -u 101:101 -v "$D4":/d debian:13 \
  rm -f /d/owner-file 2>&1)
D4A_RC=$?
printf '删除他人文件: rc=%s 输出: %s\n' "$D4A_RC" "$D4A_OUT"
D4B_OUT=$(docker run --rm --name "${PREFIX}-d4c" -u 101:101 -v "$D4":/d debian:13 \
  rm -f /d/other-file 2>&1)
D4B_RC=$?
printf '删除自己的文件: rc=%s 输出: %s\n' "$D4B_RC" "$D4B_OUT"
show "诊断：ls -ldn 看目录 mode 是否含 t；ls -ln 看文件属主；stat -c %a 确认 1777。"
show "根因：sticky 位规定只有文件属主、目录属主或 root 能删除；uid 101 不是 owner-file 的属主。"
show "修复：这是保护机制而不是故障；需要删除时由属主/root 操作，或调整目录策略。"
if [ "$D4A_RC" -ne 0 ]; then
  ok "场景 4：sticky 目录下删除他人文件被拒绝"
else
  bad "场景 4：uid 101 竟然删掉了别人的文件"
fi
if [ "$D4B_RC" -eq 0 ] && [ ! -e "$D4/other-file" ]; then
  ok "场景 4：删除自己文件成功"
else
  bad "场景 4：删除自己的文件失败"
fi

# ---------------------------------------------------------------------------
section "场景 5：docker.sock 组权限的模拟（660 root:docker）"
printf '现象：先看真实 docker.sock，再用同 mode/属组的普通文件模拟组权限\n'
stat -c 'real docker.sock: mode=%a type=%F' /var/run/docker.sock
DGID=$(getent group docker | cut -d: -f3)
if [ -z "$DGID" ]; then
  DGID=989
fi
printf 'docker 组 gid=%s\n' "$DGID"
D5="$TMP/d5"
mkdir -p "$D5"
docker run --rm --name "${PREFIX}-d5a" -v "$D5":/w debian:13 sh -c \
  "printf 'sock-like-data\\n' > /w/socklike; chown 0:$DGID /w/socklike; chmod 660 /w/socklike; ls -ln /w/socklike"
D5A_OUT=$(docker run --rm --name "${PREFIX}-d5b" -u 1000:1000 -v "$D5":/w debian:13 \
  cat /w/socklike 2>&1)
D5A_RC=$?
printf '无 docker 组读取: rc=%s 输出: %s\n' "$D5A_RC" "$D5A_OUT"
D5B_OUT=$(docker run --rm --name "${PREFIX}-d5b" -u 1000:1000 --group-add "$DGID" \
  -v "$D5":/w debian:13 cat /w/socklike 2>&1)
D5B_RC=$?
printf '补 docker 组后读取: rc=%s 输出: %s\n' "$D5B_RC" "$D5B_OUT"
show "诊断：stat/ ls -l 看 socket 的属主、属组、mode；id 看自己是否在 docker 组。"
show "根因：660 只允许属主与属组读写；不在 docker 组的进程访问 socket 得到 EACCES。"
show "修复：把用户加入 docker 组（= 给 root 等价权限，需谨慎）；本场景只做文件级模拟，不挂真实 socket。"
if [ "$D5A_RC" -ne 0 ]; then
  ok "场景 5：无组权限读取 660 文件被拒绝"
else
  bad "场景 5：无组权限竟然读到了 660 文件"
fi
if [ "$D5B_RC" -eq 0 ] && printf '%s' "$D5B_OUT" | grep -q 'sock-like-data'; then
  ok "场景 5：补组后读取成功"
else
  bad "场景 5：补组后仍读取失败"
fi

# ---------------------------------------------------------------------------
if [ "$QUIZ" -eq 1 ]; then
  printf '\n%s\n' '答案已隐藏。去掉 --quiz 重新运行即可查看每个场景的根因与修复。'
fi
printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
