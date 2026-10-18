# labs/05 · Docker 用户与卷属主动手实验

> **一句话总结**：把「容器 root = 宿主 root」「`-u` 数字 uid」「卷属主不对」三件事跑成可断言的现象。

> **本机验证**：✅ 需要 docker（本机 rootful 29.8.1 + `debian:13` 镜像），不需要网络、不需要 root 登录。

| 项目 | 内容 |
|---|---|
| 演示现象 | `docker.sock` 权限与 docker 组；默认 root；`-u 1000:1000`；`-u 101:101` 写 750 目录失败与 `chown` 修复；容器 root 产物显示 65534；删除语义；命名卷属主；`-u 1234` 无 passwd 条目 |
| 运行环境 | 宿主 + `docker run --rm debian:13`（只挂载本 lab 的 `.tmp/`） |
| 预计耗时 | 约 10 秒 |
| 对应章节 | [docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md)、[docs/09-权限排障手册](../../docs/09-权限排障手册.md)、[docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md) |

## 一、这个 lab 演示什么

容器里到底是谁在访问文件？把常见误会拆成 8 组断言：

1. `/var/run/docker.sock` 是 `660` 的 socket，且当前用户在 `docker` 组——**能访问 socket 就等价于 root**；
2. 不指定 `-u` 时容器内是 `uid=0(root)`；
3. 容器 root 在 bind mount 里创建的文件，**本机会话视角显示为 `65534`**（未映射 uid 溢出）；
4. 删除权限由**父目录的 w+x（以及 sticky）**决定，不由文件属主决定；
5. `-u 1000:1000` 时容器 uid 与宿主 uid 相同，创建的文件宿主视角也是 1000；
6. `-u 101:101` 写 `750` 的宿主目录 → `EACCES`，`chown 101:101` 后成功；
7. 命名卷根目录默认属于 root，需要在容器里 `chown`；
8. 镜像 `/etc/passwd` 里没有 1234 这个用户，`-u 1234:1234` 依然能运行。

> 锚点：容器默认**没有 userns-remap**，容器内 uid 数字与宿主 uid 数字一一对应；看到「文件属主不对」先问
> 「这个 uid 在宿主上是哪个用户」，而不是「容器里是不是 root」。

## 二、前置条件

- `docker` daemon 可用（本机 rootful，未启用 userns-remap），本地已有 `debian:13` 镜像。
- 无需 root、无需网络；脚本只用 `docker run --rm` + 唯一 `--name`，只挂载本 lab 的 `.tmp/` 目录。
- 安全边界：不使用 `--privileged`、不挂载 `/var/run/docker.sock`、不挂宿主根目录。
- 脚本退出时 `trap` 删除容器、命名卷与 `.tmp/`；`.tmp/` 中 root/异 uid 属主的文件由一次性容器删除。

## 三、运行方式

```bash
cd labs/05-docker-uid
bash run.sh
```

- 无交互、可重复；退出码 `0` 表示全部断言通过，`1` 表示有 `FAIL`。
- docker 或镜像缺失时打印 `SKIP` 并退出 0。
- 每行以 `ok` / `FAIL` 开头，末行固定为 `PASS n / FAIL m`。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. 依赖检查 ==
ok   docker 可用且本地存在 debian:13 镜像

== 2. docker.sock 的权限与 docker 组 ==
srw-rw---- 1 nobody nogroup 0 Oct 11 09:24 /var/run/docker.sock
socket mode=660 type=socket
ok   /var/run/docker.sock 是 socket
ok   socket 模式为 660（只有属主与属组可读写）
getent group docker: docker:x:989:demo
ok   当前用户在 docker 组里（docker:x:989:demo）
注：本会话是受限沙箱，ls 里 socket 的属主/属组显示为 65534，真实属组是 docker（gid 见 /etc/group）。

== 3. 默认用户是 root；容器 root 创建的文件在宿主显示 65534 ==
uid=0(root) gid=0(root) groups=0(root)
ok   未指定 -u 时容器内是 uid 0(root)
-rw-r--r-- 1 0 0 0 Oct 18 01:46 /d/by-root
宿主视角 by-root 的数值属主: 65534
ok   容器 root 创建的文件在宿主视角显示为 65534（未映射 uid 的溢出显示）

