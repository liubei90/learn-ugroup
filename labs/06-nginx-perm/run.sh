#!/usr/bin/env bash
# labs/06-nginx-perm/run.sh
# docker nginx:1.20-alpine：master root / worker nginx(101)、600 文件 403、error.log 权限拒绝、chmod 644 修复、目录 700 403。
set -u
export LC_ALL=C

LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP="$LAB_DIR/.tmp"
CNAME="learnugroup-06-nginx-perm-$$"
PORT="${LEARNUGROUP_PORT:-18080}"
BASE="http://127.0.0.1:$PORT"
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
mkdir -p -- "$TMP/html/subdir"
trap cleanup EXIT

finish_skip() {
  skip "$1"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 0
}

code() { curl -s -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }
get()  { curl -s "$1" 2>/dev/null || true; }

section "1. 依赖检查"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  finish_skip "docker 不可用（需要 docker daemon）"
fi
if ! docker image inspect nginx:1.20-alpine >/dev/null 2>&1; then
  finish_skip "本地没有 nginx:1.20-alpine 镜像"
fi
if ! command -v curl >/dev/null 2>&1; then
  finish_skip "缺少 curl，无法断言 HTTP 状态码"
fi
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
  finish_skip "端口 $PORT 已被占用（可用 LEARNUGROUP_PORT=18081 重跑）"
fi
ok "docker、nginx:1.20-alpine、curl 均可用，端口 $PORT 空闲"

section "2. 准备站点文件（属主 1000）"
printf '<h1>index-ok</h1>\n' > "$TMP/html/index.html"
printf '<h1>secret-ok</h1>\n' > "$TMP/html/secret.html"
printf '<h1>subdir-ok</h1>\n' > "$TMP/html/subdir/index.html"
chmod 644 "$TMP/html/index.html" "$TMP/html/subdir/index.html"
chmod 600 "$TMP/html/secret.html"
ls -ln "$TMP/html" "$TMP/html/subdir"

section "3. 启动 nginx 容器（只挂载本 lab 的 html 目录，只读）"
if ! docker run -d --rm --name "$CNAME" -p "127.0.0.1:$PORT:80" \
     -v "$TMP/html":/usr/share/nginx/html:ro nginx:1.20-alpine >"$TMP/cid" 2>"$TMP/run.err"; then
  finish_skip "nginx 容器启动失败（端口被占用或镜像问题）：$(tail -n 1 "$TMP/run.err")"
fi
READY=0
for _ in $(seq 1 40); do
  if [ "$(code "$BASE/")" = "200" ]; then READY=1; break; fi
  sleep 0.25
done
if [ "$READY" -ne 1 ]; then
  echo '--- 容器日志（启动失败排查）'
  docker logs "$CNAME" 2>&1 | tail -n 20
  bad "nginx 在 10 秒内没有返回 200"
  printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
  exit 1
fi
ok "nginx 已就绪，GET / 返回 200"

section "4. 进程模型：master=root，worker=nginx(101)"
NGINX_ID=$(docker exec "$CNAME" id nginx)
printf 'id nginx: %s\n' "$NGINX_ID"
case "$NGINX_ID" in
  "uid=101(nginx)"*) ok "worker 用户 nginx 的 uid=101" ;;
  *) bad "worker 用户 uid 不是 101：$NGINX_ID" ;;
esac
PS_OUT=$(docker exec "$CNAME" ps -o pid,user,args | head -n 6)
printf '%s\n' "$PS_OUT"
if printf '%s\n' "$PS_OUT" | grep -q 'master process' \
   && printf '%s\n' "$PS_OUT" | grep 'master process' | grep -q 'root'; then
  ok "master process 以 root 运行"
else
  bad "没有看到 root 运行的 master process"
fi
if printf '%s\n' "$PS_OUT" | grep 'worker process' | grep -q 'nginx'; then
  ok "worker process 以 nginx 运行"
else
  bad "没有看到 nginx 运行的 worker process"
fi
USER_DIRECTIVE=$(docker exec "$CNAME" grep -n '^user' /etc/nginx/nginx.conf)
WORKERS=$(docker exec "$CNAME" sh -c "ps -o args | grep -c 'worker process'" || true)
printf 'worker 进程数: %s\n' "$WORKERS"
printf 'nginx.conf: %s\n' "$USER_DIRECTIVE"
case "$USER_DIRECTIVE" in
  *"user  nginx;"*) ok "配置里 user 指令把 worker 指定为 nginx" ;;
  *) bad "nginx.conf 的 user 指令不是 nginx" ;;
esac

section "5. 600 文件导致 403，error.log 记录 Permission denied"
SECRET_CODE=$(code "$BASE/secret.html")
printf 'GET /secret.html -> %s\n' "$SECRET_CODE"
if [ "$SECRET_CODE" = "403" ]; then
  ok "模式 600 的 secret.html 返回 403"
else
  bad "secret.html 返回 $SECRET_CODE，预期 403"
fi
ERRLOG=$(timeout 5 docker exec "$CNAME" tail -n 20 /var/log/nginx/error.log 2>&1 || true)
if ! printf '%s\n' "$ERRLOG" | grep -q 'Permission denied'; then
  ERRLOG=$(docker logs "$CNAME" 2>&1 | tail -n 20)
fi
printf '%s\n' '--- nginx error.log（截取含 Permission denied 的行）---'
printf '%s\n' "$ERRLOG" | grep 'Permission denied' | tail -n 2 || printf '%s\n' "$ERRLOG" | tail -n 5
if printf '%s\n' "$ERRLOG" | grep 'secret.html' | grep -q '(13: Permission denied)'; then
  ok "error.log 含 secret.html 的 (13: Permission denied)"
else
  bad "error.log 未记录 secret.html 的 (13: Permission denied)"
fi

section "6. chmod 644 修复：403 -> 200"
chmod 644 "$TMP/html/secret.html"
sleep 0.2
SECRET_CODE=$(code "$BASE/secret.html")
SECRET_BODY=$(get "$BASE/secret.html")
printf 'GET /secret.html -> %s body=%s\n' "$SECRET_CODE" "$SECRET_BODY"
if [ "$SECRET_CODE" = "200" ] && printf '%s' "$SECRET_BODY" | grep -q 'secret-ok'; then
  ok "chmod 644 后 secret.html 返回 200 且内容正确"
else
  bad "chmod 644 后仍不正常（code=$SECRET_CODE）"
fi

section "7. 目录缺 x 位（700）导致 403；chmod 755 修复"
chmod 700 "$TMP/html/subdir"
SUBDIR_CODE=$(code "$BASE/subdir/index.html")
printf 'GET /subdir/index.html（目录 700）-> %s\n' "$SUBDIR_CODE"
if [ "$SUBDIR_CODE" = "403" ]; then
  ok "父目录 700 时 644 的 index.html 也返回 403"
else
  bad "目录 700 时返回 $SUBDIR_CODE，预期 403"
fi
chmod 755 "$TMP/html/subdir"
SUBDIR_CODE=$(code "$BASE/subdir/index.html")
SUBDIR_BODY=$(get "$BASE/subdir/index.html")
printf 'GET /subdir/index.html（目录 755）-> %s body=%s\n' "$SUBDIR_CODE" "$SUBDIR_BODY"
if [ "$SUBDIR_CODE" = "200" ] && printf '%s' "$SUBDIR_BODY" | grep -q 'subdir-ok'; then
  ok "目录补回 x 位后返回 200"
else
  bad "目录补回 x 位后仍不正常（code=$SUBDIR_CODE）"
fi

printf '\nPASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
