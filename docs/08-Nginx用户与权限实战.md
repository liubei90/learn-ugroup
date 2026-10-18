# 08 Nginx 用户与权限实战

> **一句话总结**：看清 master(root)/worker(nginx) 的权限分工，用一条排查树定位 403/404。

> **本机验证**：⚠️ 宿主未安装 nginx，全部现象用 `nginx:1.20-alpine` 容器复现，输出标注「容器内」；系统包路径用 `debian:13` 容器内安装 nginx 实测。

| 项目 | 内容 |
|---|---|
| 回答的问题 | 为什么 nginx 要有 root master 和 nginx worker？403 到底是文件、目录、index 还是 LSM 造成的？非 root 能不能跑 nginx？ |
| 适合读者 | 配置过 nginx，但遇到 403/404、日志写不进去、上传目录失败、unix socket 502 时只能靠猜的工程师 |
| 前置阅读 | [04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[05-提权与降权机制](05-提权与降权机制.md)、[07-Docker用户与权限实战](07-Docker用户与权限实战.md) |
| 主要来源 | `nginx:1.20-alpine` 容器内 `nginx -V` 与配置、`man 7 capabilities`、`man 7 unix`、`man 5 systemd.exec`、本机实测 |

---

## 一、先建立直觉

### 1.1 一个 master，多个 worker

nginx 启动后至少有两个角色：

- **master**：以 root 启动，读取配置、绑定端口、打开日志与 pid 文件、创建缓存临时目录，然后 `fork` 出 worker；
- **worker**：以 `user` 指令指定的用户运行（官方镜像里是 `nginx`，Alpine 内 uid 101），处理请求、读静态文件、写日志。

master 负责启动期的一次性操作，worker 负责处理请求；两者由 `fork` 形成父子关系（验证：§2.1 的 `ps -o pid,ppid,user,args`）。把「谁需要什么权限」按这两个角色分开，403/启动失败的排查会清晰很多。

### 1.2 进程、文件与权限的关系

```text
               启动阶段（root）
  ┌────────────────────────────────────────────────────┐
  │ nginx: master process (uid=0)                      │
  │  · 读 /etc/nginx/nginx.conf                        │
  │  · bind 0.0.0.0:80        ← CAP_NET_BIND_SERVICE   │
  │  · open /var/log/nginx/error.log                   │
  │  · open /var/log/nginx/access.log                  │
  │  · write /run/nginx.pid                            │
  │  · mkdir /var/cache/nginx/*_temp 并 chown nginx    │
  └───────────────┬────────────────────────────────────┘
                  │ fork + setuid(user)
                  ▼
  ┌────────────────────────────────────────────────────┐
  │ nginx: worker process (uid=101 nginx)              │
  │  · 继承监听 socket、日志 fd                         │
  │  · 读静态文件：需要文件 r + 每一级父目录 x          │
  │  · 写日志：用继承来的 fd，不再检查目录/文件权限     │
  │  · 写缓存/上传：需要 *_temp 目录的 w+x              │
  │  · 连上游 unix socket：需要 socket 文件的 w         │
  └────────────────────────────────────────────────────┘
```

> 图：nginx 两个角色的权限分工。**启动阶段一次性的操作由 root 完成，运行阶段的读写由 worker 承担**，这是很多「日志目录 750 为什么还能写」「非 root 启动为什么 mkdir 失败」的答案。

### 1.3 为什么 master 需要 root

三个硬需求：

1. **绑定特权端口**：Linux 上绑定 <1024 端口需要 `CAP_NET_BIND_SERVICE`（来源：`man 7 capabilities`：CAP_NET_BIND_SERVICE — Bind a socket to Internet domain privileged ports (port numbers less than 1024)）。root 默认拥有它。
2. **打开 root 拥有的日志与 pid 文件**：系统包把 `/var/log/nginx` 设成 `root:adm 750`，worker 用户进不去；master 在降权前打开文件，worker 继承 fd（验证：§2.4 的 `ls -ldn /var/log/nginx` 与日志 fd 继承实验）。
3. **在系统目录创建临时目录**：`/var/cache/nginx`（镜像）或 `/var/lib/nginx`（Debian 包）属于 root，master 负责 mkdir 并把属主改成 worker（验证：§2.4 启动后的 `ls -ldn` 输出）。

这也是为什么 nginx 的启动顺序通常是：读配置 → 绑定端口 → 打开日志 → 建临时目录 → fork 并 setuid。

### 1.4 worker 为什么必须降权

worker 直接解析网络请求、读用户上传的文件、执行正则与模块代码，是攻击面最大的进程。让它以 `nginx` 而非 root 运行，可以把「请求处理漏洞」的影响限制在 worker 权限内。`user` 指令就是降权声明：

```text
user  nginx;
```

验证：官方镜像内的配置与编译默认值。

```bash
docker run --rm --name learnugroup-08-e1 nginx:1.20-alpine sh -c 'id nginx; grep -n "^user" /etc/nginx/nginx.conf; nginx -V 2>&1 | tr " " "\n" | grep -E "user|prefix|conf-path"'
```

在本机执行上述命令的输出（容器内）：

```text
uid=101(nginx) gid=101(nginx) groups=101(nginx),101(nginx)
2:user  nginx;
--prefix=/etc/nginx
--conf-path=/etc/nginx/nginx.conf
--user=nginx
```

### 1.5 本章在全局模型中的位置

用 [01-权限模型全景](01-权限模型全景.md) 的三要素看 nginx：

- 主体：master 是 uid 0，worker 是 uid 101（来自 `user` 指令）；
- 资源：配置文件、docroot、日志、pid、缓存目录、unix socket、端口；
- 规则：DAC（mode/ACL）+ capability（端口）+ LSM（AppArmor/SELinux）。

nginx 自身不创造权限规则，它只是把内核规则映射到「master 先做、worker 后做」的流程上。

---

## 二、进程模型与权限需求

### 2.1 实测进程模型：master root，worker nginx(101)

```bash
docker run -d --rm --name learnugroup-08-ps -p 127.0.0.1:18080:80 nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-ps ps -o pid,ppid,user,args | head -5
docker exec learnugroup-08-ps nproc
docker exec learnugroup-08-ps sh -c "ps -o pid,args | grep -cE '^ *[0-9]+ nginx: worker process$'"
docker exec learnugroup-08-ps id nginx
docker rm -f learnugroup-08-ps
```

在本机执行上述命令的输出（容器内）：

```text
PID   PPID  USER     COMMAND
    1     0 root     nginx: master process nginx -g daemon off;
   32     1 nginx    nginx: worker process
   33     1 nginx    nginx: worker process
   34     1 nginx    nginx: worker process
20
20
uid=101(nginx) gid=101(nginx) groups=101(nginx),101(nginx)
```

`worker_processes auto` 会按 CPU 数创建 worker；本机容器内 `nproc` 为 20，所以看到 20 个 worker。验证：`grep -n worker_processes /etc/nginx/nginx.conf` → `3:worker_processes  auto;`。

**一个容易误判的细节**：在宿主用 `docker top` 看同一批进程，worker 会显示成 `tss` 而不是 `nginx`：

```bash
docker run -d --rm --name learnugroup-08-top -p 127.0.0.1:18081:80 nginx:1.20-alpine
sleep 1
docker top learnugroup-08-top -eo pid,ppid,user,args | head -5
docker rm -f learnugroup-08-top
```

在本机执行上述命令的输出（宿主视角）：

```text
PID                 PPID                USER                COMMAND
810748              810722              root                nginx: master process nginx -g daemon off;
810810              810748              tss                 nginx: worker process
810811              810748              tss                 nginx: worker process
```

原因：`docker top` 用**宿主**的 `/etc/passwd` 解析 uid，本机宿主 uid 101 是 `tss`；nginx 容器里 uid 101 是 `nginx`。uid 是数字，名字只影响显示——这本身就是一个「不要用名字判断身份」的好例子。

验证：宿主 `getent passwd 101` → `tss:x:101:103:TPM software stack:/var/lib/tpm:/bin/false`；容器内 `getent passwd nginx` → `nginx:x:101:101:nginx:/var/cache/nginx:/sbin/nologin`。

worker 的 capability 在降权后为空：

```bash
docker run -d --rm --name learnugroup-08-cap -p 127.0.0.1:18080:80 nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-cap sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = nginx ] || continue; echo "pid=${p#/proc/} $(grep -E "^(Uid|CapEff|NoNewPrivs)" $p/status | tr "\n" " ")"; done'
docker rm -f learnugroup-08-cap
```

在本机执行上述命令的输出（容器内，已删去重复的 worker 行）：

```text
pid=1 Uid:	0	0	0	0 CapEff:	00000000a80425fb NoNewPrivs:	0
pid=32 Uid:	101	101	101	101 CapEff:	0000000000000000 NoNewPrivs:	0
...（其余 worker 与 pid=32 相同）
```

worker 没有任何 capability，因此它不能绕过 DAC 检查，也不能 chown；它只能靠自己的 uid/gid 与文件 mode/ACL 获得权限。

### 2.2 降权与 `user` 指令的生效条件

- master 以 root 启动时，`user` 指令生效：worker `setuid` 到指定用户；镜像的 `nginx` 用户在 Alpine 里是 uid 101（来源：`/etc/passwd`，验证：`id nginx`）。
- master **本身不是 root** 时，`user` 指令被忽略并打印警告。验证：

```bash
docker run --rm --name learnugroup-08-warn -u 101:101 --entrypoint nginx nginx:1.20-alpine -g 'daemon off;'
```

在本机执行上述命令的输出（容器内）：

```text
2026/10/18 01:41:41 [warn] 1#1: the "user" directive makes sense only if the master process runs with super-user privileges, ignored in /etc/nginx/nginx.conf:2
nginx: [warn] the "user" directive makes sense only if the master process runs with super-user privileges, ignored in /etc/nginx/nginx.conf:2
2026/10/18 01:41:41 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

这段输出同时给出两个事实：非 root master 无法切换 worker 用户；默认配置里的缓存目录 `/var/cache/nginx` 属于 root，非 root 启动时 `mkdir` 直接失败（详见 §2.10 配方）。

### 2.3 master/worker 权限需求矩阵

| 资源 | master 需要 | worker 需要 | 说明 |
|---|---|---|---|
| `/etc/nginx/nginx.conf` 与 `conf.d/*.conf` | r（启动/重载时读） | 不需要 | worker 继承解析结果；本身不读配置 |
| docroot 静态文件 | 不必读 | r + 每一级父目录 x | 403 的第一现场；root 也受目录 x 约束（除非有 CAP_DAC_READ_SEARCH 等） |
| 错误日志文件 | w + 打开时目录 x | 用继承 fd 写 | 文件通常 `www-data:adm 640`，目录 `root:adm 750` |
| 访问日志文件 | w + 打开时目录 x | 用继承 fd 写 | master 打开后 fork，worker 继承 |
| pid 文件（如 `/run/nginx.pid`） | 目录 w + 文件创建/写 | 不需要 | 通常 root:root 644 |
| 缓存/临时目录（`client_body_temp_path` 等） | mkdir + chown 给 worker | 目录内 rwx | 镜像启动后 `700 101:0`（§2.4 实测） |
| 上传目录 | 不需要 | 目录 w+x（必要时文件 r） | 处理请求时 worker 写 |
| 监听 `<1024` 端口 | `CAP_NET_BIND_SERVICE` | 不需要（继承 socket） | master 绑定 |
| 监听 `unix:` socket | 创建 socket（目录 w+x） | 继承 fd，accept | socket 文件属主/权限决定谁能连接 |
| 上游 unix socket（php-fpm 等） | 不需要 | socket 文件 w（连接需要写权限） | `man 7 unix`：connect stream socket 需要对 socket 写 |
| 证书私钥 | 启动/重载时读 | 不需要（继承 SSL 上下文） | 私钥权限应只给 master 用户；本机未构造证书实验 |

“worker 用继承 fd 写日志”不是推测：master 打开日志后 fork，worker 即使无法重新打开文件也能写。§2.4 用“把日志改成 640 root:root 后仍能记录请求”验证了这一点。

### 2.4 日志与缓存目录：master 打开，worker 继承

#### 官方镜像：日志是 stdout/stderr 的符号链接

```bash
docker run --rm --name learnugroup-08-ls nginx:1.20-alpine sh -c 'ls -ldn /var/log/nginx /var/cache/nginx; ls -ln /var/log/nginx'
```

在本机执行上述命令的输出（容器内）：

```text
drwxr-xr-x    2 0        0             4096 May 17  2022 /var/cache/nginx
drwxr-xr-x    2 0        0             4096 May 17  2022 /var/log/nginx
total 0
lrwxrwxrwx    1 0        0               11 May 17  2022 access.log -> /dev/stdout
lrwxrwxrwx    1 0        0               11 May 17  2022 error.log -> /dev/stderr
```

容器里日志直接进 stdout/stderr（`docker logs` 能看到），所以镜像场景很少遇到“日志目录不可写”。但一旦你把日志改到文件，就回到 master/worker 权限模型。

#### 启动后创建的缓存目录

```bash
docker run -d --rm --name learnugroup-08-cache -p 127.0.0.1:18082:80 nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-cache sh -c 'ls -ldn /var/cache/nginx /var/cache/nginx/*; ls -ln /var/run/nginx.pid'
docker rm -f learnugroup-08-cache
```

在本机执行上述命令的输出（容器内）：

```text
drwxr-xr-x    1 0        0             4096 Oct 18 01:40 /var/cache/nginx
drwx------    2 101      0             4096 Oct 18 01:40 /var/cache/nginx/client_temp
drwx------    2 101      0             4096 Oct 18 01:40 /var/cache/nginx/fastcgi_temp
drwx------    2 101      0             4096 Oct 18 01:40 /var/cache/nginx/proxy_temp
drwx------    2 101      0             4096 Oct 18 01:40 /var/cache/nginx/scgi_temp
drwx------    2 101      0             4096 Oct 18 01:40 /var/cache/nginx/uwsgi_temp
-rw-r--r--    1 0        0                2 Oct 18 01:40 /var/run/nginx.pid
```

要点：

- 缓存子目录由 master（root）创建，属主改成 nginx(101)、模式 700；worker 能读写，其他用户不能。
- pid 文件 root:root 644，由 master 写；worker 不需要。
- 如果换了缓存路径（例如挂载到宿主目录），必须保证 master 能 mkdir、worker 能读写，否则启动报 `mkdir() ... failed (13: Permission denied)` 或运行时 `open() ... failed (13: Permission denied)`。

#### 日志 fd 继承的直接验证

把日志放到一个宿主目录，目录 700、日志文件由 master 创建；启动后把日志文件改成 `640 root:root`（worker 无法重新 open），再发请求：

```bash
mkdir -p demo/logs demo/www && chmod 700 demo/logs
printf 'logdemo-ok\n' > demo/www/index.html
cat > demo/nginx-log.conf <<'EOF'
worker_processes 2;
error_log /logs/error.log warn;
pid /tmp/nginx.pid;
events { worker_connections 64; }
http {
  access_log /logs/access.log;
  client_body_temp_path /tmp/client_temp;
  proxy_temp_path       /tmp/proxy_temp;
  fastcgi_temp_path     /tmp/fastcgi_temp;
  uwsgi_temp_path       /tmp/uwsgi_temp;
  scgi_temp_path        /tmp/scgi_temp;
  server { listen 8080; root /srv/www; location / { } }
}
EOF
docker run -d --rm --name learnugroup-08-log -p 127.0.0.1:18083:8080 \
  -v "$PWD/demo/logs":/logs -v "$PWD/demo/www":/srv/www:ro \
  -v "$PWD/demo/nginx-log.conf":/etc/nginx/nginx.conf:ro nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-log chmod 640 /logs/access.log
docker exec learnugroup-08-log ls -ln /logs/access.log
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:18083/
docker exec learnugroup-08-log cat /logs/access.log
```

在本机执行上述命令的输出（容器内）：

```text
-rw-r-----    1 0        0                0 Oct 18 01:43 /logs/access.log
HTTP 200
172.17.0.1 - - [18/Oct/2026:01:43:25 +0000] "GET / HTTP/1.1" 200 11 "-" "curl/8.14.1"
```

worker 的 uid 是 101，文件是 `640 root:root`，它**无法重新打开**该文件；请求能成功且日志有记录，只能是因为它继承了 master 在降权前打开的 fd。master 侧的证据：

```bash
docker exec learnugroup-08-log sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm)" = nginx ] || continue; echo "pid=${p#/proc/} $(grep "^Uid" $p/status)"; ls -l $p/fd 2>/dev/null | grep -E "logs"; done'
```

在本机执行上述命令的输出（容器内）：

```text
pid=1 Uid:	0	0	0	0
l-wx------    1 root     root            64 Oct 18 01:43 2 -> /logs/error.log
l-wx------    1 root     root            64 Oct 18 01:43 5 -> /logs/error.log
l-wx------    1 root     root            64 Oct 18 01:43 6 -> /logs/access.log
```

worker 的 `/proc/<pid>/fd/*` 链接读取被拒绝（`Permission denied`）：worker 降权后进程 `dumpable=0`，普通 root（在容器内没有 `CAP_SYS_PTRACE`）不能读它的 fd 链接。这不妨碍结论——日志写入与 master fd 已经证明继承关系；顺便说明 `/proc/PID/fd` 不是任何时候都能读（见 09 章）。

#### Debian 系统包：日志目录属于 root:adm

在 `debian:13` 容器内安装 nginx 包后实测：

```bash
docker run --rm --name learnugroup-08-pkg -v "$PWD":/w debian:13 bash -c '
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends nginx >/dev/null 2>&1
nginx -v 2>&1; id www-data
grep -nE "^(user|worker_processes|pid|error_log)" /etc/nginx/nginx.conf
ls -ldn /var/log/nginx /var/log/nginx/error.log /var/lib/nginx /etc/nginx/sites-enabled
ls -ln /etc/nginx/sites-enabled | head -3
grep -nE "listen|root|index " /etc/nginx/sites-enabled/default | head -5
nginx; sleep 0.3
ls -ldn /var/lib/nginx/*
ls -ln /run/nginx.pid
'
```

在本机执行上述命令的输出（容器内；`ps` 在 debian:13 基础镜像里没有安装，进程模型用官方镜像的实测结果）：

```text
nginx version: nginx/1.26.3
uid=33(www-data) gid=33(www-data) groups=33(www-data)
1:user www-data;
2:worker_processes auto;
4:pid /run/nginx.pid;
5:error_log /var/log/nginx/error.log;
drwxr-xr-x 2  0 0 4096 Oct 18 01:49 /etc/nginx/sites-enabled
drwxr-xr-x 2  0 0 4096 Sep 15 09:28 /var/lib/nginx
drwxr-xr-x 2  0 4 4096 Oct 18 01:49 /var/log/nginx
-rw-r----- 1 33 4    0 Oct 18 01:49 /var/log/nginx/error.log
total 0
lrwxrwxrwx 1 0 0 34 Oct 18 01:49 default -> /etc/nginx/sites-available/default
22:	listen 80 default_server;
23:	listen [::]:80 default_server;
27:	# listen 443 ssl default_server;
28:	# listen [::]:443 ssl default_server;
41:	root /var/www/html;
drwx------ 2 33 0 4096 Oct 18 01:49 /var/lib/nginx/body
drwx------ 2 33 0 4096 Oct 18 01:49 /var/lib/nginx/fastcgi
drwx------ 2 33 0 4096 Oct 18 01:49 /var/lib/nginx/proxy
drwx------ 2 33 0 4096 Oct 18 01:49 /var/lib/nginx/scgi
drwx------ 2 33 0 4096 Oct 18 01:49 /var/lib/nginx/uwsgi
-rw-r--r-- 1 0 0 4 Oct 18 01:49 /run/nginx.pid
```

关键差异：系统包用 `www-data`(33)，日志目录 `root:adm 750`、日志文件 `www-data:adm 640`；缓存目录是 `/var/lib/nginx`，启动后建 `700 33:0` 的子目录；pid 在 `/run/nginx.pid`。这些路径与官方镜像不同，排障时先确认你用的是哪一种（§2.9）。

### 2.5 403/404 排查树

```text
请求 GET /path
│
├─ nginx 能定位到文件吗？
│   ├─ 否（ENOENT）──────────────────────────────▶ 404
│   │   错误日志：open() ".../path" failed (2: No such file or directory)
│   │   检查：root 拼接、alias、try_files、符号链接目标
│   └─ 是
│       ├─ 父目录缺 x（无法 traverse）────────────▶ 403
│       │   错误日志：open() ".../path" failed (13: Permission denied)
│       │   检查：从 docroot 到文件每一级目录的 o+x（或 ACL）
│       ├─ 文件缺 r ─────────────────────────────▶ 403
│       │   错误日志：open() ".../path" failed (13: Permission denied)
│       │   检查：文件 mode/属主/ACL，worker uid 是否匹配
│       ├─ 请求目录且无 index、autoindex off ─────▶ 403
│       │   错误日志：directory index of ".../" is forbidden
│       │   检查：index 文件名、是否漏配 index
│       ├─ deny/allow、auth 等访问规则 ──────────▶ 403/401
│       │   检查：配置里的 deny、auth_basic、limit_except
│       └─ LSM（AppArmor/SELinux）拒绝 ──────────▶ 403/500（视策略）
│           检查：dmesg/journalctl、aa-status、audit.log
│
└─ 上游/后端问题不在本树：502/504 看 §2.7
```

> 图：403/404 排查树。**先看 error.log 的 errno**：`2` 是路径不存在，`13` 是权限被拒，`directory index ... forbidden` 是缺 index；三者修法完全不同。

本机实测（docroot 只读挂载，文件属主 1000）：

```bash
mkdir -p demo/html/private demo/html/noindex
printf 'INDEX-OK\n' > demo/html/index.html
printf 'secret\n' > demo/html/secret.html
printf 'private\n' > demo/html/private/p.html
printf 'hidden\n' > demo/html/noindex/data.html
chmod 600 demo/html/secret.html
chmod 700 demo/html/private
chmod 755 demo/html/noindex
docker run -d --rm --name learnugroup-08-403 -p 127.0.0.1:18080:80 -v "$PWD/demo/html":/usr/share/nginx/html:ro nginx:1.20-alpine
sleep 1
for u in / /secret.html /private/p.html /noindex/ /missing.html; do printf '%-18s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18080$u"; done
docker logs learnugroup-08-403 2>&1 | grep -E 'Permission denied|directory index|open\(\)' | tail -n 6
```

在本机执行上述命令的输出（HTTP 状态来自宿主 curl；错误日志来自容器 stderr）：

```text
/                  200
/secret.html       403
/private/p.html    403
/noindex/          403
/missing.html      404
2026/10/18 01:41:34 [error] 31#31: *2 open() "/usr/share/nginx/html/secret.html" failed (13: Permission denied), client: 172.17.0.1, server: localhost, request: "GET /secret.html HTTP/1.1", host: "127.0.0.1:18080"
2026/10/18 01:41:34 [error] 31#31: *3 open() "/usr/share/nginx/html/private/p.html" failed (13: Permission denied), client: 172.17.0.1, server: localhost, request: "GET /private/p.html HTTP/1.1", host: "127.0.0.1:18080"
2026/10/18 01:41:34 [error] 31#31: *4 directory index of "/usr/share/nginx/html/noindex/" is forbidden, client: 172.17.0.1, server: localhost, request: "GET /noindex/ HTTP/1.1", host: "127.0.0.1:18080"
2026/10/18 01:41:34 [error] 31#31: *5 open() "/usr/share/nginx/html/missing.html" failed (2: No such file or directory), client: 172.17.0.1, server: localhost, request: "GET /missing.html HTTP/1.1", host: "127.0.0.1:18080"
```

对应修复：

```bash
chmod 644 demo/html/secret.html
chmod 711 demo/html/private
curl -s -o /dev/null -w '/secret.html %{http_code}\n' http://127.0.0.1:18080/secret.html
curl -s -o /dev/null -w '/private/p.html %{http_code}\n' http://127.0.0.1:18080/private/p.html
docker rm -f learnugroup-08-403
```

在本机执行上述命令的输出：

```text
/secret.html 200
/private/p.html 200
```

为什么目录 700 → 711 就够了：worker 只需要「进入并遍历」目录（x），不需要列目录（r）。文件 644 给 other 读权限，worker 就能读；如果文件属主是容器内 nginx(101)，600 也可以。**修法取决于改动哪一侧**：文件侧给 worker 读权限，或把文件属主/组改成 worker 可读。

验证：worker 的实际 uid 见 §2.1；错误日志里的 `13` 是 `EACCES`，`2` 是 `ENOENT`。

### 2.6 写操作与上传：worker 需要目录 w

静态站点只读；上传、缓存、临时文件需要 worker 写：

- `client_body_temp_path`：请求体超过内存缓冲时落盘，worker 需要该目录的 rwx；
- `proxy_temp_path`/`fastcgi_temp_path` 等：代理/上游响应临时文件；
- 业务上传目录：worker 需要目录 w+x（写文件还要看目录 x；是否可读取决于下载逻辑）。

镜像启动后这些目录是 `700 101:0`（§2.4），worker 可写，所以默认上传不会因权限失败。若你把这些路径挂到宿主目录（如 `-v "$PWD/cache":/var/cache/nginx`），挂载会覆盖镜像内已 chown 的目录，宿主目录如果是 root:root 755，worker 就写不进去，表现为运行时 `open() "/var/cache/nginx/client_temp/..." failed (13: Permission denied)` 或 500。

典型日志（与 §2.10 的启动失败同源）：

```text
[emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

修复顺序：先在宿主把目录 chown 给容器 worker uid（镜像 101、Debian 包 33；以实际镜像 `id` 为准），或在启动脚本里以 root 建目录后 chown，再降权。

### 2.7 反向代理与 unix socket：502 的另一种来源

连接上游 unix socket 需要**对 socket 文件有写权限**（来源：`man 7 unix`：On Linux, connecting to a stream socket object requires write permission on that socket）。socket 文件在创建时按 umask 生成权限，所有者/组/模式可用 `chmod/chown` 改（同上 man 页）。

本机复现：宿主 Python 在 `sock/app.sock` 上提供 HTTP，nginx worker（uid 101）通过 `proxy_pass http://unix:/sock/app.sock:/` 访问；socket 先设 700（属主 1000），再改 666：

```bash
mkdir -p demo/sockproxy/sock demo/sockproxy/www
cat > demo/sockproxy/server.py <<'PY'
import os, socket
p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sock", "app.sock")
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p); s.listen(16); os.chmod(p, 0o700)
while True:
    c, _ = s.accept(); c.recv(4096)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nunix-ok\n")
    c.close()
PY
cat > demo/sockproxy/nginx.conf <<'EOF'
worker_processes 1;
error_log /dev/stderr info;
pid /tmp/nginx.pid;
events { worker_connections 64; }
http {
  access_log /dev/stdout;
  client_body_temp_path /tmp/client_temp;
  proxy_temp_path       /tmp/proxy_temp;
  fastcgi_temp_path     /tmp/fastcgi_temp;
  uwsgi_temp_path       /tmp/uwsgi_temp;
  scgi_temp_path        /tmp/scgi_temp;
  server { listen 8080; location / { proxy_pass http://unix:/sock/app.sock:/; } }
}
EOF
python3 demo/sockproxy/server.py & echo $! > demo/sockproxy/server.pid
sleep 0.5
ls -ln demo/sockproxy/sock/app.sock
docker run -d --rm --name learnugroup-08-unix -p 127.0.0.1:18082:8080 \
  -v "$PWD/demo/sockproxy/sock":/sock \
  -v "$PWD/demo/sockproxy/nginx.conf":/etc/nginx/nginx.conf:ro nginx:1.20-alpine
sleep 1
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:18082/
docker logs learnugroup-08-unix 2>&1 | grep -E 'connect\(\)|Permission denied' | tail -2
chmod 666 demo/sockproxy/sock/app.sock
curl -s -w '\nHTTP %{http_code}\n' http://127.0.0.1:18082/
docker rm -f learnugroup-08-unix
kill "$(cat demo/sockproxy/server.pid)"; rm -f demo/sockproxy/sock/app.sock
```

在本机执行上述命令的输出（socket 属主为宿主 1000；nginx 在容器内；请求由宿主 curl 发起）：

```text
srwx------ 1 1000 1000 0 10月18日 09:41 demo/sockproxy/sock/app.sock
HTTP 502
2026/10/18 01:41:58 [crit] 32#32: *1 connect() to unix:/sock/app.sock failed (13: Permission denied) while connecting to upstream, client: 172.17.0.1, server: , request: "GET / HTTP/1.1", upstream: "http://unix:/sock/app.sock:/", host: "127.0.0.1:18082"
srw-rw-rw- 1 1000 1000 0 10月18日 09:41 demo/sockproxy/sock/app.sock
unix-ok

HTTP 200
```

结论：`502` 不一定是 upstream 挂了；`connect() ... failed (13: Permission denied)` 说明 worker 对 socket 文件没有写权限。php-fpm 场景同理：

- php-fpm 的 pool 配置里 `listen.owner`/`listen.group`/`listen.mode` 决定 `www.sock` 的属主与模式（具体默认值取决于发行版的 pool 配置，本机未运行 php-fpm，未实测默认值）；
- nginx worker 需要能 traverse socket 所在目录（x）并对 socket 有 w；
- 常见做法是让 nginx worker 与 php-fpm 用户同组，把 socket 设为 `660` 且组匹配，或给 socket 所在目录合适的 ACL；
- 权限不对的日志形态是 `connect() ... failed (13: Permission denied)`；`504` 通常是超时，不是权限。

### 2.8 端口 <1024 与 CAP_NET_BIND_SERVICE

Linux 默认 `ip_unprivileged_port_start=1024`，非 root 绑定 <1024 端口返回 `EACCES`。master 以 root 启动时天然可以 bind 80；一旦以非 root 运行 nginx，就需要额外条件。

验证：宿主与容器内的 sysctl 不同。

```bash
cat /proc/sys/net/ipv4/ip_unprivileged_port_start
python3 -c 'import socket
s=socket.socket()
try: s.bind(("127.0.0.1",80)); print("host bind 80 OK")
except OSError as e: print("host bind 80 failed:", e.errno, e.strerror)'
docker run --rm --name learnugroup-08-port -u 101:101 nginx:1.20-alpine sh -c 'cat /proc/sys/net/ipv4/ip_unprivileged_port_start; nc -l -p 80 >/dev/null 2>&1 & sleep 1; netstat -ltn 2>/dev/null | grep -q ":80 " && echo "bind 80 OK as uid $(id -u)" || echo "bind 80 FAILED"'
```

在本机执行上述命令的输出（第一段宿主，第二段容器内）：

```text
1024
host bind 80 failed: 13 Permission denied
0
bind 80 OK as uid 101
```

容器的 `ip_unprivileged_port_start` 是 0（Docker 默认网络命名空间设置），所以容器内普通用户也能 bind 80；这是容器与宿主行为不同的一个典型点。**不能**把这条结论带回宿主机。

要让非 root nginx 在宿主绑 80，可选：

| 方案 | 做法 | 注意 |
|---|---|---|
| 文件 capability | `setcap cap_net_bind_service=+ep /usr/sbin/nginx` | 需要 `libcap2-bin`；升级包会替换二进制，文件 capability 随之丢失；脚本不行，必须是二进制 |
| systemd AmbientCapabilities | `AmbientCapabilities=CAP_NET_BIND_SERVICE` + `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` + `User=nginx` | 来源：`man 5 systemd.exec`；本机无 systemd 服务，未实测 |
| 端口转发/反代 | nginx 监听 8080，由 root 的负载均衡或容器映射 80 | 最常用，避免给 nginx 特权 |
| 调低 sysctl | `net.ipv4.ip_unprivileged_port_start=0` | 影响整机安全边界，不推荐 |

### 2.9 系统包 vs 官方容器镜像：路径与用户都不同

| 项 | Debian 包（`nginx`，容器内实测） | 官方镜像 `nginx:1.20-alpine` |
|---|---|---|
| 版本 | 1.26.3（随发行版） | 1.20.2 |
| worker 用户 | `www-data`(33) | `nginx`(101) |
| 主配置里的 user | `user www-data;` | `user nginx;` |
| 站点配置 | `/etc/nginx/sites-enabled/default` | `/etc/nginx/conf.d/default.conf` |
| docroot | `/var/www/html` | `/usr/share/nginx/html` |
| 日志 | `/var/log/nginx/` 真实文件，目录 `root:adm 750`，文件 `www-data:adm 640` | 符号链接到 `/dev/stdout`、`/dev/stderr` |
| 缓存 | `/var/lib/nginx`，启动后 `700 33:0` 子目录 | `/var/cache/nginx`，启动后 `700 101:0` 子目录 |
| pid | `/run/nginx.pid`，root:root 644 | `/var/run/nginx.pid`，root:root 644 |
| 默认入口 | 发行版 init/systemd 脚本 | `/docker-entrypoint.sh` + `nginx -g daemon off;` |

验证：上面两节的实际输出（包版本、目录、文件 mode/属主）与 `docker image inspect nginx:1.20-alpine --format 'User={{.Config.User}} Entrypoint={{.Config.Entrypoint}} Cmd={{.Config.Cmd}}'`：

在本机执行上述命令的输出：

```text
User= Entrypoint=[/docker-entrypoint.sh] Cmd=[nginx -g daemon off;]
```

`User=` 为空说明镜像默认 root 启动，worker 用户由配置里的 `user nginx;` 决定；这正是 master/worker 模型。

排障时的第一条命令因此是：**确认你用的是哪种部署**。容器镜像的日志在 stdout，系统包的日志在 `/var/log/nginx`；容器镜像的 docroot 是 `/usr/share/nginx/html`，系统包是 `/var/www/html`；uid 分别是 101 与 33。

### 2.10 以非 root 运行 nginx 的完整配方

目标：master 与 worker 都跑在 uid 101，不依赖 root。需要改三处：pid/日志/临时路径都在可写目录，监听端口 >1024，去掉或忽略 `user` 指令（master 非 root 时它本来也会被忽略）。

```bash
mkdir -p demo/ngx/conf demo/ngx/www
printf 'nonroot-nginx-ok\n' > demo/ngx/www/index.html
chmod -R a+rX demo/ngx/www
cat > demo/ngx/conf/nginx.conf <<'EOF'
worker_processes 1;
error_log /tmp/error.log warn;
pid /tmp/nginx.pid;
events { worker_connections 256; }
http {
  access_log /tmp/access.log;
  client_body_temp_path /tmp/client_temp;
  proxy_temp_path       /tmp/proxy_temp;
  fastcgi_temp_path     /tmp/fastcgi_temp;
  uwsgi_temp_path       /tmp/uwsgi_temp;
  scgi_temp_path        /tmp/scgi_temp;
  server { listen 8080; root /srv/www; location / { } }
}
EOF
docker run -d --rm --name learnugroup-08-nonroot -u 101:101 -p 127.0.0.1:18086:8080 \
  --entrypoint nginx \
  -v "$PWD/demo/ngx/conf/nginx.conf":/etc/nginx/nginx.conf:ro \
  -v "$PWD/demo/ngx/www":/srv/www:ro \
  nginx:1.20-alpine -c /etc/nginx/nginx.conf -g 'daemon off;'
sleep 1
curl -s -w '\nHTTP %{http_code}\n' http://127.0.0.1:18086/
docker top learnugroup-08-nonroot -eo pid,ppid,user,args | head -4
docker rm -f learnugroup-08-nonroot
```

在本机执行上述命令的输出（容器内进程，宿主 curl）：

```text
nonroot-nginx-ok

HTTP 200
PID                 PPID                USER                COMMAND
799134              799109              tss                 nginx: master process nginx -c /etc/nginx/nginx.conf -g daemon off;
799169              799134              tss                 nginx: worker process
```

（`tss` 是宿主对 uid 101 的名字，容器内是 `nginx`；master 与 worker 都是 101，没有 root 阶段。）

配方要点：

1. `--entrypoint nginx` 跳过 `/docker-entrypoint.sh`，避免入口脚本的默认初始化与自定义配置相互影响；
2. `pid`、`error_log`、`access_log`、五个 `*_temp_path` 全部指向 `/tmp`（或挂载的可写目录），否则会 `mkdir/open ... failed (13: Permission denied)`；
3. 监听 8080；若要监听 80，需要 §2.8 的 capability/端口转发条件；
4. 配置文件与 docroot 只要 worker 可读即可（`chmod -R a+rX` 或精确到 644/755）；
5. 非 root 时 `user` 指令被忽略并告警（§2.2），不要再写它。

生产环境更推荐「root master 绑定 80 + worker 降权 + systemd 加固」，而不是把 master 也降成非 root；非 root 配方适合无特权容器、用户态服务或调试。

### 2.11 配置项 → 权限影响

| 配置项 | 影响 | 排障提示 |
|---|---|---|
| `user <name>;` | worker 以该用户运行 | master 非 root 时被忽略并告警 |
| `worker_processes auto;` | 按 CPU 数创建 worker | 进程数不是权限问题，但影响日志/缓存并发 |
| `error_log <path> <level>;` | master 打开文件；worker 继承 fd | 目录不可写 → 启动失败；日志级别决定能否看到 `(13: Permission denied)` |
| `access_log <path>;` | 同上 | 路径不可写时启动失败或请求 500 |
| `pid <path>;` | master 写 pid | 非 root 配方必须换到可写目录 |
| `client_body_temp_path` | worker 写请求体临时文件 | 目录必须对 worker 可写；`/tmp` 下注意清理 |
| `proxy_temp_path`/`fastcgi_temp_path` | worker 写代理临时文件 | 同上 |
| `listen 80;` | master 绑定特权端口 | 非 root 需 CAP_NET_BIND_SERVICE 或端口转发 |
| `listen 8080;` | 非特权端口 | 非 root 配方的首选 |
| `listen unix:/path;` | master 创建 socket | 目录需 w+x；socket 权限可用 umask/后续 chmod 控制 |
| `root <dir>;` | worker 读 docroot | 每一级父目录都要 x；文件要 r |
| `index a b;` | 目录请求找 index | 都没有且 autoindex off → 403 |
| `autoindex on;` | 目录列表 | 安全上通常关闭；关闭时缺 index 是 403 |
| `proxy_pass http://unix:/path;` | worker 连接上游 socket | socket 文件需 w；目录需 x |
| `allow/deny`、`auth_basic` | 访问控制 | 403/401，别与文件权限混淆 |
| `disable_symlinks` | 符号链接安全 | 与目录 x 组合影响可访问性 |
| `daemon off;` | 前台运行 | 容器场景必须；与权限无关但影响启动方式 |

### 2.12 生产环境注意

1. **先确认部署形态**：容器镜像（日志 stdout、uid 101、conf.d）还是系统包（日志 `/var/log/nginx`、uid 33、sites-enabled）。
2. **日志轮转**：系统包用 logrotate，日志文件属主/模式要允许 master 重新打开；容器用 stdout，交给容器日志驱动。`USR1` 信号让 nginx 重新打开日志，不要直接 `rm` 正在写的日志。
3. **缓存目录放在本地可写路径**，不要挂一个 root:root 755 的宿主目录覆盖镜像里的 `/var/cache/nginx`。
4. **上传目录最小权限**：只给 worker w+x，不给 other；必要时用独立 uid + ACL。
5. **unix socket 明确属主/模式**：php-fpm 与 nginx 用同组 + 660，或 socket 目录 ACL；不要 777。
6. **不要用 root master 处理业务代码**：master 只做 bind/打开文件；worker 降权。需要 <1024 端口时优先端口转发。
7. **AppArmor/SELinux 要纳入排查**：本机 AppArmor 已启用（`/sys/module/apparmor/parameters/enabled` 输出 `Y`），但未构造 nginx 的 LSM 拒绝案例；遇到 403 且 error.log 无 `(13)` 时查 `dmesg`/`journalctl`。
8. **systemd 加固**（来源：`man 5 systemd.exec`）：`User=nginx`、`NoNewPrivileges=yes`、`CapabilityBoundingSet=CAP_NET_BIND_SERVICE`、`AmbientCapabilities=CAP_NET_BIND_SERVICE`、`ProtectSystem=strict`、`ProtectHome=yes`；本机无 systemd 服务，未实测。

---

## 三、动手验证

对应实验：[labs/06-nginx-perm](../labs/06-nginx-perm/)。该 lab 覆盖 master/worker、600 文件 403、错误日志、`chmod 644` 修复、目录 700 403、`user` 指令。

本机验证方式：宿主无 nginx，全部用 `nginx:1.20-alpine`；容器名统一 `learnugroup-08-*`，用 `--rm`，结束时 `docker rm -f`。宿主 curl 可用。以下命令只读写工作区内的 `demo/` 目录，清理时也只删除 `demo/`，执行前先 `pwd` 确认位置。

```bash
mkdir -p demo/html && printf 'INDEX-OK\n' > demo/html/index.html
```

1. 看进程模型：

```bash
docker run -d --rm --name learnugroup-08-v1 -p 127.0.0.1:18087:80 nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-v1 ps -o pid,ppid,user,args | head -4
docker top learnugroup-08-v1 -eo pid,ppid,user,args | head -3
docker rm -f learnugroup-08-v1
```

要看的是：master 是 root，worker 在容器内是 nginx、在宿主 `docker top` 里是 tss（§2.1）。

2. 看 worker uid 与 capability：

```bash
docker run -d --rm --name learnugroup-08-v2 -p 127.0.0.1:18088:80 nginx:1.20-alpine
sleep 1
docker exec learnugroup-08-v2 sh -c 'id nginx; for p in /proc/[0-9]*; do [ "$(cat $p/comm)" = nginx ] || continue; echo "$(basename $p) $(grep -E "^(Uid|CapEff)" $p/status | tr "\n" " ")"; done'
docker rm -f learnugroup-08-v2
```

要看的是：worker `Uid: 101`、`CapEff: 0000000000000000`；master `Uid: 0`、CapEff 非零。

3. 复现 403 并读错误日志：

```bash
printf 'secret\n' > demo/html/secret.html && chmod 600 demo/html/secret.html
docker run -d --rm --name learnugroup-08-v3 -p 127.0.0.1:18089:80 -v "$PWD/demo/html":/usr/share/nginx/html:ro nginx:1.20-alpine
sleep 1
curl -s -o /dev/null -w 'secret.html %{http_code}\n' http://127.0.0.1:18089/secret.html
docker logs learnugroup-08-v3 2>&1 | grep -E 'Permission denied' | tail -1
chmod 644 demo/html/secret.html
curl -s -o /dev/null -w 'after chmod %{http_code}\n' http://127.0.0.1:18089/secret.html
docker rm -f learnugroup-08-v3
```

要看的是：403 → error.log 的 `open() ... failed (13: Permission denied)` → chmod 644 后 200。

4. 看目录缺 x 与 index 缺失的差异：

```bash
mkdir -p demo/html/private demo/html/noindex
printf 'p\n' > demo/html/private/p.html && chmod 700 demo/html/private
docker run -d --rm --name learnugroup-08-v4 -p 127.0.0.1:18090:80 -v "$PWD/demo/html":/usr/share/nginx/html:ro nginx:1.20-alpine
sleep 1
for u in /private/p.html /noindex/; do printf '%-18s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18090$u"; done
docker logs learnugroup-08-v4 2>&1 | grep -E 'Permission denied|directory index' | tail -2
chmod 711 demo/html/private
curl -s -o /dev/null -w 'private after 711 %{http_code}\n' http://127.0.0.1:18090/private/p.html
docker rm -f learnugroup-08-v4
```

要看的是：目录 700 → 403 + `(13)`；缺 index 的目录 → 403 + `directory index ... forbidden`；711 后文件可读。

5. 看日志 fd 继承：

按 §2.4 的命令跑一遍，注意 `chmod 640 /logs/access.log` 后请求仍记录。

6. 看 unix socket 权限导致 502：

按 §2.7 的命令跑一遍，先 700 → 502 + `connect() ... (13)`，再 666 → 200。

7. 看非 root 启动失败与完整配方：

按 §2.2、§2.10 的命令跑一遍，对比 `mkdir() ... (13)` 与 200。

8. 看端口差异：

按 §2.8 的命令跑一遍，对比宿主 1024/EACCES 与容器 0/成功。

清理：

```bash
docker rm -f learnugroup-08-v1 learnugroup-08-v2 learnugroup-08-v3 learnugroup-08-v4 2>/dev/null || true
docker run --rm --name learnugroup-08-vclean -v "$PWD/demo":/w debian:13 sh -c 'rm -rf /w'
```

---

## 四、常见误解

❌ 「nginx 的 master 是 root，所以 worker 也是 root。」 → ✅ master 以 root 启动，worker 由 `user` 指令降权为 nginx(101)（验证：§2.1 容器内 `ps` 与 `/proc/<pid>/status`；worker `CapEff` 为 0）。

❌ 「worker 是 nginx 用户，所以它读不了 root:adm 750 的日志目录，日志肯定写不进去。」 → ✅ master 在降权前打开日志，worker 继承 fd；日志改成 `640 root:root` 后请求仍被记录（验证：§2.4）。

❌ 「`user` 指令一定生效，改了就会换用户。」 → ✅ master 本身不是 root 时该指令被忽略并打印 `[warn] ... ignored`（验证：§2.2）。

❌ 「403 就是文件权限，chmod 777 一定能解决。」 → ✅ 403 还包括父目录缺 x、缺 index、deny 规则或 LSM 这几种来源；777 既不能修缺 index，也破坏最小权限。先看 error.log 的 errno（验证：§2.5 四种 403/404 的日志不同）。

❌ 「目录 700，改成 755 才能被 worker 访问。」 → ✅ worker 只需要 x 就能 traverse，711 即可；是否需要 r 取决于是否列目录（验证：§2.5 改 711 后 200）。

❌ 「404 和 403 都是权限问题。」 → ✅ 404 是路径不存在（ENOENT），403 是存在但被拒绝（EACCES/index/规则/LSM）；错误日志 `(2)` 与 `(13)` 可区分（验证：§2.5）。

❌ 「502 一定是后端服务挂了。」 → ✅ 另一种情况是 worker 对上游 unix socket 没有写权限，日志是 `connect() ... failed (13: Permission denied)`（验证：§2.7）。

❌ 「非 root 也能直接绑 80，因为容器里试过可以。」 → ✅ 容器内 `ip_unprivileged_port_start=0` 才允许；本机宿主是 1024，非 root 绑 80 返回 EACCES（验证：§2.8）。不要把容器内的 sysctl 当成宿主事实。

❌ 「日志目录属主是 root，所以只能 root 读日志来排障。」 → ✅ 系统包的日志文件是 `www-data:adm 640`，`adm` 组可读；容器镜像日志走 stdout，`docker logs` 即可。排障不一定要 root，但读 `/proc/<worker>/fd` 受 `dumpable=0` 限制（验证：§2.4）。

❌ 「换到非 root 运行只要加 `user nginx` 就行。」 → ✅ 非 root master 会忽略 `user`，并且默认 pid/日志/缓存路径不可写，启动直接 `[emerg]`；必须改路径、端口和入口（验证：§2.2、§2.10）。

---

## 五、速查表

| 现象/需求 | 命令或配置 | 关键点 |
|---|---|---|
| 看 master/worker | `docker exec C ps -o pid,ppid,user,args` | master root、worker nginx |
| 看 worker uid | `docker exec C id nginx` | 官方镜像 101 |
| 看 worker capability | `grep CapEff /proc/<pid>/status` | 降权后为 0 |
| 看宿主如何显示 uid | `docker top C -eo pid,user,args` | 用宿主 passwd，本机 101 是 tss |
| 看 worker 数 | `grep worker_processes /etc/nginx/nginx.conf` | auto = CPU 数 |
| 看日志 fd 继承 | master `/proc/1/fd`；worker 写日志 | worker 不需要目录 w |
| 看缓存目录权限 | `ls -ldn /var/cache/nginx/*` | 101:0 700（镜像） |
| 看系统包日志权限 | `ls -ldn /var/log/nginx; ls -ln /var/log/nginx` | root:adm 750，文件 www-data:adm 640 |
| 403 且 errno 13 | 查 error.log `open() ... Permission denied` | 文件 r 或父目录 x |
| 403 且缺 index | `directory index ... is forbidden` | 配 index 或关目录请求 |
| 404 | `open() ... failed (2: No such file or directory)` | root/alias/try_files 路径 |
| 看路径每一级权限 | `namei -l /path/to/file` | 定位缺 x 的目录 |
| 修文件不可读 | `chmod 644 file` 或 chown 给 worker | 改文件侧或属主侧 |
| 修目录不可进入 | `chmod 711 dir` | traverse 只需 x |
| 启动失败 mkdir 13 | 查 `*_temp_path` 是否可写 | 非 root 配方改 /tmp |
| 上传失败 | 查 `client_body_temp_path` | worker 需要 w |
| 上游 unix socket 502 | `connect() ... (13: Permission denied)` | socket 文件需 w |
| 看 socket 权限 | `ls -ln /path/app.sock` | 创建时按 umask |
| 宿主非 root 绑 80 | `cat /proc/sys/net/ipv4/ip_unprivileged_port_start` | 1024 → EACCES |
| 容器内绑 80 | 容器内同文件 | 0 → 允许 |
| 给 nginx 绑端口能力 | `setcap cap_net_bind_service=+ep /usr/sbin/nginx` | 需 libcap2-bin；升级会丢 |
| systemd 授权 | `AmbientCapabilities=CAP_NET_BIND_SERVICE` | 配合 `User=`/`CapabilityBoundingSet=` |
| 非 root 配方 | pid/log/temp 改 /tmp，listen 8080 | 去掉 `user` 指令 |
| 确认部署形态 | 查 `sites-enabled` 或 `conf.d` | 包 vs 镜像路径不同 |

---

## 六、延伸阅读

- 本章实验：[labs/06-nginx-perm](../labs/06-nginx-perm/)（master/worker、403、日志、chmod 修复）。
- 上一章：[07-Docker用户与权限实战](07-Docker用户与权限实战.md)（容器默认 root、卷属主、socket）。
- 排障方法：[09-权限排障手册](09-权限排障手册.md)（EACCES/EPERM、403/404/502 速查）。
- 原理章节：[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[05-提权与降权机制](05-提权与降权机制.md)（setuid/降权顺序）、[06-命名空间与uid映射](06-命名空间与uid映射.md)（容器内的 uid 含义）。
- 相邻主题：[03-文件权限与ACL](03-文件权限与ACL.md)（目录 x、ACL 授权）。
- man 页：`man 7 capabilities`、`man 7 unix`、`man 5 systemd.exec`、`man 7 path_resolution`。