== 4. 删除语义：看父目录的 w+x，而不是文件属主 ==
--- 情形 A：父目录属于当前用户且可写（无 sticky） ---
ok   父目录可写时，宿主能删除 root 属主文件（删除看目录 w+x）
--- 情形 B：父目录由容器 root 创建，宿主无写权限 ---
drwxr-xr-x 2 0 0 4096 Oct 18 01:46 /d/rootdir2
-rw-r--r-- 1 0 0    0 Oct 18 01:46 /d/rootdir2/x
宿主删除 root 属主目录内文件: rc=1 rm: cannot remove '/home/demo/code/learn-ugroup/labs/05-docker-uid/.tmp/rootdir/rootdir2/x': Permission denied
ok   父目录属主是 root 且 mode 755 时，宿主删不掉里面的文件
（清理仍按约定交给一次性容器，不用宿主 rm 去动 root 属主目录）

== 5. -u 1000:1000：容器 uid 与宿主 uid 相同 ==
uid=1000 gid=1000 groups=1000
-rw-r--r-- 1 1000 1000 0 Oct 18 01:46 /d/by1000
ok   容器内 uid=1000
ok   容器 uid 1000 创建的文件，宿主视角属主也是 1000

== 6. -u 101:101 写 750 的宿主目录：EACCES；chown 101 后成功 ==
uid 101 写 750 目录: rc=1 输出: touch: cannot touch '/d/x': Permission denied
ok   uid 101 写 750 宿主目录失败
ok   失败原因是 Permission denied（EACCES）
drwxr-x--- 2 65534 65534 4096 Oct 18 09:46 /home/demo/code/learn-ugroup/labs/05-docker-uid/.tmp/host750
chown 101:101 后 uid 101 写入: rc=0 输出: -rw-r--r-- 1 101 101 0 Oct 18 01:46 /d/x
ok   chown 101:101 之后 uid 101 能写入

== 7. 命名卷的属主：默认 root，需要在容器里 chown ==
drwxr-xr-x 2 0 0 4096 Oct 18 01:46 /data
-rw-r--r-- 1 0 0    0 Oct 18 01:46 /data/rootfile
ok   命名卷根目录默认属主是 0(root)
uid 1000 写命名卷: rc=1 输出: touch: cannot touch '/data/x': Permission denied
ok   uid 1000 默认写不进 root 属主的命名卷
ok   容器内 chown 1000:1000 后 uid 1000 能写命名卷

== 8. 镜像里没有该用户也能用 -u 1234 运行 ==
uid=1234 gid=1234 groups=1234
ok   镜像是 debian:13 且 /etc/passwd 无 1234，仍能以 -u 1234 运行

