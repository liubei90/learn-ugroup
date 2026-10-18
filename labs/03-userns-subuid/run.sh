#!/usr/bin/env bash
# labs/03-userns-subuid/run.sh
# 宿主可跑，不需要 root。演示：subuid、unshare -Ur 的单 uid 映射、内层 caps、未映射 uid、嵌套 userns。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP="$LAB_DIR/.tmp"
PASS=0
FAIL=0

ok()   { printf 'ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

rm -rf -- "$TMP"
mkdir -p -- "$TMP"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

ME=$(id -un)
MYUID=$(id -u)
norm() { tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//'; }

section "1. /etc/subuid 与 /etc/subgid"
echo '--- /etc/subuid'
cat /etc/subuid
echo '--- /etc/subgid'
cat /etc/subgid
if grep -qx "$ME:100000:65536" /etc/subuid; then
  ok "/etc/subuid 为 $ME 分配了 100000 起的 65536 个从属 uid"
else
  bad "/etc/subuid 中没有 $ME:100000:65536"
fi
if grep -qx "$ME:100000:65536" /etc/subgid; then
  ok "/etc/subgid 为 $ME 分配了 100000 起的 65536 个从属 gid"
else
  bad "/etc/subgid 中没有 $ME:100000:65536"
fi
if command -v newuidmap >/dev/null 2>&1; then
  ok "newuidmap 可用（可写多行 uid_map）"
else
  skip "newuidmap 未安装：本机只能做单 uid 映射，多行映射只在文档里讲原理"
fi

section "2. 本会话自身的 uid_map"
cat /proc/self/uid_map
MAP_LINES=$(wc -l < /proc/self/uid_map)
if [ "$MAP_LINES" -eq 1 ]; then
  ok "本会话只有一个 uid 映射区间（$(norm < /proc/self/uid_map)）"
else
  bad "本会话 uid_map 行数为 $MAP_LINES，预期 1"
fi

section "3. unshare -Ur：把当前 uid 映射成内层 root"
if ! unshare -Ur true 2>/dev/null; then
  skip "unshare -Ur 不可用（内核未开启非特权用户命名空间）"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
fi
INNER_MAP=$(unshare -Ur cat /proc/self/uid_map | norm)
WANT_MAP="0 $MYUID 1"
printf 'unshare -Ur 内 uid_map: %s\n' "$INNER_MAP"
if [ "$INNER_MAP" = "$WANT_MAP" ]; then
  ok "内层映射为 $WANT_MAP（内层 0 = 外层 $MYUID）"
else
  bad "内层映射为 $INNER_MAP，预期 $WANT_MAP"
fi
INNER_UID=$(unshare -Ur id -u)
printf 'unshare -Ur 内 id -u: %s\n' "$INNER_UID"
if [ "$INNER_UID" = "0" ]; then
  ok "内层 id -u 为 0"
else
  bad "内层 id -u 为 $INNER_UID"
fi
INNER_CAP=$(unshare -Ur awk '/^CapEff:/ {print $2}' /proc/self/status)
printf 'unshare -Ur 内 CapEff: %s\n' "$INNER_CAP"
case "$INNER_CAP" in
  *[!0]*) ok "内层进程拥有相对该 userns 的全部 capability（CapEff 非零）" ;;
  *) bad "内层 CapEff=$INNER_CAP，预期非零" ;;
esac
if [ "$(unshare -Ur awk '/^NoNewPrivs:/ {print $2}' /proc/self/status)" = "1" ]; then
  ok "内层 NoNewPrivs=1（与宿主会话一致）"
else
  bad "内层 NoNewPrivs 不为 1"
fi

section "4. 内层 root 创建的文件，在宿主视角仍属于当前用户"
rm -f -- "$TMP/inner-created"
unshare -Ur sh -c "touch '$TMP/inner-created'"
INNER_CREATED_UID=$(stat -c '%u' "$TMP/inner-created")
printf '内层 uid 0 创建的文件，宿主 stat -c %%u: %s\n' "$INNER_CREATED_UID"
if [ "$INNER_CREATED_UID" = "$MYUID" ]; then
  ok "内层 root 创建的文件在宿主仍属 $MYUID（内层 root 不是宿主 root）"
else
  bad "内层 root 创建的文件在宿主 uid=$INNER_CREATED_UID，预期 $MYUID"
fi

section "5. 未映射 uid 的溢出显示：65534"
INNER_SELF_UID=$(unshare -Ur stat -c '%u' "$LAB_DIR/run.sh")
INNER_SHADOW_UID=$(unshare -Ur stat -c '%u' /etc/shadow)
printf '内层看「外层属于 %s 的本 lab 文件」: uid=%s\n' "$MYUID" "$INNER_SELF_UID"
printf '内层看 /etc/shadow（外层未映射的 root 属主）: uid=%s\n' "$INNER_SHADOW_UID"
if [ "$INNER_SELF_UID" = "0" ]; then
  ok "被映射的 $MYUID 在内层显示为 0"
else
  bad "内层看本 lab 文件 uid=$INNER_SELF_UID，预期 0"
fi
if [ "$INNER_SHADOW_UID" = "65534" ]; then
  ok "未映射的属主在内层显示为溢出 UID 65534"
else
  bad "未映射属主显示为 $INNER_SHADOW_UID，预期 65534"
fi

section "6. 内层切到未映射 uid：setpriv --reuid=1 报 EINVAL"
SP_OUT=$(unshare -Ur setpriv --reuid=1 id 2>&1)
SP_RC=$?
printf 'rc=%s 输出: %s\n' "$SP_RC" "$SP_OUT"
if [ "$SP_RC" -ne 0 ]; then
  ok "切到 uid 1 失败（rc=$SP_RC）"
else
  bad "切到 uid 1 竟然成功"
fi
case "$SP_OUT" in
  *"Invalid argument"*|*"无效的参数"*) ok "错误为 EINVAL（只映射了内层 uid 0，没有 uid 1 可切）" ;;
  *) bad "错误信息不含 EINVAL 特征：$SP_OUT" ;;
esac

section "7. 嵌套用户命名空间"
NESTED_MAP=$(unshare -Ur unshare -Ur cat /proc/self/uid_map | norm)
printf '两层 unshare -Ur 后的 uid_map: %s\n' "$NESTED_MAP"
if [ "$NESTED_MAP" = "0 0 1" ]; then
  ok "嵌套后内层 map 为 0 0 1（内层 0 = 中间层 0）"
else
  bad "嵌套 map 为 $NESTED_MAP，预期 0 0 1"
fi

section "8. 宿主读 /etc/shadow：拒绝（只判断，不打印内容）"
if cat /etc/shadow >/dev/null 2>"$TMP/err"; then
  bad "宿主用户竟然读到了 /etc/shadow"
else
  ok "宿主 cat /etc/shadow 被拒绝：$(cat "$TMP/err")"
fi

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
