#!/usr/bin/env bash
# scripts/env-check.sh
# 环境自检：输出能力矩阵（OK/SKIP/FAIL），FAIL 不影响退出码，结尾打印 env-check: PASS。
set -u
export LC_ALL=C

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OK_N=0
SKIP_N=0
FAIL_N=0

row() {
  local name=$1 status=$2 detail=$3
  printf '%-24s %-5s %s\n' "$name" "$status" "$detail"
  case "$status" in
    OK) OK_N=$((OK_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)) ;;
  esac
}

section() { printf '\n== %s ==\n' "$*"; }

section "1. 基础环境"
printf '工作目录：%s\n' "$ROOT"
if [ -r /etc/os-release ]; then
  row "发行版" OK "$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
else
  row "发行版" SKIP "/etc/os-release 不可读"
fi
row "内核" OK "$(uname -r)"
row "当前用户" OK "uid=$(id -u) gid=$(id -g) 用户=$(id -un)"

section "2. 能力矩阵"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    row "docker" OK "server $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  else
    row "docker" FAIL "命令存在但 daemon 不可用（权限或未启动）"
  fi
else
  row "docker" SKIP "未安装 docker"
fi
for img in debian:13 nginx:1.20-alpine alpine:latest; do
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    row "镜像 $img" SKIP "docker 不可用，未检查"
  elif docker image inspect "$img" >/dev/null 2>&1; then
    row "镜像 $img" OK "本地已存在"
  else
    row "镜像 $img" SKIP "本地不存在（需要时 docker pull）"
  fi
done

if unshare -Ur true >/dev/null 2>&1; then
  row "非特权 userns" OK "unshare -Ur 可用（$(unshare -Ur id -u 2>/dev/null)）"
else
  row "非特权 userns" SKIP "unshare -Ur 不可用（内核未开启或受限）"
fi
if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
  row "ACL 工具" OK "getfacl/setfacl 可用"
else
  row "ACL 工具" SKIP "缺 acl 包（Debian: apt install acl）"
fi
if command -v gcc >/dev/null 2>&1; then
  row "gcc" OK "$(gcc --version | head -n 1)"
else
  row "gcc" SKIP "未安装（lab 04 会打印 SKIP）"
fi
if command -v curl >/dev/null 2>&1; then
  row "curl" OK "$(curl --version | head -n 1 | cut -d' ' -f1-2)"
else
  row "curl" SKIP "未安装（lab 06 会打印 SKIP）"
fi
if command -v python3 >/dev/null 2>&1; then
  row "python3" OK "$(python3 --version 2>&1)"
else
  row "python3" SKIP "未安装（lab 01 的 fd 小节会 SKIP）"
fi
if command -v findmnt >/dev/null 2>&1; then
  MNT_OPTS=$(findmnt -T "$ROOT" -n -o OPTIONS 2>/dev/null || true)
  if printf '%s' "$MNT_OPTS" | grep -q 'nosuid'; then
    row "/home 挂载选项" OK "nosuid 存在（$MNT_OPTS）"
  else
    row "/home 挂载选项" OK "无 nosuid（$MNT_OPTS）——lab 01 第 6 节会 FAIL"
  fi
else
  row "/home 挂载选项" SKIP "缺 findmnt"
fi
if [ -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]; then
  row "非特权端口起点" OK "ip_unprivileged_port_start=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"
else
  row "非特权端口起点" SKIP "/proc/sys 不可读"
fi
if [ -r /etc/subuid ]; then
  SUBID_LINE=$(grep -E "^$(id -un):" /etc/subuid 2>/dev/null | head -n 1)
  if [ -n "$SUBID_LINE" ]; then
    row "/etc/subuid" OK "$SUBID_LINE"
  else
    row "/etc/subuid" SKIP "没有 $(id -un) 的从属 uid 区间"
  fi
else
  row "/etc/subuid" SKIP "文件不存在"
fi
if command -v newuidmap >/dev/null 2>&1; then
  row "newuidmap" OK "可用（可写多行 uid_map）"
else
  row "newuidmap" SKIP "未安装：只能单 uid 映射（lab 03 会说明）"
fi

port_free() {
  local p=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
  elif command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"
  else
    return 2
  fi
}
for p in 18080 18081; do
  port_free "$p"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    row "端口 $p" OK "空闲"
  elif [ "$rc" -eq 1 ]; then
    row "端口 $p" FAIL "已被占用（lab 06 可用 LEARNUGROUP_PORT 换端口）"
  else
    row "端口 $p" SKIP "缺 python3/ss，未检查"
  fi
done

section "3. 建议运行的实验"
HOST_LABS="labs/01-permission-model、labs/02-acl、labs/03-userns-subuid"
DOCKER_LABS="labs/04-setuid-caps、labs/05-docker-uid、labs/06-nginx-perm、labs/07-drills"
printf '宿主可跑：%s\n' "$HOST_LABS"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  printf '容器实验：%s\n' "$DOCKER_LABS"
  if ! docker image inspect debian:13 >/dev/null 2>&1; then
    printf '注意：缺 debian:13 镜像 → labs/04、05、07 会打印 SKIP\n'
  fi
  if ! docker image inspect nginx:1.20-alpine >/dev/null 2>&1; then
    printf '注意：缺 nginx:1.20-alpine 镜像 → labs/06 会打印 SKIP\n'
  fi
else
  printf '容器实验：docker 不可用，labs/04、05、06、07 会打印 SKIP\n'
fi
if ! unshare -Ur true >/dev/null 2>&1; then
  printf '注意：非特权 userns 不可用 → labs/03 会打印 SKIP\n'
fi
if ! command -v gcc >/dev/null 2>&1; then
  printf '注意：缺 gcc → labs/04 会打印 SKIP\n'
fi
if ! command -v curl >/dev/null 2>&1; then
  printf '注意：缺 curl → labs/06 会打印 SKIP\n'
fi

printf '\n能力矩阵：%d OK / %d SKIP / %d FAIL\n' "$OK_N" "$SKIP_N" "$FAIL_N"
printf '\nenv-check: PASS\n'
exit 0
