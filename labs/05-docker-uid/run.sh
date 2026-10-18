#!/usr/bin/env bash
# labs/05-docker-uid/run.sh
# docker 内演示：默认 root、-u 数字 uid、绑定挂载的属主/权限、命名卷属主、容器 root 产物与删除语义、docker.sock 权限。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ME=$(id -un)
TMP="$LAB_DIR/.tmp"
PREFIX="learnugroup-05-docker-uid-$$"
VOL="${PREFIX}-vol"
PASS=0
FAIL=0

ok()   { printf 'ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

CNAMES=("${PREFIX}-default" "${PREFIX}-rootwrite" "${PREFIX}-del" "${PREFIX}-u1000" "${PREFIX}-u101" "${PREFIX}-chown" "${PREFIX}-vol" "${PREFIX}-volwrite" "${PREFIX}-volchown" "${PREFIX}-u1234")

cleanup() {
  local n
  for n in "${CNAMES[@]}"; do
    docker rm -f "$n" >/dev/null 2>&1 || true
  done
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$TMP":/w debian:13 sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
}
rm -rf -- "$TMP"
mkdir -p -- "$TMP"
trap cleanup EXIT

finish_skip() {
  skip "$1"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
}

section "1. 依赖检查"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  finish_skip "docker 不可用（需要 docker daemon）"
fi
if ! docker image inspect debian:13 >/dev/null 2>&1; then
  finish_skip "本地没有 debian:13 镜像"
fi
ok "docker 可用且本地存在 debian:13 镜像"

section "2. docker.sock 的权限与 docker 组"
ls -l /var/run/docker.sock
SOCK_MODE=$(stat -c '%a' /var/run/docker.sock)
SOCK_TYPE=$(stat -c '%F' /var/run/docker.sock)
printf 'socket mode=%s type=%s\n' "$SOCK_MODE" "$SOCK_TYPE"
if [ "$SOCK_TYPE" = "socket" ]; then
  ok "/var/run/docker.sock 是 socket"
else
  bad "/var/run/docker.sock 类型为 $SOCK_TYPE"
fi
if [ "$SOCK_MODE" = "660" ]; then
  ok "socket 模式为 660（只有属主与属组可读写）"
else
  bad "socket 模式为 $SOCK_MODE，预期 660"
fi
GROUP_LINE=$(getent group docker)
printf 'getent group docker: %s\n' "$GROUP_LINE"
case "$GROUP_LINE" in
  *"$ME"*|*"$(id -un)"*) ok "当前用户在 docker 组里（$GROUP_LINE）" ;;
  *) bad "当前用户不在 docker 组：$GROUP_LINE" ;;
esac
echo '注：本会话是受限沙箱，ls 里 socket 的属主/属组显示为 65534，真实属组是 docker（gid 见 /etc/group）。'

section "3. 默认用户是 root；容器 root 创建的文件在宿主显示 65534"
DEFAULT_ID=$(docker run --rm --name "${PREFIX}-default" debian:13 id)
printf '%s\n' "$DEFAULT_ID"
case "$DEFAULT_ID" in
  "uid=0(root) gid=0(root) groups=0(root)") ok "未指定 -u 时容器内是 uid 0(root)" ;;
  *) bad "默认用户不是 root：$DEFAULT_ID" ;;
esac
mkdir -p "$TMP/rootdir"
chmod 755 "$TMP/rootdir"
ROOTWRITE_OUT=$(docker run --rm --name "${PREFIX}-rootwrite" -v "$TMP/rootdir":/d debian:13 \
  sh -c 'touch /d/by-root; ls -ln /d/by-root')
printf '%s\n' "$ROOTWRITE_OUT"
HOST_ROOT_OWNER=$(stat -c '%u' "$TMP/rootdir/by-root")
printf '宿主视角 by-root 的数值属主: %s\n' "$HOST_ROOT_OWNER"
if [ "$HOST_ROOT_OWNER" = "65534" ]; then
  ok "容器 root 创建的文件在宿主视角显示为 65534（未映射 uid 的溢出显示）"
else
  bad "宿主视角属主为 $HOST_ROOT_OWNER，预期 65534"
fi

section "4. 删除语义：看父目录的 w+x，而不是文件属主"
echo '--- 情形 A：父目录属于当前用户且可写（无 sticky）'
rm -f "$TMP/rootdir/by-root"
if [ ! -e "$TMP/rootdir/by-root" ]; then
  ok "父目录可写时，宿主能删除 root 属主文件（删除看目录 w+x）"
else
  bad "宿主未能删除 root 属主文件"
fi
echo '--- 情形 B：父目录由容器 root 创建，宿主无写权限'
docker run --rm --name "${PREFIX}-del" -v "$TMP/rootdir":/d debian:13 \
  sh -c 'mkdir -p /d/rootdir2; touch /d/rootdir2/x; ls -ldn /d/rootdir2 /d/rootdir2/x'
DEL_OUT=$(rm -f "$TMP/rootdir/rootdir2/x" 2>&1)
DEL_RC=$?
printf '宿主删除 root 属主目录内文件: rc=%s %s\n' "$DEL_RC" "$DEL_OUT"
if [ "$DEL_RC" -ne 0 ]; then
  ok "父目录属主是 root 且 mode 755 时，宿主删不掉里面的文件"
