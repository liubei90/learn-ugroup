# labs/06 · Nginx 权限实战动手实验

> **一句话总结**：用 `nginx:1.20-alpine` 复现「403 + error.log Permission denied」并把它修成 200。

> **本机验证**：✅ 需要 docker、本地 `nginx:1.20-alpine` 镜像、`curl` 与一个空闲端口（默认 18080）。

| 项目 | 内容 |
|---|---|
| 演示现象 | master=root / worker=nginx(101)；`user nginx;`；600 文件 403；error.log `(13: Permission denied)`；`chmod 644` 修复；目录 700 也 403 |
| 运行环境 | 宿主 + `docker run --rm -p 127.0.0.1:18080:80 -v <lab>/.tmp/html:/usr/share/nginx/html:ro nginx:1.20-alpine` |
| 预计耗时 | 约 8 秒 |
| 对应章节 | [docs/08-Nginx用户与权限实战](../../docs/08-Nginx用户与权限实战.md)、[docs/09-权限排障手册](../../docs/09-权限排障手册.md)、[docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md) |

## 一、这个 lab 演示什么

把「nginx 返回 403，错误日志只写 Permission denied」的完整链路跑一遍：

1. 官方镜像的进程模型：master 以 **root** 运行，worker 以 **nginx(101)** 运行；
2. 配置第 2 行 `user  nginx;` 决定 worker 的降权目标；
3. 宿主文件 `600`、属主 1000 → worker(101) 打不开 → HTTP **403**，`error.log` 记录
   `open() ... failed (13: Permission denied)`；
4. 宿主 `chmod 644` → 同一个 URL 变成 **200**；
5. 目录 `700` 时，里面 644 的 `index.html` 也 403——因为 worker 连目录都进不去；`chmod 755` 恢复 200。

> 锚点：nginx 的权限问题 90% 可以落到三个问题——**worker 是谁（uid）**、**它要读的文件是什么 mode/属主**、
> **路径上每一级目录有没有 x 位**。本 lab 的三次 403/200 切换就是这三个问题。

## 二、前置条件

- `docker` daemon 可用，本地已有 `nginx:1.20-alpine` 镜像（本机已预置）。
- 需要 `curl` 断言 HTTP 状态码；默认端口 `18080`，可用 `LEARNUGROUP_PORT=18081` 覆盖。
- 不需要 root、不需要网络。容器 `-p 127.0.0.1:$PORT:80`，只挂载本 lab 的 `.tmp/html`（`:ro`）。
- 安全边界：不使用 `--privileged`、不挂载 `/var/run/docker.sock`、不挂宿主根目录。

## 三、运行方式

```bash
cd labs/06-nginx-perm
bash run.sh
# 端口冲突时：
LEARNUGROUP_PORT=18081 bash run.sh
```

- 无交互、可重复；退出码 `0` 表示全部断言通过，`1` 表示有 `FAIL`。
- docker / 镜像 / curl 缺失或端口被占用时打印 `SKIP` 并退出 0。
- 每行以 `ok` / `FAIL` 开头，末行固定为 `PASS n / FAIL m`。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. 依赖检查 ==
ok   docker、nginx:1.20-alpine、curl 均可用，端口 18080 空闲

== 2. 准备站点文件（属主 1000） ==
/home/demo/code/learn-ugroup/labs/06-nginx-perm/.tmp/html:
total 12
-rw-r--r-- 1 1000 1000   18 Oct 18 09:46 index.html
-rw------- 1 1000 1000   19 Oct 18 09:46 secret.html
drwxrwxr-x 2 1000 1000 4096 Oct 18 09:46 subdir

/home/demo/code/learn-ugroup/labs/06-nginx-perm/.tmp/html/subdir:
total 4
-rw-r--r-- 1 1000 1000 19 Oct 18 09:46 index.html

== 3. 启动 nginx 容器（只挂载本 lab 的 html 目录，只读） ==
ok   nginx 已就绪，GET / 返回 200

== 4. 进程模型：master=root，worker=nginx(101) ==
id nginx: uid=101(nginx) gid=101(nginx) groups=101(nginx),101(nginx)
ok   worker 用户 nginx 的 uid=101
PID   USER     COMMAND
    1 root     nginx: master process nginx -g daemon off;
   32 nginx    nginx: worker process
   33 nginx    nginx: worker process
   34 nginx    nginx: worker process
   35 nginx    nginx: worker process
ok   master process 以 root 运行
ok   worker process 以 nginx 运行
worker 进程数: 22
nginx.conf: 2:user  nginx;
ok   配置里 user 指令把 worker 指定为 nginx

== 5. 600 文件导致 403，error.log 记录 Permission denied ==
GET /secret.html -> 403
ok   模式 600 的 secret.html 返回 403
--- nginx error.log（截取含 Permission denied 的行）---
2026/10/18 01:46:26 [error] 32#32: *2 open() "/usr/share/nginx/html/secret.html" failed (13: Permission denied), client: 172.17.0.1, server: localhost, request: "GET /secret.html HTTP/1.1", host: "127.0.0.1:18080"
ok   error.log 含 secret.html 的 (13: Permission denied)

== 6. chmod 644 修复：403 -> 200 ==
GET /secret.html -> 200 body=<h1>secret-ok</h1>
ok   chmod 644 后 secret.html 返回 200 且内容正确