PASS 17 / FAIL 0
```

## 五、分步讲解

### 1. docker.sock 与 docker 组

```text
srw-rw---- 1 nobody nogroup 0 ... /var/run/docker.sock
socket mode=660 type=socket
getent group docker: docker:x:989:demo
```

socket 是 `660`，属主/属组才有读写；本机 `demo` 在 `docker` 组里，所以能调 daemon。
**能写这个 socket 就等于能以 root 操作宿主**（可以起一个挂载宿主根目录的容器），因此「加入 docker 组」
在安全上等价于给 root——这是 [docs/07](../../docs/07-Docker用户与权限实战.md) 的重点之一。
本会话是受限沙箱，`ls` 显示的 `nobody nogroup` 是未映射 uid 的溢出显示，真实属组看 `/etc/group`。

### 2. 默认用户与容器 root 的产物

- 不带 `-u`：`uid=0(root) gid=0(root) groups=0(root)`；
- 容器 root 在 bind mount 里 `touch /d/by-root`，容器内 `ls -ln` 是 `0 0`；
- 回到本会话 `stat -c %u` 得到 **65534**。

原因：本会话运行在嵌套用户命名空间里，`init` 命名空间的 uid 0 没有映射到本会话，于是显示为溢出 UID。
**关键结论**：inode 上记录的是宿主命名空间的 kuid（这里是 0 = root），不是「容器里的 0」。

### 3. 删除语义：父目录的 w+x 才决定能不能删

两个对照实验：

- 情形 A：`by-root` 在**当前用户拥有且可写**的目录里，宿主 `rm` **成功**。POSIX 的 unlink 只检查
  父目录的 `w+x`（以及目录 sticky 时的属主规则），与文件属主无关；
- 情形 B：容器 root 创建了 `rootdir2`（`drwxr-xr-x root root`），宿主再删里面的 `x` → `Permission denied`。

所以「root 创建的文件删不掉」的真实条件是**父目录不让你写**，而不是文件属于 root。
业务上遇到「容器写出来的文件宿主删不掉」，先 `ls -ld` 父目录，再决定是 `chown` 父目录、调整权限，
还是用容器清理。

### 4. `-u 1000:1000`：数字 uid 才是唯一身份

容器内 `id` 输出 `uid=1000 gid=1000 groups=1000`（镜像里没有这个用户，只是数字）。
因为本机没有启用 userns-remap，容器 uid 1000 与宿主 uid 1000 是同一个 kuid，所以：

```text
容器内 ls -ln: -rw-r--r-- 1 1000 1000 ... /d/by1000
宿主 stat %u:  1000
```

这就是「容器内写出来的文件属主与容器进程 uid 一致」的完整解释。

### 5. `-u 101:101` 写 750 目录：EACCES 与 chown 修复

- 宿主建 `.tmp/host750`，属主 1000、mode 750；
- 容器以 `-u 101:101` `touch /d/x` → `Permission denied`（101 既不是属主，也不在属组，other 无权限）；
- 在容器里 `chown 101:101 /d` 后同一个命令成功。

注意 `chown` 之后宿主视角目录属主变成 `65534`（101 未映射），此时宿主自己也**不再能往这个目录写**——
所以本 lab 的清理必须交给一次性容器（脚本 `trap` 里已这样做）。

### 6. 命名卷：属主同样是 root

- `docker volume create` 后，卷根目录在容器内 `drwxr-xr-x 0 0`；
- `-u 1000` 写入 → `Permission denied`；
- 容器内 `chown 1000:1000 /data` 后成功。

命名卷不是「自动适应用户」的魔法：首次创建时属主是 root，后续要么 chown，要么用镜像里的入口脚本调整，
要么用 rootless/userns-remap 重新规划 uid（见 docs/07 的解法对比表）。

### 7. `-u 1234`：镜像里没有这个用户也能跑

```text
uid=1234 gid=1234 groups=1234
```

`-u` 接受纯数字，不要求 `/etc/passwd` 有条目；`/etc/passwd` 只影响 `id` 能不能把数字翻译成名字、
以及 `$HOME` 等默认值。排查「容器里没有某个用户」时，这不影响用数字 uid 运行，但会影响依赖用户名查找的程序。

## 六、清理

`trap` 中依次：`docker rm -f` 所有一次性容器 → `docker volume rm -f` 命名卷 → 用一次性容器
`rm -rf /w/*` 清掉 `.tmp/` 里 root/101 属主的内容 → 删除 `.tmp/`。
手动清理：

```bash
docker volume rm -f learnugroup-05-docker-uid-$$-vol 2>/dev/null || true
docker run --rm -v "$PWD/.tmp":/w debian:13 sh -c 'rm -rf /w/*'
rm -rf labs/05-docker-uid/.tmp
```

## 七、对应章节

- [docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md)：容器 uid 映射、卷属主五种解法、docker 组风险。
- [docs/09-权限排障手册](../../docs/09-权限排障手册.md)：`docker 卷写不进去` 的诊断顺序。
- [docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)：删除看目录 `w+x`、sticky 位。
- 相邻实验：[labs/02-acl](../02-acl/)（不 chown 的 ACL 修法）、[labs/06-nginx-perm](../06-nginx-perm/)。

## 八、延伸练习

1. **命名卷 vs 绑定挂载**：把第 7 节换成 bind mount 一个 750 目录，对比失败信息；再查
   `docker volume inspect` 的 `Mountpoint`，解释两者的属主初始化差异。
2. **父目录 sticky**：建一个 `1777` 目录，让容器 `-u 101` 创建文件、宿主尝试删除，验证 sticky 对删除的影响
   （与 [labs/07](../07-drills/) 场景 4 对照）。
3. **userns-remap 原理推演**：读 docs/07 的 `daemon.json` 片段，推断启用后「容器 uid 1000」会映射到宿主的
   哪个数字，并说明为什么本 lab 的「容器 uid == 宿主 uid」结论会失效。