else
  bad "宿主竟然删掉了 root 属主目录内的文件"
fi
echo '（清理仍按约定交给一次性容器，不用宿主 rm 去动 root 属主目录）'

section "5. -u 1000:1000：容器 uid 与宿主 uid 相同"
mkdir -p "$TMP/share"
chmod 755 "$TMP/share"
U1000_OUT=$(docker run --rm --name "${PREFIX}-u1000" -u 1000:1000 -v "$TMP/share":/d debian:13 \
  sh -c 'id; touch /d/by1000; ls -ln /d/by1000')
printf '%s\n' "$U1000_OUT"
case "$U1000_OUT" in
  *"uid=1000"*) ok "容器内 uid=1000" ;;
  *) bad "容器内 uid 不是 1000" ;;
esac
HOST_BY1000=$(stat -c '%u' "$TMP/share/by1000" 2>/dev/null || echo missing)
if [ "$HOST_BY1000" = "1000" ]; then
  ok "容器 uid 1000 创建的文件，宿主视角属主也是 1000"
else
  bad "宿主视角属主为 $HOST_BY1000，预期 1000"
fi

section "6. -u 101:101 写 750 的宿主目录：EACCES；chown 101 后成功"
mkdir -p "$TMP/host750"
chmod 750 "$TMP/host750"
FAIL_OUT=$(docker run --rm --name "${PREFIX}-u101" -u 101:101 -v "$TMP/host750":/d debian:13 \
  sh -c 'touch /d/x' 2>&1)
FAIL_RC=$?
printf 'uid 101 写 750 目录: rc=%s 输出: %s\n' "$FAIL_RC" "$FAIL_OUT"
if [ "$FAIL_RC" -ne 0 ]; then
  ok "uid 101 写 750 宿主目录失败"
else
  bad "uid 101 竟然写入了 750 宿主目录"
fi
case "$FAIL_OUT" in
  *"Permission denied"*) ok "失败原因是 Permission denied（EACCES）" ;;
  *) bad "错误信息不含 Permission denied：$FAIL_OUT" ;;
esac
docker run --rm --name "${PREFIX}-chown" -v "$TMP/host750":/d debian:13 chown 101:101 /d
ls -ldn "$TMP/host750"
OK_OUT=$(docker run --rm --name "${PREFIX}-u101" -u 101:101 -v "$TMP/host750":/d debian:13 \
  sh -c 'touch /d/x; ls -ln /d/x' 2>&1)
OK_RC=$?
printf 'chown 101:101 后 uid 101 写入: rc=%s 输出: %s\n' "$OK_RC" "$OK_OUT"
if [ "$OK_RC" -eq 0 ]; then
  ok "chown 101:101 之后 uid 101 能写入"
else
  bad "chown 后 uid 101 仍写不进去：$OK_OUT"
fi

section "7. 命名卷的属主：默认 root，需要在容器里 chown"
docker volume create "$VOL" >/dev/null
VOL_OUT=$(docker run --rm --name "${PREFIX}-vol" -v "$VOL":/data debian:13 \
  sh -c 'touch /data/rootfile; ls -ldn /data /data/rootfile')
printf '%s\n' "$VOL_OUT"
if printf '%s\n' "$VOL_OUT" | grep -qE '^drwxr-xr-x +[0-9]+ +0 +0 .* /data$'; then
  ok "命名卷根目录默认属主是 0(root)"
else
  bad "命名卷根目录属主不是 root"
fi
VOLFAIL_OUT=$(docker run --rm --name "${PREFIX}-volwrite" -u 1000:1000 -v "$VOL":/data debian:13 \
  touch /data/x 2>&1)
VOLFAIL_RC=$?
printf 'uid 1000 写命名卷: rc=%s 输出: %s\n' "$VOLFAIL_RC" "$VOLFAIL_OUT"
if [ "$VOLFAIL_RC" -ne 0 ]; then
  ok "uid 1000 默认写不进 root 属主的命名卷"
else
  bad "uid 1000 竟然写进了 root 属主的命名卷"
fi
docker run --rm --name "${PREFIX}-volchown" -v "$VOL":/data debian:13 chown 1000:1000 /data
VOLOK_RC=0
docker run --rm --name "${PREFIX}-volwrite" -u 1000:1000 -v "$VOL":/data debian:13 \
  sh -c 'touch /data/x' 2>"$TMP/vol.err" || VOLOK_RC=$?
if [ "$VOLOK_RC" -eq 0 ]; then
  ok "容器内 chown 1000:1000 后 uid 1000 能写命名卷"
else
  bad "chown 后 uid 1000 仍写不进命名卷：$(cat "$TMP/vol.err")"
fi
docker volume rm -f "$VOL" >/dev/null

section "8. 镜像里没有该用户也能用 -u 1234 运行"
U1234_OUT=$(docker run --rm --name "${PREFIX}-u1234" -u 1234:1234 debian:13 \
  sh -c 'id; echo ok > /tmp/x; cat /tmp/x')
printf '%s\n' "$U1234_OUT"
case "$U1234_OUT" in
  *"uid=1234"*) ok "镜像是 debian:13 且 /etc/passwd 无 1234，仍能以 -u 1234 运行" ;;
  *) bad "以 -u 1234 运行失败" ;;
esac

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