== 7. 目录缺 x 位（700）导致 403；chmod 755 修复 ==
GET /subdir/index.html（目录 700）-> 403
ok   父目录 700 时 644 的 index.html 也返回 403
GET /subdir/index.html（目录 755）-> 200 body=<h1>subdir-ok</h1>
ok   目录补回 x 位后返回 200

PASS 11 / FAIL 0
```

## 五、分步讲解

### 1. 进程模型：为什么 master 是 root，worker 是 nginx

```text
PID   USER     COMMAND
    1 root     nginx: master process nginx -g daemon off;
   32 nginx    nginx: worker process
...
id nginx: uid=101(nginx) gid=101(nginx) groups=101(nginx),101(nginx)
nginx.conf: 2:user  nginx;
```

- master 以 root 启动，负责需要特权的动作（本实验里是 bind 80）；
- 配置文件第 2 行 `user  nginx;` 指定 worker 以 `nginx` 运行；实际 uid 是 `101`；
- worker 进程数由 `worker_processes` 决定，本机容器内出现 22 个 worker——与权限无关，但看日志时要记住
  **处理请求的是 worker，不是 master**。

所以：`ps` 里看到 nginx 是 root 还是不 root，要先分清 master/worker；判断「读不到文件」要看 **worker 的 uid**。

### 2. 403 的根因：worker(101) 与文件属主(1000) 不匹配

站点文件由宿主创建：`secret.html` 属主 1000、mode `600`。worker 以 uid 101 打开时：

- 属主匹配？否（101 ≠ 1000）；
- 属组匹配？否；
- other 权限？`600` 的 other 是 `---`。

结果 `open()` 返回 `EACCES`，nginx 对静态文件权限失败统一回 **403**，并写 error.log：

```text
[error] 32#32: *2 open() "/usr/share/nginx/html/secret.html" failed (13: Permission denied)
```

`13` 是 `EACCES` 的 errno。**看到这条日志，任务就已经完成了 80%：是 worker 的 uid 打不开某个路径。**

### 3. 修复一：`chmod 644`

把 `secret.html` 改成 `644` 后立刻 200：

```text
GET /secret.html -> 200 body=<h1>secret-ok</h1>
```

为什么是 644 而不是 777：worker 只需要**读**静态文件，`644` 的 other `r` 已足够；`777` 会额外给出写权限，
对站点文件没有意义且扩大风险。

### 4. 修复二：目录 x 位

把包含 `index.html` 的 `subdir` 改成 `700`，即使 `index.html` 是 644，请求仍是 403——
worker 没有目录的 `x`，无法把路径解析到文件。`chmod 755 subdir` 后恢复 200。
用 `namei -l /path/to/file` 可以把每一级的 mode 都列出来，是定位这类问题的标准工具（见 docs/09）。

### 5. 同一现象的其它修法（对应 docs/08/docs/09）

| 修法 | 命令 | 适用 |
|---|---|---|
| 放宽读权限 | `chmod 644 file` | 静态资源，最简单 |
| 改属主/属组 | `chown -R 101:101 html/` 或 `chgrp nginx` + `640` | 需要对 worker 精细授权 |
| ACL | `setfacl -m u:101:r file` | 不想改属主（见 [labs/02](../02-acl/)） |
| 换 worker uid | 自定义镜像 `USER` / 配置 `user` | 与镜像内用户表一致时 |
| 改目录布局 | 把可写目录（缓存/上传）单独授权 | 写操作场景 |

本 lab 故意只用 `chmod`，因为它能在宿主侧完成、最容易复现；真实环境要结合 owner/group 策略。

## 六、清理

脚本 `trap` 执行 `docker rm -f learnugroup-06-nginx-perm-$$` 并删除 `.tmp/`；容器 `--rm`，不残留。
手动清理：

```bash
docker rm -f learnugroup-06-nginx-perm-$$ 2>/dev/null || true
rm -rf labs/06-nginx-perm/.tmp
```

## 七、对应章节

- [docs/08-Nginx用户与权限实战](../../docs/08-Nginx用户与权限实战.md)：进程模型、权限矩阵、403 排查树、日志/缓存目录。
- [docs/09-权限排障手册](../../docs/09-权限排障手册.md)：`EACCES` 与 `EPERM`、`namei -l`、5 分钟诊断流程。
- [docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md)：容器 uid 与宿主文件属主。
- 相邻实验：[labs/02-acl](../02-acl/)（ACL 修法）、[labs/07-drills](../07-drills/)（同类故障演练）。

## 八、延伸练习

1. **三种修法对比**：对同一个 600 文件分别用 `chmod 644`、`chown 101:101`、`setfacl -m u:101:r`，
   各跑一次 `curl`，比较对宿主权限面的影响。
2. **目录 x 位排查**：用 `namei -l` 检查 `.tmp/html/subdir/index.html` 每一级 mode，再构造「中间目录 701」
   的变体，解释为什么 `x` 有、`r` 无也能访问已知文件名。
3. **日志写入位置**：把 nginx 的 `error_log` 指到一个 700 的目录，观察 master/worker 谁报错、
   错误发生在启动还是请求阶段，并与本 lab 的 `tail error.log` 对照。
