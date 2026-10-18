#!/usr/bin/env bash
# labs/02-acl/run.sh
# 宿主演示 ACL（ext4）。容器部分（给 uid 101 授权）可选，需要 docker + gcc，不联网。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP="$LAB_DIR/.tmp"
CNAME="learnugroup-02-acl-$$"
PASS=0
FAIL=0
DOCKER_OK=0

ok()   { printf 'ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

cleanup() {
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
rm -rf -- "$TMP"
mkdir -p -- "$TMP"
trap cleanup EXIT

MYUID=$(id -u)

if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1; then
  skip "getfacl/setfacl 未安装（Debian: apt install acl）"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
fi

section "1. setfacl / getfacl：给当前用户加一条 ACL"
: > "$TMP/acl1"
setfacl -m "u:$MYUID:r" "$TMP/acl1"
getfacl -p "$TMP/acl1"
USER_ENTRIES=$(getfacl -cp "$TMP/acl1" | grep -c '^user:')
printf 'ACL 中 user: 行数 = %s（一条 user:: 属主条目 + 一条扩展条目）\n' "$USER_ENTRIES"
if [ "$USER_ENTRIES" -eq 2 ] && getfacl -cp "$TMP/acl1" | grep -q '^user:.*:r--$'; then
  ok "扩展 ACL 条目已存在（user:$MYUID:r--）"
else
  bad "未看到预期的扩展 ACL 条目"
fi
if getfacl -cp "$TMP/acl1" | grep -q '^mask::'; then
  ok "setfacl 自动生成了 mask 条目"
else
  bad "缺少 mask 条目"
fi

section "2. chmod 改的是 mask：640 之后 group 受 mask 限制"
chmod 640 "$TMP/acl1"
getfacl -p "$TMP/acl1"
if getfacl -cp "$TMP/acl1" | grep -qx 'mask::r--'; then
  ok "chmod 640 把 mask 改成 r--"
else
  bad "chmod 640 后 mask 不是 r--"
fi
if getfacl -cp "$TMP/acl1" | grep -q '^group::rw-.*#effective:r--'; then
  ok "getfacl 标出 group 的 #effective:r--（受 mask 限制）"
else
  bad "没有看到 group 的 #effective:r-- 标注"
fi

section "3. default ACL：新文件自动继承"
mkdir "$TMP/acldir"
setfacl -d -m "u:$MYUID:rwx" "$TMP/acldir"
setfacl -m "u:$MYUID:rwx" "$TMP/acldir"
: > "$TMP/acldir/newfile"
getfacl -p "$TMP/acldir" "$TMP/acldir/newfile"
if getfacl -cp "$TMP/acldir" | grep -q '^default:user:.*:rwx$'; then
  ok "目录带 default ACL 条目"
else
  bad "目录上没有 default ACL 条目"
fi
if getfacl -cp "$TMP/acldir/newfile" | grep -q '^user:.*:rwx.*#effective:rw-'; then
  ok "新建文件继承 default ACL，并被 mask 限制为有效 rw-"
else
  bad "新建文件没有继承 default ACL（或 effective 标注不符）"
fi

section "4. setfacl -k / -b：分别删默认 ACL 与全部 ACL"
mkdir "$TMP/acl2"
setfacl -d -m "u:$MYUID:rwx" "$TMP/acl2"
setfacl -m "u:$MYUID:rwx" "$TMP/acl2"
setfacl -k "$TMP/acl2"
getfacl -p "$TMP/acl2"
if getfacl -cp "$TMP/acl2" | grep -q '^default:'; then
  bad "-k 之后仍有 default 条目"
else
  ok "-k 只删除 default 条目"
fi
if getfacl -cp "$TMP/acl2" | grep -q '^user:.*:rwx$'; then
  ok "-k 保留了普通访问 ACL 条目"
else
  bad "-k 误删了普通访问 ACL 条目"
fi
setfacl -b "$TMP/acl2"
if [ "$(getfacl -cp "$TMP/acl2" | grep -c '^user:')" -eq 1 ] \
   && ! getfacl -cp "$TMP/acl2" | grep -q '^mask::'; then
  ok "-b 清除了全部扩展 ACL（只剩 user:: 属主条目）"
else
  bad "-b 之后仍有扩展 ACL 残留"
fi

section "5. 备份与恢复：getfacl -p -R > bak + setfacl --restore"
getfacl -p -R "$TMP/acldir" > "$TMP/acl.bak"
printf '备份文件条目数: %s\n' "$(grep -c '^# file:' "$TMP/acl.bak")"
setfacl -bR "$TMP/acldir"
if getfacl -cp "$TMP/acldir" | grep -q '^default:' \
   || [ "$(getfacl -cp "$TMP/acldir/newfile" | grep -c '^user:')" -ne 1 ]; then
  bad "setfacl -bR 没有清干净"
else
  ok "setfacl -bR 后 ACL 已清除"
fi
setfacl --restore="$TMP/acl.bak"
if getfacl -cp "$TMP/acldir" | grep -q '^default:user:.*:rwx$' \
   && [ "$(getfacl -cp "$TMP/acldir/newfile" | grep -c '^user:')" -eq 2 ]; then
  ok "setfacl --restore 恢复了目录 default ACL 与文件 ACL"
else
  bad "ACL 恢复失败"
fi

section "6. 可选：容器内把 ACL 授给 uid 101（不联网，直接写 ACL xattr）"
if command -v docker >/dev/null 2>&1 && docker image inspect debian:13 >/dev/null 2>&1; then
  DOCKER_OK=1
else
  skip "docker 或 debian:13 镜像不可用，跳过跨 uid ACL 演示"
fi
if [ "$DOCKER_OK" -eq 1 ] && ! command -v gcc >/dev/null 2>&1; then
  skip "gcc 不可用，无法编译最小 ACL 写入器，跳过跨 uid ACL 演示"
  DOCKER_OK=0
fi
if [ "$DOCKER_OK" -eq 1 ]; then
  cat > "$TMP/aclset.c" <<'EOF'
/* 直接写 system.posix_acl_access：基础镜像没有 acl 包，本 lab 不联网，故用最小 C 程序。 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s FILE UID\n", argv[0]); return 2; }
    uint32_t uid = (uint32_t)strtoul(argv[2], NULL, 10);
    unsigned char buf[4 + 5 * 8];
    size_t off = 0;
    uint32_t version = 2;
    memcpy(buf + off, &version, 4); off += 4;
    struct { uint16_t tag, perm; uint32_t id; } entries[5] = {
        {0x01, 6, 0xFFFFFFFFu}, /* ACL_USER_OBJ  rw- */
        {0x02, 4, 0},           /* ACL_USER      r-- */
        {0x04, 4, 0xFFFFFFFFu}, /* ACL_GROUP_OBJ r-- */
        {0x10, 4, 0xFFFFFFFFu}, /* ACL_MASK      r-- */
        {0x20, 0, 0xFFFFFFFFu}  /* ACL_OTHER     --- */
    };
    entries[1].id = uid;
    for (int i = 0; i < 5; i++) {
        memcpy(buf + off, &entries[i].tag, 2);  off += 2;
        memcpy(buf + off, &entries[i].perm, 2); off += 2;
        memcpy(buf + off, &entries[i].id, 4);   off += 4;
    }
    if (setxattr(argv[1], "system.posix_acl_access", buf, off, 0) != 0) {
        fprintf(stderr, "setxattr: %s\n", strerror(errno));
        return 1;
    }
    printf("acl-set uid=%u file=%s\n", uid, argv[1]);
    return 0;
}
EOF
  if ! gcc -static -O2 -o "$TMP/aclset" "$TMP/aclset.c" >/dev/null 2>&1; then
    skip "静态编译 ACL 写入器失败，跳过跨 uid ACL 演示"
  else
    mkdir -p "$TMP/cross"
    printf 'CROSS-UID-OK\n' > "$TMP/cross/secret.txt"
    chmod 600 "$TMP/cross/secret.txt"
    echo '宿主文件: secret.txt 属主 1000、模式 600（其他 uid 不可读）'
    ACL_OUT=$(docker run --rm --name "$CNAME" -v "$LAB_DIR":/lab debian:13 \
      /lab/.tmp/aclset /lab/.tmp/cross/secret.txt 101 2>&1)
    printf '容器内（root）授予 uid 101 r--：%s\n' "$ACL_OUT"
    if [ "$ACL_OUT" = "acl-set uid=101 file=/lab/.tmp/cross/secret.txt" ]; then
      ok "容器内成功写入 uid 101 的 ACL 条目"
    else
      bad "写入 uid 101 的 ACL 条目失败：$ACL_OUT"
    fi
    CROSS_OUT=$(docker run --rm --name "$CNAME" -u 101:101 -v "$LAB_DIR":/lab debian:13 \
      cat /lab/.tmp/cross/secret.txt 2>&1)
    printf '容器内以 uid 101 读取: %s\n' "$CROSS_OUT"
    case "$CROSS_OUT" in
      *CROSS-UID-OK*) ok "uid 101 通过 ACL 读到了原本 600 的文件" ;;
      *) bad "uid 101 读取失败：$CROSS_OUT" ;;
    esac
    DENY_OUT=$(docker run --rm --name "$CNAME" -u 102:102 -v "$LAB_DIR":/lab debian:13 \
      cat /lab/.tmp/cross/secret.txt 2>&1)
    printf '对照：未授权的 uid 102 读取: %s\n' "$DENY_OUT"
    case "$DENY_OUT" in
      *Permission\ denied*) ok "未授权的 uid 102 仍被拒绝（ACL 精确到 uid）" ;;
      *) bad "uid 102 未被拒绝：$DENY_OUT" ;;
    esac
    echo '宿主视角（本会话 userns 未映射 uid 101，数值显示为 4294967295 属正常）：'
    getfacl -p "$TMP/cross/secret.txt"
  fi
fi

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
