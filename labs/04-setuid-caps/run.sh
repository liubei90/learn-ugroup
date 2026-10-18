#!/usr/bin/env bash
# labs/04-setuid-caps/run.sh
# 宿主 gcc 编译静态程序 + docker debian:13 内演示 SUID / no_new_privs / file capability。
# 依赖：gcc（宿主）、docker、debian:13 镜像；容器内 apt 安装 libcap2-bin 需要网络，失败只 SKIP。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP="$LAB_DIR/.tmp"
CNAME="learnugroup-04-setuid-caps-$$"
PASS=0
FAIL=0

ok()   { printf 'ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

cleanup() {
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
rm -rf -- "$TMP"
mkdir -p -- "$TMP/bin"
trap cleanup EXIT

finish_skip() {
  skip "$1"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
}

section "1. 检查依赖"
if ! command -v gcc >/dev/null 2>&1; then
  finish_skip "宿主 gcc 不可用（Debian: apt install gcc）"
fi
ok "宿主 gcc 可用（$(gcc --version | head -n 1)）"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  finish_skip "docker 不可用（需要 docker daemon）"
fi
if ! docker image inspect debian:13 >/dev/null 2>&1; then
  finish_skip "本地没有 debian:13 镜像"
fi
ok "docker 可用且本地存在 debian:13 镜像"

section "2. 宿主 gcc 静态编译两个观察程序"
if ! gcc -static -O2 -o "$TMP/bin/uidinfo" "$LAB_DIR/src/uidinfo.c" 2>"$TMP/gcc1.err"; then
  sed -n '1,10p' "$TMP/gcc1.err"
  finish_skip "静态编译 uidinfo 失败（可能缺 static libc：apt install libc6-dev）"
fi
if ! gcc -static -O2 -o "$TMP/bin/capread" "$LAB_DIR/src/capread.c" 2>"$TMP/gcc2.err"; then
  sed -n '1,10p' "$TMP/gcc2.err"
  finish_skip "静态编译 capread 失败"
fi
file "$TMP/bin/uidinfo" "$TMP/bin/capread"
ok "两个程序均静态编译成功"

section "3. 容器内：useradd alice、放 SUID 程序、跑 no_new_privs、装 libcap2-bin"
cat > "$TMP/inner.sh" <<'INNER'
#!/bin/bash
set -u
echo "--- 容器内身份"
id
useradd -m -u 1000 -s /bin/bash alice
echo "USER $(id -u alice) $(id -un alice)"
mkdir -p /root
printf 'TOP-SECRET\n' > /root/secret.txt
chmod 600 /root/secret.txt
cp /lab/.tmp/bin/uidinfo /usr/local/bin/uidinfo
chown root:root /usr/local/bin/uidinfo
chmod 4755 /usr/local/bin/uidinfo
echo "--- SUID 文件的 ls -l"
ls -l /usr/local/bin/uidinfo
echo "--- SUID 运行（alice 执行 root 属主程序）"
su alice -c /usr/local/bin/uidinfo | sed 's/^/SUID /'
echo "--- no_new_privs 运行"
if command -v setpriv >/dev/null 2>&1; then
    su alice -c "setpriv --no-new-privs /usr/local/bin/uidinfo" | sed 's/^/NNP /'
else
    echo "NNP setpriv-missing"
fi
echo "--- file capability 部分"
if apt-get update -qq >/dev/null 2>&1 \
   && apt-get install -y -qq --no-install-recommends libcap2-bin >/dev/null 2>&1; then
    cp /lab/.tmp/bin/capread /usr/local/bin/capread
    chmod 755 /usr/local/bin/capread
    setcap cap_dac_override=ep /usr/local/bin/capread
    echo "GETCAP $(getcap /usr/local/bin/capread)"
    su alice -c /usr/local/bin/capread | sed 's/^/CAP /'
    echo "APTX ok"
else
    echo "APTX failed"
fi
INNER

CONTAINER_OUT=$(timeout 300 docker run --rm --name "$CNAME" -v "$LAB_DIR":/lab \
  debian:13 bash /lab/.tmp/inner.sh 2>&1)
CONTAINER_RC=$?
printf '%s\n' "$CONTAINER_OUT"

if [ "$CONTAINER_RC" -ne 0 ]; then
  bad "容器内脚本退出码 $CONTAINER_RC"
else
  ok "容器内脚本正常结束"
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^USER 1000 alice$'; then
    ok "容器内已创建 alice（uid=1000）"
  else
    bad "容器内未创建 alice 或 uid 不符"
  fi
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^-rwsr-xr-x.* /usr/local/bin/uidinfo$'; then
    ok "SUID 程序权限位为 -rwsr-xr-x（root 属主）"
  else
    bad "SUID 程序权限位不符"
  fi
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^SUID real=1000 effective=0 saved=0'; then
    ok "SUID 执行后 euid=0、saved=0（真实 uid 仍为 alice 1000）"
  else
    bad "SUID 执行后 euid/saved 不符"
  fi
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^SUID read /root/secret.txt: OK -> TOP-SECRET$'; then
    ok "SUID 程序以 euid=0 读到 /root/secret.txt（600）"
  else
    bad "SUID 程序未能读到 /root/secret.txt"
  fi
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^NNP real=1000 effective=1000 saved=1000'; then
    ok "no_new_privs 下 SUID 失效：euid 保持 1000"
  else
    bad "no_new_privs 下 euid 不是 1000"
  fi
  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^NNP read /root/secret.txt: DENIED'; then
    ok "no_new_privs 下读取 /root/secret.txt 被拒绝"
  else
    bad "no_new_privs 下读取结果不符"
  fi

  if printf '%s\n' "$CONTAINER_OUT" | grep -q '^APTX ok$'; then
    if printf '%s\n' "$CONTAINER_OUT" | grep -q '^GETCAP .*cap_dac_override=ep$'; then
      ok "getcap 显示 cap_dac_override=ep"
    else
      bad "getcap 输出不含 cap_dac_override=ep"
    fi
    if printf '%s\n' "$CONTAINER_OUT" | grep -q '^CAP uid=1000 euid=1000 CapEff= 0000000000000002$'; then
      ok "普通用户执行带 file capability 的程序：CapEff=0x2（CAP_DAC_OVERRIDE）"
    else
      bad "CapEff 不是 0000000000000002"
    fi
    if printf '%s\n' "$CONTAINER_OUT" | grep -q '^CAP read /root/secret.txt: OK -> TOP-SECRET$'; then
      ok "capability 路径下读到 /root/secret.txt（无需 SUID）"
    else
      bad "capability 路径下读取失败"
    fi
  else
    skip "容器内 apt 安装 libcap2-bin 失败（无网络？），跳过 capability 断言"
  fi
fi

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
