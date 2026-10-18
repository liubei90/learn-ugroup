# 07 Docker 用户与权限实战

> **一句话总结**：用一套 uid 模型解释容器 root、docker 组与卷属主，并给出可复制的修法。

> **本机验证**：✅ 全部可验证（Docker 29.8 rootful；正文容器输出均标注「容器内」；rootless 部分只给核对清单，标注未验证）。

| 项目 | 内容 |
|---|---|
| 回答的问题 | 为什么普通用户执行 `docker` 就能在容器里当 root？为什么容器写宿主目录会 `Permission denied`？`chown`、`-u`、命名卷、rootless 到底该选哪个？ |
| 适合读者 | 在开发机、CI 或生产服务器上用 Docker 部署服务，被「卷属主不对」「docker 组权限」困扰的工程师 |
| 前置阅读 | [01-权限模型全景](01-权限模型全景.md)、[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[06-命名空间与uid映射](06-命名空间与uid映射.md) |
| 主要来源 | `man 1 docker-run`、`man 8 dockerd`、`man 5 Dockerfile`、`man 7 unix`、本机 Docker 29.8 实测 |

---

## 一、先建立直觉

### 1.1 先分清三个「用户」

同一个 `docker run` 背后有三套身份，混在一起就会得出错误结论：

| 身份 | 在本机是谁 | 决定什么 |
|---|---|---|
| 执行 `docker` 命令的用户 | `demo`，`uid=1000` | 能否打开 `/var/run/docker.sock` |
| `dockerd` 守护进程 | `root`（rootful 模式） | 能否创建命名空间、挂载目录、改文件属主 |
| 容器里的进程 | 默认 `uid=0`，可被 `-u` 覆盖 | 写文件时内核检查的是它的 fsuid/fsgid 与 capability |

所以「普通用户执行 docker 却能在容器里用 root」不是提权漏洞，而是两件事叠加：

1. 普通用户在 `docker` 组里，能调用以 root 运行的 `dockerd` 的 API；
2. 容器进程默认以 `uid=0` 运行（`man 1 docker-run` 的 `-u, --user` 条目原文：Without this argument the command will be run as root in the container）。

验证：本机 `getent group docker` 的输出 → `docker:x:989:demo`；`docker run --rm --name learnugroup-07-id alpine:latest id` 的输出见 §2.2。

### 1.2 一条调用链：客户端 → socket → dockerd → runc → 容器进程

```text
   demo (uid=1000)                     root (uid=0)
   ┌──────────────┐   /var/run/docker.sock   ┌──────────────┐
   │ docker CLI   │ ───────────────────────▶ │ dockerd      │
   │ 只是 HTTP    │   660 root:docker        │ 解析挂载、   │
   │ 客户端       │   （组内用户可读写）     │ 创建命名空间 │
   └──────────────┘                          └──────┬───────┘
                                                    │ containerd / runc
                                                    ▼
                                     ┌──────────────────────────────┐
                                     │ 容器进程（默认 uid=0）        │
                                     │ 写绑定挂载时，内核按它的      │
                                     │ fsuid/fsgid 检查宿主 inode    │
                                     └──────────────────────────────┘
```

> 图：Docker 的用户与权限链路。**「谁能连 socket」和「容器里是谁」是两个独立问题**，卷属主问题出在右边这一半。

### 1.3 关键区分：docker 组的权限 vs 容器内的 uid

- `docker` 组控制**能不能调用 Docker API**。能调用 API 的进程可以让 root 的 daemon 做几乎任何事，所以它等价于宿主 root（§2.1）。
- 容器内的 uid 控制**写文件时内核怎么检查 inode**。默认 rootful 模式下没有 user namespace 重映射，容器里的 `uid=0` 就是宿主 inode 上的 `0`（§2.3）。

把这两件事混为一谈，就会在「已经是 docker 组了，为什么还写不进去」和「容器里是 root，为什么宿主文件属主是 1000」之间反复打转。

### 1.4 本章在全局模型中的位置

[01-权限模型全景](01-权限模型全景.md) 给出的三要素是「进程凭证 × 资源权限 × 检查规则」。本章把这三要素落到 Docker 上：

- 进程凭证 = 容器进程的 uid/gid/capability（默认 root，可用 `-u`/`USER` 改）；
- 资源权限 = 宿主目录的属主与 mode（绑定挂载）或 Docker 管理的卷目录（命名卷）；
- 检查规则 = 内核的 DAC 检查，`docker` 组本身不参与文件检查，只参与 socket 的 `connect()`。

---

## 二、机制与配置：从 socket 到卷属主

### 2.1 docker.sock 为什么等于 root

`dockerd` 以 root 运行，Docker API 能做的事包括：挂载宿主任意目录、设置容器 capability、创建网络、读取镜像。因此**任何能读写 `/var/run/docker.sock` 的进程，都能让 daemon 替它执行接近 root 的操作**。Docker 守护进程默认监听这个 Unix socket，其访问控制就是文件系统的 mode + 属组。

验证：本机 socket 的权限与属组。

```bash
ls -ln /var/run/docker.sock
stat -c '%a %U:%G' /var/run/docker.sock
getent group docker
```

在本机执行上述命令的输出：

```text
srw-rw---- 1 65534 65534 0 10月11日 09:24 /var/run/docker.sock
660 nobody:nogroup
docker:x:989:demo
```

说明两点：

1. 模式是 `660`，只有属主与属组可读写。本会话运行在受限的用户命名空间里，`root:docker` 被显示成 `nobody:nogroup`（`65534`）；普通宿主上这一行是 `root docker`，模式位不变。
2. `getent group docker` 显示 `demo` 在 `docker` 组（gid 989）。本会话的 `id` 输出会把辅助组显示成 `65534`，那是 uid/gid 映射不完整的显示问题；`docker` 命令能连上 socket 这一事实（下面 curl 调用成功）说明内核判定时用的是真实 gid 989。

验证：客户端确实通过 socket 调 API，而不是「本地 root 特权」。

```bash
curl -s --unix-socket /var/run/docker.sock http://localhost/version | jq -r '.Version, .ApiVersion'
```

在本机执行上述命令的输出：

```text
29.8.1
1.56
```

**为什么加入 docker 组等于 root。** 组成员可以 POST 一个「挂载宿主任意目录、带 `CAP_SYS_ADMIN` 或 `--privileged`」的容器；`man 1 docker-run` 对 `--privileged` 的描述是：give extended privileges、access to all devices、nearly all the same access to the host as processes running outside of a container。容器里再借助这些权限改宿主文件，等价链路就闭合了。本课程不执行这条链路，只用于解释风险。

安全替代方案对比：

| 方案 | 做法 | 优点 | 代价 |
|---|---|---|---|
| rootless Docker | 以普通用户运行 dockerd，容器 uid 映射到 subuid | 真正去掉「组=root」 | 需要 subuid/newuidmap、cgroup v2；端口 <1024 受限（§2.7） |
| Podman | 无守护进程，默认 rootless | 无需常驻 root daemon | 与 Docker API/Compose 生态有差异 |
| sudo 白名单 | 只允许 `sudo docker` 执行固定子命令 | 改动小、可审计 | 仍是 root 等价，只是收窄入口 |
| 远程 Docker API + TLS | 客户端不接触本地 socket | 可做认证/审计 | 配置复杂，证书与网络要保护 |

本机验证方式：`docker info --format '{{json .SecurityOptions}}'` 的输出为 `["name=apparmor,profile=default","name=seccomp,profile=builtin","name=cgroupns"]`，没有 userns-remap 项，说明本机是 rootful 默认模式。

### 2.2 容器内默认用户：root、USER 与 -u

镜像的 `USER` 指令决定默认运行用户；没有该指令时是 root。运行时的 `-u/--user` 覆盖镜像的 `USER`。`/etc/passwd` 只用于把名字解析成数字，**镜像里没有该用户，照样可以用数字 uid 运行**。

验证：容器内默认身份。

```bash
docker run --rm --name learnugroup-07-root alpine:latest id
```

输出（容器内）：

```text
uid=0(root) gid=0(root) groups=0(root),0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
```

验证：`-u` 指定数字 uid，以及镜像里没有该用户时仍可运行。

```bash
docker run --rm --name learnugroup-07-u1000 -u 1000:1000 alpine:latest id
docker run --rm --name learnugroup-07-u1234 -u 1234:1234 alpine:latest sh -c 'id; grep -E "^[^:]*:[^:]*:1234:" /etc/passwd || echo "no passwd entry for 1234"'
docker run --rm --name learnugroup-07-nobody --user nobody alpine:latest id
```

在本机执行上述命令的输出（容器内）：

```text
uid=1000 gid=1000 groups=1000
uid=1234 gid=1234 groups=1234
no passwd entry for 1234
uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)
```

结论：`-u 1234` 不需要镜像里有 uid 1234 的账户；`--user nobody` 里的 `nobody` 能在 alpine 的 `/etc/passwd` 中解析成 65534。`-u` 的合法写法由 `man 1 docker-run` 给出：`user | user:group | uid | uid:gid | user:gid | uid:group`。

`--group-add` 增加的是辅助组（`man 1 docker-run`：Add additional groups to run as），常用于「主用户不变，但需要访问某个组可写目录」的场景，compose 里对应 `group_add:`（§2.6 有实测）。

### 2.3 uid 映射：默认容器 uid == 宿主 uid

在默认 rootful 模式（未启用 userns-remap）下，容器的 user namespace 没有做 uid 映射，容器内 `uid=N` 写宿主绑定目录时，宿主 inode 的属主就是 `N`。

验证：容器内 root 与 uid 1000 各创建一个文件，分别在容器内和宿主查看。

```bash
mkdir -p demo/mnt && chmod 755 demo/mnt
docker run --rm --name learnugroup-07-b1 -v "$PWD/demo/mnt":/w alpine:latest sh -c 'touch /w/root-created.txt; ls -ln /w/root-created.txt'
ls -ln demo/mnt/root-created.txt
docker run --rm --name learnugroup-07-b3 -u 1000:1000 -v "$PWD/demo/mnt":/w alpine:latest sh -c 'touch /w/u1000.txt; ls -ln /w/u1000.txt'
ls -ln demo/mnt/u1000.txt
```

在本机执行上述命令的输出（前两行容器内，后两行宿主）：

```text
-rw-r--r--    1 0        0                0 Oct 18 01:39 /w/root-created.txt
-rw-r--r-- 1 65534 65534 0 10月18日 09:39 demo/mnt/root-created.txt
-rw-r--r--    1 1000     1000             0 Oct 18 01:39 /w/u1000.txt
-rw-r--r-- 1 1000 1000 0 10月18日 09:39 demo/mnt/u1000.txt
```

解读：

| 容器内 uid | 宿主 inode 的 uid（默认 rootful） | 说明 |
|---|---|---|
| `0` | `0`（root） | 容器 root 就是宿主 root；本会话 userns 显示为 65534 |
| `1000` | `1000`（demo） | 与宿主用户相同，写自己的目录无障碍 |
| `101` | `101` | 本机宿主 101 是 `tss`；uid 是数字，名字只影响显示 |

验证：本机无 userns-remap，`docker info` 的 SecurityOptions 里没有 userns 项（§2.1 已给输出）。

如果启用了 daemon 级 `userns-remap`，容器内的 uid 会被映射到 `/etc/subuid` 里的区间（例如 `100000` 起），容器 root 不再是宿主 root。`man 8 dockerd` 的 `--userns-remap=default|uid:gid|user:group|user|uid` 条目说明了这一点：指定用户时，daemon 会查找该用户的 subordinate ID 范围作为映射。rootless Docker 用同一套 subuid 机制，只是 daemon 本身也以普通用户运行（§2.7）。

**宿主视角的 65534 是怎么来的。** 本会话自身在嵌套 user namespace 里，只映射了 uid 1000；宿主真实 uid 0、101 都不在映射表内，内核统一显示为溢出 UID 65534（`nobody`）。这不是文件的真实属主，换成正常登录的宿主终端会显示 `root`/`tss`。判断真实属主请用容器内 `ls -ln` 或 `stat` 的数字。

### 2.4 卷属主问题（本章核心）

#### 现象

容器以非 root 用户运行时，写绑定挂载的宿主目录失败：

```bash
mkdir -p demo/data && chmod 750 demo/data
docker run --rm --name learnugroup-07-b4 -u 101:101 -v "$PWD/demo/data":/data alpine:latest sh -c 'id; touch /data/x'
```

在本机执行上述命令的输出（容器内）：

```text
uid=101 gid=101 groups=101
touch: /data/x: Permission denied
```

#### 根因

绑定挂载**不做 uid 翻译**。内核看到的是宿主目录的 inode：`demo/data` 属主 1000、模式 750，容器进程 fsuid=101、fsgid=101，既不是属主也不在属组，other 位是 `---`，于是 `open(O_CREAT)` 返回 `EACCES`。容器内是不是 root、镜像里有没有 101 账户，都不影响这个判断。

验证：宿主侧目录元数据。

```bash
ls -ldn demo/data
stat -c '%a %u:%g %n' demo/data
```

在本机执行上述命令的输出：

```text
drwxr-x--- 2 1000 1000 4096 10月18日 09:39 demo/data
750 1000:1000 demo/data
```

#### 修复的最小闭环：把宿主目录给容器 uid

```bash
docker run --rm --name learnugroup-07-b5 -v "$PWD/demo/data":/data alpine:latest chown 101:101 /data
docker run --rm --name learnugroup-07-b6 -u 101:101 -v "$PWD/demo/data":/data alpine:latest sh -c 'touch /data/x && ls -ln /data'
```

在本机执行上述命令的输出（第二条为容器内）：

```text
total 0
-rw-r--r--    1 101      101              0 Oct 18 01:39 x
```

容器 root 有 `CAP_CHOWN`/`CAP_DAC_OVERRIDE`，所以能改宿主 inode 的属主；这就是「用容器 chown 修宿主机目录」的原理。注意 `chown` 改变的是宿主真实属主，换来的是「该目录对 uid 101 可写」，也会影响宿主上原本使用该目录的用户。

#### 绑定挂载 vs 命名卷

| 维度 | 绑定挂载 `-v /host/path:/data` | 命名卷 `-v volname:/data` |
|---|---|---|
| inode 位置 | 宿主指定路径，属主/权限由用户维护 | `/var/lib/docker/volumes/...`，Docker 管理 |
| 初始属主 | 取决于宿主目录 | 卷根目录默认 `root:root 755`（验证：§2.4 命名卷实测） |
| 首次使用 | 直接暴露宿主内容 | 空卷会从镜像对应路径复制内容（copy-up） |
| uid 问题 | 需要 chown 或 `-u` | 同样需要，卷根目录是 root:root |
| 跨容器共享 | 天然共享 | 天然共享，更适合数据 |
| 迁移/备份 | 直接复制目录 | 需要 `docker run --rm -v vol:/data ... tar` 或 `docker volume` 工具 |

> 命名卷不是「自动解决属主」的银弹：Docker 首次创建卷目录时属主是 root，只有镜像里那个路径本身带有非 root 属主时，copy-up 才会把属主带过来。

验证：命名卷根目录属主与 copy-up 行为。

```bash
docker volume rm -f learnugroup-07-copyvol
docker run --rm --name learnugroup-07-f1 -v learnugroup-07-copyvol:/usr/share/nginx/html nginx:1.20-alpine sh -c 'ls -ln /usr/share/nginx/html; head -1 /usr/share/nginx/html/index.html'
docker run --rm --name learnugroup-07-f1b -v learnugroup-07-copyvol:/usr/share/nginx/html alpine:latest sh -c 'ls -ln /usr/share/nginx/html'
```

在本机执行上述命令的输出（容器内）：

```text
total 8
-rw-r--r--    1 0        0              494 Nov 16  2021 50x.html
-rw-r--r--    1 0        0              612 Nov 16  2021 index.html
<!DOCTYPE html>
total 8
-rw-r--r--    1 0        0              494 Nov 16  2021 50x.html
-rw-r--r--    1 0        0              612 Nov 16  2021 index.html
```

卷目录是空的，第一次挂载时 Docker 把镜像 `/usr/share/nginx/html` 的内容复制进卷，属主保持镜像里的 `0:0`。因此「用命名卷 + 非 root 用户」仍会遇到同样的 EACCES，除非镜像里该路径本身属于目标 uid，或在启动时 chown。

验证：命名卷根目录默认属主与 `-u 101` 失败。

```bash
docker volume rm -f learnugroup-07-vol
docker volume create learnugroup-07-vol
docker run --rm --name learnugroup-07-b8 -v learnugroup-07-vol:/data alpine:latest sh -c 'ls -ldn /data; touch /data/root.txt'
docker run --rm --name learnugroup-07-b9 -u 101:101 -v learnugroup-07-vol:/data alpine:latest sh -c 'touch /data/u101.txt'
docker run --rm --name learnugroup-07-b10 -v learnugroup-07-vol:/data alpine:latest chown 101:101 /data
docker run --rm --name learnugroup-07-b11 -u 101:101 -v learnugroup-07-vol:/data alpine:latest sh -c 'touch /data/u101.txt && ls -ln /data'
```

在本机执行上述命令的输出（容器内）：

```text
drwxr-xr-x    2 0        0             4096 Oct 18 01:39 /data
touch: /data/u101.txt: Permission denied
total 0
-rw-r--r--    1 0        0                0 Oct 18 01:39 root.txt
-rw-r--r--    1 101      101              0 Oct 18 01:40 u101.txt
```

#### 五种以上解法的对比

| # | 解法 | 做法 | 优点 | 缺点/限制 | 本机验证 |
|---|---|---|---|---|---|
| 1 | 宿主目录 chown 给容器 uid | `chown -R 101:101 dir`（或容器内 chown） | 简单、一次到位 | 需要 root；多个消费者 uid 不同时冲突；NFS 上 chown 受服务端导出与 root_squash 配置限制 | ✅ 容器内 chown 后 101 可写（上） |
| 2 | 容器以宿主 uid 运行 | `-u $(id -u):$(id -g)` | 不用改宿主属主；文件属主就是自己 | 镜像内不一定有该 uid 的 home 或所需权限；需要镜像配合 | ✅ uid 1000 写宿主目录成功（§2.3） |
| 3 | compose `user:` + `group_add:` | 在 compose 服务里固定 uid/gid，必要时附加组 | 配置化、可复现 | 仍要保证目录对 uid/组可写 | ✅ `groups=989,1000` 且写成功（§2.6） |
| 4 | 命名卷 | 用命名卷代替绑定挂载，首次 chown 一次 | 可移植、Docker 管理 | 卷根仍是 root:root；备份/迁移要专门工具 | ✅ 卷属主 root，chown 后成功（上） |
| 5 | userns-remap | daemon.json 开启 `userns-remap`，容器 uid 映射到 subuid | 容器 root 不再是宿主 root，纵深防御 | 需重启 daemon；已有容器/卷的属主会变化；排障更复杂 | ⚠️ 本机未启用（需改 daemon） |
| 6 | rootless Docker | 普通用户运行 daemon，uid 映射到 subuid | 不用 root daemon，组不再等价 root | 需要 subuid/newuidmap、cgroup v2；端口 <1024 受限 | ⚠️ 本机缺 `newuidmap`，未验证 |

> 递归 `chown -R` 会改变目录下所有条目的属主；执行前用 `find DIR -maxdepth 2 -ls` 确认范围，并且只对本课程工作区内的目录执行。

补充两种常见工程做法（不单列为解法，因为本质是 1 或 3 的自动化）：

- **启动脚本 chown**：容器入口以 root 启动，`chown` 数据目录后 `exec gosu/su-exec` 降到目标用户。适合数据库镜像，代价是容器启动时仍有 root 阶段。
- **init 容器/Job 预置权限**：部署前用一次性容器（`docker run --rm -v ... chown`）把目录修好，主容器直接以非 root 启动。

#### 清理 root 属主产物

容器 root 在宿主创建的文件，属主是 0；本会话显示为 65534。宿主普通用户对这个文件能做什么由 mode 决定：644 时 other 可读但不可写，600/640 时连读也会被拒；改属主（`chown`）则需要 root 或 `CAP_CHOWN`。**能否删除只取决于父目录的 w+x 和 sticky 位**，与文件属主无关——见 §四第 5 条与 [03-文件权限与ACL](03-文件权限与ACL.md)。清理这类产物最稳妥的办法仍是让容器来删：

```bash
docker run --rm --name learnugroup-07-clean -v "$PWD/demo":/w debian:13 sh -c 'rm -rf /w/mnt /w/data /w/root-created.txt'
```

验证：本机在可写父目录里，普通用户可以 unlink 容器 root 创建的文件；父目录不可写时才会失败（`demo/data` 被 chown 成 101 后，`ls -ldn` 显示 750、属主 101，宿主 1000 既非属主也不在属组）。

### 2.5 Dockerfile 实践：USER、COPY --chown、多阶段

最低要求是：**不要以 root 作为最终运行用户**，并且把文件属主在构建时就设好，避免运行时 chown。

```bash
mkdir -p demo/img && cd demo/img
printf 'hello-from-build\n' > app.txt
cat > Dockerfile <<'EOF'
FROM alpine:latest
RUN addgroup -g 1001 app && adduser -D -u 1001 -G app app
COPY app.txt /app/root-owned.txt
COPY --chown=1001:1001 app.txt /app/app-owned.txt
USER app
CMD ["sh", "-c", "id; ls -ln /app; cat /app/app-owned.txt"]
EOF
docker build -q -t learnugroup-07-img:latest .
docker run --rm --name learnugroup-07-c1 learnugroup-07-img:latest
cd ../..
```

在本机执行上述命令的输出（`docker run` 为容器内）：

```text
uid=1001(app) gid=1001(app) groups=1001(app),1001(app)
total 8
-rw-rw-r--    1 1001     1001            17 Oct 18 01:40 app-owned.txt
-rw-rw-r--    1 0        0               17 Oct 18 01:40 root-owned.txt
hello-from-build
```

要点：

1. `COPY` 默认以 `uid=0 gid=0` 创建文件（来源：`man 5 Dockerfile` 的 COPY 条目：All new files and directories are created with mode 0755 and with the uid and gid of 0）；`COPY --chown=1001:1001` 在复制时改属主，上面的输出直接证明。
2. `USER app` 让后续命令与容器默认进程以 `uid=1001` 运行（来源：`man 5 Dockerfile`：Sets the username or UID used for running subsequent commands；Until the USER instruction is set, instructions will be run as root）。
3. `USER` 只是**默认值**，运行时 `-u 0` 仍可覆盖：

```bash
docker run --rm --name learnugroup-07-c2 -u 0:0 learnugroup-07-img:latest id
```

在本机执行上述命令的输出（容器内）：

```text
uid=0(root) gid=0(root) groups=0(root)
```

4. 多阶段构建的作用是：编译阶段可以用 root/大镜像，最终阶段只 `COPY --from=builder` 产物并 `USER` 降权。这样运行镜像里没有编译工具链，攻击面更小。多阶段本身不改变 uid 规则，`COPY --from` 仍支持 `--chown`。

**为什么容器内不要 root。** 在默认 rootful 模式下，容器 root 对绑定挂载拥有宿主 root 的文件权限，还能 chown 宿主文件（§2.4 实测）；一旦进程被攻破，影响面从「容器内」扩大到「宿主可写目录」。非 root 用户 + 最小 capability 才是可接受的默认值。

### 2.6 Compose：user 与 group_add

compose 的 `user:` 等价于 `docker run -u`，`group_add:` 等价于 `--group-add`。下面的实验用宿主 `docker` 组 gid 989 演示「附加组让非 root 用户写组可写目录」：

```bash
mkdir -p demo/cmp/data
docker run --rm --name learnugroup-07-prep -v "$PWD/demo/cmp/data":/d alpine:latest sh -c 'chown 101:989 /d; chmod 770 /d; ls -ldn /d'
```

在本机执行上述命令的输出（容器内）：

```text
drwxrwx---    2 101      989           4096 Oct 18 01:44 /d
```

`demo/cmp/compose.yaml` 的内容如下（用 `cat > demo/cmp/compose.yaml <<'EOF'` 写入即可）：

```yaml
services:
  nogroup:
    image: alpine:latest
    user: "1000:1000"
    volumes: ["./data:/data"]
    command: ["sh", "-c", "id; touch /data/nogroup.txt"]
  withgroup:
    image: alpine:latest
    user: "1000:1000"
    group_add: ["989"]
    volumes: ["./data:/data"]
    command: ["sh", "-c", "id; touch /data/withgroup.txt && echo withgroup-write-ok"]
```

在本机执行 `docker compose -f demo/cmp/compose.yaml -p learnugroup-07-cmp run --rm nogroup` 与 `... withgroup` 的输出（容器内）：

```text
uid=1000 gid=1000 groups=1000
touch: /data/nogroup.txt: Permission denied
uid=1000 gid=1000 groups=989,1000
withgroup-write-ok
```

结论：`group_add` 把 gid 989 加入辅助组，于是进程对 `101:989 770` 的目录有组写权限；gid 989 在容器内没有对应的 `/etc/group` 名字也能生效，因为内核只认数字。

一个 nginx + php-fpm 共享 socket 的骨架（**模式示意，未在本机运行这两个镜像**；uid 以镜像内 `id` 为准）：

```yaml
services:
  php:
    image: php:8.3-fpm-alpine
    volumes:
      - ./www:/var/www/html
      - ./run:/run/php
    # 让 php-fpm 以固定 uid 写 /run/php/www.sock，并在入口里 chown 目录
  web:
    image: nginx:1.20-alpine
    user: "101:101"
    group_add: ["82"]          # 以镜像内 `id` 实测的组为准
    volumes:
      - ./www:/usr/share/nginx/html:ro
      - ./run:/run/php
    ports: ["8080:8080"]
```

关键点：两个容器必须对 socket 所在目录与 socket 文件有互相匹配的 uid/gid 权限；只挂同一个目录不会自动解决。具体排查见 [08-Nginx用户与权限实战](08-Nginx用户与权限实战.md) 的 unix socket 一节。

### 2.7 rootless Docker 与 userns-remap：要求与限制

本机是 rootful 默认模式（SecurityOptions 无 userns 项），以下内容**未在本机实测**，只作为生产环境核对清单。可本机验证的锚点先列出：

```bash
grep demo /etc/subuid /etc/subgid
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
cat /proc/sys/net/ipv4/ip_unprivileged_port_start
command -v newuidmap newgidmap
```

在本机执行上述命令的输出：

```text
/etc/subuid:demo:100000:65536
/etc/subgid:demo:100000:65536
cgroup2fs
cpuset cpu io memory hugetlb pids rdma misc
1024
```

`command -v newuidmap newgidmap` 无输出，说明两个程序都未安装（见下表）。

据此可以判断：

| 条件 | 本机状态 | rootless 需要什么 |
|---|---|---|
| subuid/subgid 范围 | 有（100000 起 65536 个） | 必须有；用 `newuidmap`/`newgidmap` 写多行映射 |
| `newuidmap/newgidmap` | 未安装（`command -v` 无输出） | rootless 的关键 setuid 辅助程序，通常由 `uidmap` 包提供 |
| cgroup | cgroup v2（`cgroup2fs`），控制器齐全 | 需要 cgroup v2 + systemd 用户会话委托，才能限制资源 |
| 非特权端口 | 宿主 `ip_unprivileged_port_start=1024` | 普通用户绑定 <1024 会 EACCES，需 rootlesskit 的端口转发或调低 sysctl |

```text
rootful（本机默认）        rootless
容器 uid 0 ──────────────▶ 宿主 uid 0（真 root）      容器 uid 0 ──▶ 宿主 subuid 区间（如 100000）
docker 组 ──────────────▶ root 等价                    docker 组 ──▶ 普通用户，不再等价 root
```

> 图：rootful 与 rootless 的 uid 差异。rootless 下容器 root 写宿主目录时，inode 属主是 subuid，不是你的 uid，因此「写自己的目录」也会失败，除非用 idmapped mount 或把目录属主调整为 subuid。这一点未在本机验证。

**userns-remap（daemon 级）**。在 `/etc/docker/daemon.json` 写入 `{"userns-remap": "default"}` 并重启 `dockerd` 后，容器 uid 会映射到 subuid。代价：

- 已有镜像/容器/卷的属主与新映射不一致，需要迁移；
- `--privileged`、部分挂载、部分网络模式不可用；
- 排障时 `ls -n` 看到的宿主 uid 变成 subuid，需要对照 `uid_map`；
- 本机未启用，配置片段来自 `man 8 dockerd` 的 `--userns-remap` 语义。

**rootless 的限制**（需以实际环境核对）：

- `--privileged` 只在用户命名空间内有意义，不能获得宿主级设备与挂载权限；挂载任意宿主路径同样受限；
- 端口 <1024 需要端口转发或 `ip_unprivileged_port_start` 调整（本机宿主值 1024）；
- `docker.sock` 位于用户运行时目录（如 `$XDG_RUNTIME_DIR/docker.sock`），不是 `/var/run/docker.sock`；
- 资源限制依赖 cgroup v2 + systemd 委托（本机 cgroup v2 已验证）。

### 2.8 安全边界：docker.sock 与 --privileged

课程立场：**文档解释原理，实验禁止执行**。

- 把宿主 `/var/run/docker.sock` 挂进容器，等于把 root 的 Docker API 交给容器内的进程；容器里只要有 docker 客户端，就能创建新容器、挂载宿主根目录。本课程实验不挂载该 socket，也不提供可复制的挂载命令。
- `--privileged` 按 `man 1 docker-run` 的定义会开放所有设备，并让 AppArmor 放宽到接近宿主进程的访问能力。它不是「方便调试」的普通选项，生产环境应默认禁止。
- 需要查看容器权限时用只读方式：`docker inspect`、`docker top`、`docker exec ... grep CapEff /proc/self/status`。
- 审计入口：检查 `/var/run/docker.sock` 的 mode/属组、`getent group docker` 成员、是否有用户直接持有 root 等价权限。参见 [10-账户安全基线与审计](10-账户安全基线与审计.md)。

### 2.9 配置项 → 权限影响

| 配置项 | 作用点 | 权限影响 | 注意 |
|---|---|---|---|
| 宿主目录 mode/属主 | 绑定挂载的 inode | 决定容器进程能否读写 | 与容器内用户无关，先看 `ls -ldn` |
| `-u/--user`（运行） | 容器进程 fsuid/fsgid | 覆盖镜像 `USER` | 需要镜像内路径对该 uid 可访问 |
| `USER`（Dockerfile） | 构建后默认用户 | 运行时默认身份 | 运行时仍可被 `-u 0` 覆盖 |
| `--group-add` / `group_add` | 辅助组 | 组可写目录的访问 | gid 可数字，无需容器内组名 |
| `COPY --chown` | 镜像内文件属主 | 容器内文件权限 | 默认 uid/gid 0 |
| 绑定挂载 `-v` | 宿主 inode 直通 | 不翻译 uid | 需要 chown 或 `-u` |
| 命名卷 | Docker 管理的 inode | 默认 root:root；copy-up 保留镜像属主 | 首次挂载才复制 |
| `userns-remap` | daemon 级映射 | 容器 uid → subuid | 需重启 daemon，存量数据要迁移 |
| rootless | 用户命名空间 | 容器 root → subuid | 组不再等价 root；端口受限 |
| `--privileged` | 容器权限 | 接近宿主 root | 生产禁用 |
| 挂载 docker.sock | 容器可调 daemon | 等价宿主 root | 课程实验禁止 |

### 2.10 生产环境注意

1. **不要用「加入 docker 组」当权限方案**。需要普通用户部署时，优先 rootless 或受控的 sudo 白名单；组内成员按 root 等价审计。
2. **镜像构建阶段就固定 uid**：`useradd --system` 创建专用账户，`COPY --chown` 设好属主，最终 `USER` 降权。
3. **数据目录归属单一 uid**：绑定挂载的宿主目录明确 chown 给容器运行 uid；多容器共享时用组 + `group_add`，不要 777。
4. **命名卷不是权限银弹**：首次初始化后仍要 chown，或让镜像中的数据目录本身属于目标 uid。
5. **userns-remap/rootless 要提前设计**：已有卷属主、备份恢复、日志采集都会受影响；先在测试环境验证。
6. **禁止把 docker.sock 挂进业务容器**；需要构建/部署能力时用 CI runner 或受控 API。

---

## 三、动手验证

对应实验：[labs/05-docker-uid](../labs/05-docker-uid/)。该 lab 覆盖本章的「默认 root / `-u` / 卷 uid 不匹配 / chown 修复 / 命名卷 / docker.sock 权限」六个现象。

本机验证方式：本机 Docker 29.8 为 rootful，宿主没有 root，部分操作只能在容器里完成。以下命令都在工作区内创建 `demo/` 临时目录，结束时用容器清理 root 属主产物；清理命令只删除 `demo/` 和本章创建的卷，执行前先用 `pwd` 确认当前目录是课程工作区。

```bash
mkdir -p demo/mnt demo/data && chmod 750 demo/data
```

1. 看默认用户与镜像 `USER`：

```bash
docker run --rm --name learnugroup-07-v1 alpine:latest id
docker image inspect nginx:1.20-alpine --format 'User={{.Config.User}}'
```

要看的是：第一条 `uid=0`；第二条输出 `User=`（空），说明 nginx 镜像没有设置默认用户，master 以 root 启动，之后由 `user` 指令降权（详见 08）。

2. 看 `-u` 与镜像内账户无关：

```bash
docker run --rm --name learnugroup-07-v2 -u 1234:1234 alpine:latest sh -c 'id; grep -c 1234 /etc/passwd || true'
```

要看的是：命令能运行、`id` 是 1234，`/etc/passwd` 里没有对应项（`grep -c` 输出 0）。

3. 看容器 root 写宿主目录的属主：

```bash
docker run --rm --name learnugroup-07-v3 -v "$PWD/demo/mnt":/w alpine:latest sh -c 'touch /w/f; ls -ln /w/f'
ls -ln demo/mnt/f
```

要看的是：容器内 `0 0`，宿主本会话显示 `65534`（正常宿主显示 `root`）。文件 mode 644 时宿主 other 可读、不可写；要改属主/写文件就得 chown 或换 uid。

4. 看非 root 用户被宿主目录拒绝：

```bash
docker run --rm --name learnugroup-07-v4 -u 101:101 -v "$PWD/demo/data":/d alpine:latest sh -c 'touch /d/x'
```

要看的是：`touch: /d/x: Permission denied`。先用 `ls -ldn demo/data` 确认是 750/1000:1000。

5. 看 chown 修复：

```bash
docker run --rm --name learnugroup-07-v5 -v "$PWD/demo/data":/d alpine:latest chown 101:101 /d
docker run --rm --name learnugroup-07-v6 -u 101:101 -v "$PWD/demo/data":/d alpine:latest sh -c 'touch /d/x && ls -ln /d'
```

要看的是：第二条成功并显示属主 101。回到宿主 `ls -ldn demo/data` 会看到属主已变成 101（本会话显示 65534，用 `stat -c %u` 看数字）。

6. 看命名卷的默认属主与 copy-up：

```bash
docker volume rm -f learnugroup-07-verify
docker run --rm --name learnugroup-07-v7 -v learnugroup-07-verify:/data alpine:latest ls -ldn /data
docker run --rm --name learnugroup-07-v8 -v learnugroup-07-verify:/usr/share/nginx/html nginx:1.20-alpine ls -ln /usr/share/nginx/html
```

要看的是：空卷 `root:root 755`；第二次挂载后卷里出现镜像的 `index.html`，属主仍是 0。

7. 看构建时的属主控制：

```bash
docker build -q -t learnugroup-07-verify-img demo/img
docker run --rm --name learnugroup-07-v9 learnugroup-07-verify-img sh -c 'id; ls -ln /app'
```

要看的是：`uid=1001(app)`，`app-owned.txt` 属主 1001，`root-owned.txt` 属主 0。

8. 看 compose 的 `group_add`：

```bash
docker compose -f demo/cmp/compose.yaml -p learnugroup-07-verify run --rm withgroup
```

要看的是：`groups=989,1000` 与 `withgroup-write-ok`。

9. 清理（含 root 属主文件）：

```bash
docker run --rm --name learnugroup-07-vclean -v "$PWD/demo":/w debian:13 sh -c 'rm -rf /w/mnt /w/data /w/root-created.txt'
docker volume rm -f learnugroup-07-verify learnugroup-07-copyvol learnugroup-07-vol
rm -rf demo
```

容器输出与宿主输出的差异要记住：容器内 `ls -ln` 的 uid 是**真实数字**；本会话宿主看到的 65534 是 userns 显示溢出，不要拿它当真实属主。

---

## 四、常见误解

❌ 「容器里的 root 被隔离了，所以容器 root 很安全。」 → ✅ 默认 rootful 模式没有 userns 重映射，容器 root 就是宿主 root；它能 chown 宿主绑定目录（验证：§2.4 的 `chown 101:101 /data` 改变了宿主 inode 属主）。

❌ 「普通用户执行 docker 能当 root，是因为 docker 命令有 setuid 位。」 → ✅ `docker` 客户端没有 setuid；它能当 root 是因为客户端通过 `/var/run/docker.sock`（660 root:docker）调用以 root 运行的 daemon（验证：`ls -ln /var/run/docker.sock` 为 660，`curl --unix-socket ... /version` 成功）。

❌ 「把用户加进 docker 组只是方便，不算 root 权限。」 → ✅ 组内成员可以让 daemon 创建挂载宿主目录或带 `--privileged` 的容器（来源：`man 1 docker-run` 对 `--privileged` 的定义：接近宿主进程的访问权），因此等价于 root。

❌ 「Dockerfile 里写了 `USER app`，运行时不会变成 root。」 → ✅ `USER` 只是默认值，`docker run -u 0` 会覆盖它（验证：本机构建后用 `-u 0:0` 运行，`id` 输出 uid=0）。

❌ 「镜像里没有 1234 用户，所以不能用 `-u 1234` 运行。」 → ✅ 可以；uid 是数字，`/etc/passwd` 只影响名字解析（验证：`-u 1234:1234` 的 `id` 正常，`grep` 无对应项）。

❌ 「命名卷会自动继承宿主目录的属主，所以不会有权限问题。」 → ✅ 命名卷根目录默认 `root:root 755`，仅当镜像对应路径带非 root 属主时 copy-up 才会带过来（验证：§2.4 命名卷实测）。

❌ 「容器 root 在宿主创建的文件，普通用户永远删不掉。」 → ✅ 删除/改名由**父目录的 w+x 与 sticky 位**决定，与文件属主无关；父目录对当前用户可写时能删，父目录是 root 的 755 目录时才删不掉。本会话中 `rm -f` 删除容器 root 创建的文件成功（验证：§2.4 清理小节），在 root 属主的 755 `.git` 子目录里删除失败（验证：09 章 git 案例）。这正好呼应 [03-文件权限与ACL](03-文件权限与ACL.md) 中「目录 w 位决定增删」的结论。

❌ 「容器里 `chown` 只影响容器，不会动宿主文件。」 → ✅ 绑定挂载下 `chown` 改的就是宿主 inode 的属主（验证：§2.4 中 chown 后宿主 `ls -ldn` 显示属主变化）。

❌ 「rootless Docker 只是不用 root 启动 daemon，卷权限和 rootful 一样。」 → ✅ rootless 下容器 uid 映射到 subuid，写宿主目录时 inode 属主是 subuid 而不是你的 uid，权限问题反而更多；需要 idmapped mount 或目录属主配合（原理见 [06-命名空间与uid映射](06-命名空间与uid映射.md)，本机未实测）。

---

## 五、速查表

| 现象/需求 | 命令或配置 | 关键点 |
|---|---|---|
| 看容器默认用户 | `docker run --rm IMAGE id` | 默认 root |
| 看镜像默认用户 | `docker image inspect IMAGE --format '{{.Config.User}}'` | 空 = root |
| 以指定 uid 运行 | `docker run -u 1000:1000 IMAGE ...` | 覆盖 `USER`，镜像内可无该用户 |
| 附加组 | `docker run --group-add 989 IMAGE ...` | 组名可不存在，数字 gid 即可 |
| 看宿主目录属主 | `ls -ldn DIR` / `stat -c '%u:%g %a' DIR` | 绑定挂载权限第一现场 |
| 看容器内文件属主 | `docker run --rm -v "$PWD/DIR":/d IMAGE ls -ln /d` | 容器内数字才是真实属主 |
| 修宿主目录属主 | `docker run --rm -v "$PWD/DIR":/d IMAGE chown UID:GID /d` | 容器 root 有 CAP_CHOWN |
| 以宿主 uid 运行 | `-u $(id -u):$(id -g)` | 文件属主即自己 |
| compose 固定用户 | `user: "1000:1000"` | 等价 `-u` |
| compose 附加组 | `group_add: ["989"]` | 等价 `--group-add` |
| 命名卷默认属主 | `docker run --rm -v VOL:/d IMAGE ls -ldn /d` | 默认 root:root |
| 看卷 copy-up | 挂载到镜像有内容的路径后 `ls -ln` | 属主保留镜像值 |
| Dockerfile 设默认用户 | `USER app` | 只影响默认值 |
| COPY 改属主 | `COPY --chown=UID:GID src dest` | 默认 uid/gid 0 |
| 看 socket 权限 | `ls -ln /var/run/docker.sock` | 660 root:docker |
| 看 docker 组成员 | `getent group docker` | 组成员 = root 等价 |
| 验证 API 通路 | `curl -s --unix-socket /var/run/docker.sock http://localhost/version` | 客户端只是 HTTP |
| 看是否 userns-remap | `docker info --format '{{json .SecurityOptions}}'` | 无 userns 项 = 默认 rootful |
| 看 subuid | `grep $USER /etc/subuid /etc/subgid` | rootless/remap 的基础 |
| 清理 root 属主产物 | 一次性容器 `rm -rf` | 不要用宿主 `sudo rm -rf` |
| 判断删除权限 | 看父目录 `w+x` 与 sticky | 与文件属主无关 |

---

## 六、延伸阅读

- 本章实验：[labs/05-docker-uid](../labs/05-docker-uid/)（uid 对照、卷属主、socket 权限）。
- 下一章：[08-Nginx用户与权限实战](08-Nginx用户与权限实战.md)（master/worker 模型与 403 排查）。
- 排障方法：[09-权限排障手册](09-权限排障手册.md)（EACCES/EPERM、容器特有问题）。
- 原理章节：[01-权限模型全景](01-权限模型全景.md)、[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[05-提权与降权机制](05-提权与降权机制.md)、[06-命名空间与uid映射](06-命名空间与uid映射.md)。
- 安全基线：[10-账户安全基线与审计](10-账户安全基线与审计.md)。
- man 页：`man 1 docker-run`、`man 8 dockerd`、`man 5 Dockerfile`、`man 7 unix`、`man 7 user_namespaces`。
