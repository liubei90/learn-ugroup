#!/usr/bin/env bash
# labs/01-permission-model/run.sh
# 宿主可跑，无需 root、无需网络。演示：进程凭证 / umask 矩阵 / 特殊位 / 目录 x 位 / 已打开 fd / nosuid。
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

section "1. 进程凭证：id 与 /proc/self/status"
id
echo "--- /proc/self/status 关键字段 ---"
grep -E '^(Uid|Gid|Groups|CapEff|CapBnd|NoNewPrivs):' /proc/self/status

MYUID=$(id -u)
STATUS_UID=$(awk '/^Uid:/ {print $2}' /proc/self/status)
if [ "$STATUS_UID" = "$MYUID" ]; then
  ok "id -u 与 /proc/self/status 的 Uid 一致（$MYUID）"
else
  bad "id -u=$MYUID 但 /proc/self/status Uid=$STATUS_UID"
fi
if grep -q '^NoNewPrivs:' /proc/self/status; then
  ok "本会话存在 NoNewPrivs 字段（$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status)）"
else
  bad "未找到 NoNewPrivs 字段"
fi
CAPEFF=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
printf '本会话 CapEff=%s（沙箱内无 capability，root 才能绕过的检查在这里也会被拦）\n' "$CAPEFF"

section "2. umask 矩阵：022 / 077 / 002"
check_umask() {
  local u=$1 want_f=$2 want_d=$3 got_f got_d
  ( umask "$u"; : > "$TMP/f_$u"; mkdir "$TMP/d_$u" )
  got_f=$(stat -c '%a' "$TMP/f_$u")
  got_d=$(stat -c '%a' "$TMP/d_$u")
  printf 'umask %s -> 新文件 %s，新目录 %s\n' "$u" "$got_f" "$got_d"
  if [ "$got_f" = "$want_f" ] && [ "$got_d" = "$want_d" ]; then
    ok "umask $u 得到文件 $want_f / 目录 $want_d"
  else
    bad "umask $u 期望文件 $want_f 目录 $want_d，实际 $got_f / $got_d"
  fi
}
check_umask 022 644 755
check_umask 077 600 700
check_umask 002 664 775

section "3. 特殊位在 ls/stat 中的显示"
: > "$TMP/special"
for spec in "4755:-rwsr-xr-x" "2775:-rwxrwsr-x" "1777:-rwxrwxrwt" "4644:-rwSr--r--" "2644:-rw-r-Sr--"; do
  mode=${spec%%:*}
  want=${spec#*:}
  chmod "$mode" "$TMP/special"
  got_mode=$(stat -c '%a' "$TMP/special")
  got_sym=$(stat -c '%A' "$TMP/special")
  printf 'chmod %s -> stat %%a=%s  %%A=%s\n' "$mode" "$got_mode" "$got_sym"
  if [ "$got_mode" = "$mode" ] && [ "$got_sym" = "$want" ]; then
    ok "mode $mode 显示为 $want"
  else
    bad "mode $mode 期望 $want，实际 $got_mode / $got_sym"
  fi
done

section "4. 目录缺 x 位：读里面的文件也会失败"
mkdir "$TMP/nosearch"
printf 'data\n' > "$TMP/nosearch/f"
chmod 600 "$TMP/nosearch"
printf 'chmod 600 nosearch 后执行 cat nosearch/f：\n'
if cat "$TMP/nosearch/f" 2>"$TMP/err"; then
  bad "目录缺 x 位时仍然读到了文件"
else
  ok "目录无 x 位导致读取失败：$(cat "$TMP/err")"
fi
chmod 700 "$TMP/nosearch"
printf 'chmod 700 nosearch 后执行 cat nosearch/f：\n'
if cat "$TMP/nosearch/f" 2>"$TMP/err"; then
  ok "补上 x 位后读取成功"
else
  bad "补上 x 位后仍然失败：$(cat "$TMP/err")"
fi

section "5. 已打开的 fd 不再复查权限（python3）"
cat > "$TMP/fdtest.py" <<'PY'
import os
import sys

path = sys.argv[1]
f = open(path, "w+")
f.write("payload")
f.flush()
os.chmod(path, 0)
try:
    f.seek(0)
    data = f.read()
except Exception as exc:  # noqa: BLE001 - 演示用
    data = "ERR:%s" % exc
try:
    open(path, "r").close()
    reopened = "OK"
except PermissionError:
    reopened = "DENIED"
print("fd-read=%s reopen=%s" % (data, reopened))
PY
if command -v python3 >/dev/null 2>&1; then
  FD_OUT=$(python3 "$TMP/fdtest.py" "$TMP/fdtest")
  printf '%s\n' "$FD_OUT"
  case "$FD_OUT" in
    "fd-read=payload reopen=DENIED") ok "chmod 000 后，已打开 fd 仍可读，重新 open 被拒绝" ;;
    *) bad "fd 实验输出不符：$FD_OUT" ;;
  esac
else
  skip "python3 不可用，跳过已打开 fd 实验"
fi

section "6. 挂载选项：/home 的 nosuid"
findmnt -T "$LAB_DIR" -o TARGET,SOURCE,FSTYPE,OPTIONS
MOUNT_OPTS=$(findmnt -T "$LAB_DIR" -n -o OPTIONS)
case "$MOUNT_OPTS" in
  *nosuid*) ok "本 lab 所在文件系统带 nosuid（$MOUNT_OPTS）" ;;
  *) bad "本 lab 所在文件系统缺少 nosuid（$MOUNT_OPTS）" ;;
esac

section "7. 数值属主观察（ls -n / stat）"
: > "$TMP/owned"
stat -c 'numeric: uid=%u gid=%g mode=%a name=%n' "$TMP/owned"
ls -ln "$TMP/owned"
if [ "$(stat -c '%u' "$TMP/owned")" = "$MYUID" ]; then
  ok "自建文件数值属主等于当前 uid（$MYUID）"
else
  bad "自建文件数值属主不是当前 uid"
fi
printf '宿主视角 /etc/shadow 的数值属主: %s（本会话根文件系统属主显示为 65534:65534）\n' \
  "$(stat -c '%u:%g' /etc/shadow)"
printf '当前 /proc/self/uid_map:\n'
cat /proc/self/uid_map

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
