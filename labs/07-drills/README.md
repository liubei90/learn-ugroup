# labs/07 · 权限排障演练（5 个故障场景）

> **一句话总结**：5 个「现象 → 诊断 → 根因 → 修复」闭环演练，支持 `--quiz` 隐藏答案自测。

> **本机验证**：✅ 需要 docker + `debian:13` 镜像；场景 2 在宿主完成，其余场景用一次性容器跨 uid 复现。

| 项目 | 内容 |
|---|---|
| 演示现象 | 600 文件跨 uid EACCES；目录缺 x 位；绑定挂载卷 uid 不匹配；sticky 目录删除；docker.sock 组权限模拟 |
| 运行环境 | 宿主 + `docker run --rm debian:13`（只挂载本 lab 的 `.tmp/`） |
| 预计耗时 | 约 10 秒；带 `--quiz` 相同 |
| 对应章节 | [docs/09-权限排障手册](../../docs/09-权限排障手册.md)、[docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)、[docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md) |

## 一、这个 lab 演示什么

排障不是背命令，而是把「现象 → 诊断 → 根因 → 修复」跑成闭环。本 lab 有 5 个真实故障：

| # | 故障 | 一句根因 | 修复方向 |
|---|---|---|---|
| 1 | 容器 uid 101 读宿主 600 文件 → EACCES | 文件 mode 只给属主 1000 读 | `chmod 644` / chown / ACL |
| 2 | 宿主读 600 目录里的 644 文件 → EACCES | 目录缺 `x`，路径无法解析 | `chmod 700` 目录 |
| 3 | 容器 uid 101 写 750 宿主目录 → EACCES | 目录属主/组不匹配 | 容器内 `chown 101:101` |
| 4 | uid 101 删不掉别人的文件 → EPERM | sticky 位保护 | 由属主/root 删除（不是放宽 777） |
| 5 | 无 docker 组读 660 root:docker 文件 → EACCES | 660 只给属组 | 谨慎加入 docker 组（= root 等价） |

每个场景都先**复现故障并断言失败**，再**执行修复并断言成功**。这保证 README 里的结论不是纸面推导。

## 二、前置条件

- `docker` daemon 可用，本地已有 `debian:13` 镜像；场景 2 只需要宿主命令。
- 需要命令：`cat`、`ls`、`stat`、`namei`（可选，用来展示逐级权限）、`docker`。
- 不需要 root、不需要网络；容器只用 `--rm` + 唯一 `--name`，只挂载本 lab 的 `.tmp/`。
- 安全边界：不使用 `--privileged`、不挂载真实 `/var/run/docker.sock`、不挂宿主根目录；
  场景 5 用同 mode/属组的普通文件**模拟** socket 权限，不触碰真实 socket。

## 三、运行方式

```bash
cd labs/07-drills
bash run.sh          # 正常模式：显示现象、诊断、根因、修复
bash run.sh --quiz   # 自测模式：隐藏根因/修复，只留现象与断言
```

- 无交互、可重复；退出码 `0` 表示全部断言通过，`1` 表示有 `FAIL`。
- docker / 镜像缺失时打印 `SKIP` 并退出 0。
- 每行以 `ok` / `FAIL` 开头，末行固定为 `PASS n / FAIL m`。

## 四、真实运行输出

### 4.1 正常模式（`bash run.sh`）

```text
== 0. 依赖检查 ==
ok   docker 可用且本地存在 debian:13 镜像

== 场景 1：600 文件，另一个 uid 读不到（EACCES） ==
现象：容器内 uid 101 读取宿主 600 文件
-rw------- 1 1000 1000 10 Oct 18 01:47 /d/data.txt
cat: /d/data.txt: Permission denied
rc=1
诊断：ls -ln 看文件的属主/mode；容器内 id 看读取者 uid；cat 的 errno=EACCES。
根因：data.txt 属主 1000、mode 600，uid 101 既非属主也不在属组，other 为 ---。
修复：放宽读权限到 644（或 chown/ACL，见 labs/02、labs/05）。
ok   场景 1：未授权 uid 读取被拒绝
修复后 rc=0 输出: DRILL1-OK
ok   场景 1：修复后跨 uid 读取成功

== 场景 2：目录缺 x 位，里面 644 文件也读不到 ==
现象：宿主 cat 一个 mode 600 的目录里的 644 文件
drw------- 2 1000 1000 4096 Oct 18 09:47 /home/demo/code/learn-ugroup/labs/07-drills/.tmp/d2
cat: /home/demo/code/learn-ugroup/labs/07-drills/.tmp/d2/inner.txt: Permission denied
rc=1
f: /home/demo/code/learn-ugroup/labs/07-drills/.tmp/d2/inner.txt
drwxr-xr-x nobody nogroup /
drwxr-xr-x nobody nogroup home
drwx------ demo demo  demo
drwxrwxr-x demo demo  code
drwxrwxr-x demo demo  learn-ugroup
drwxrwxr-x demo demo  labs
drwxrwxr-x demo demo  07-drills
drwxrwxr-x demo demo  .tmp
drw------- demo demo  d2
                           inner.txt - Permission denied
诊断：用 namei -l（或对路径逐级 stat）看每一级目录的 x 位。
根因：目录 mode 600 没有 x，路径解析无法进入目录；文件自身 644 不起作用。
修复：chmod 700 目录（只给属主 x），之后即可读。
ok   场景 2：目录内文件不可读
修复后 rc=0 输出: DRILL2-OK
ok   场景 2：修复后可读

== 场景 3：绑定挂载的宿主目录 uid 不匹配，容器写不进去 ==
现象：容器 uid 101 往宿主 750 目录写文件
drwxr-x--- 2 1000 1000 4096 Oct 18 09:47 /home/demo/code/learn-ugroup/labs/07-drills/.tmp/d3
uid=101 gid=101 groups=101
touch: cannot touch '/d/x': Permission denied
rc=1
诊断：宿主 ls -ldn 目录、容器内 id 对照 uid/gid；touch 报 EACCES。
根因：目录属主 1000、mode 750，容器 uid 101 无写权限；绑定挂载不改变 inode 属主。
修复：在容器内 chown 101:101 目录（或改 mode/换 -u/用 ACL）。
ok   场景 3：跨 uid 写入被拒绝
修复后 rc=0 输出: -rw-r--r-- 1 101 101 0 Oct 18 01:47 /d/x
ok   场景 3：修复后可写

== 场景 4：sticky 目录（1777）里，uid 101 删不掉别人的文件 ==
现象：1777 目录里，容器 uid 101 删除宿主文件 / 删除自己的文件
total 4
-rw-r--r-- 1  101  101  0 Oct 18 01:47 other-file
-rw-rw-r-- 1 1000 1000 11 Oct 18 01:47 owner-file
drwxrwxrwt 2 1000 1000 4096 Oct 18 09:47 /home/demo/code/learn-ugroup/labs/07-drills/.tmp/d4
删除他人文件: rc=1 输出: rm: cannot remove '/d/owner-file': Operation not permitted
删除自己的文件: rc=0 输出: 
诊断：ls -ldn 看目录 mode 是否含 t；ls -ln 看文件属主；stat -c %a 确认 1777。
根因：sticky 位规定只有文件属主、目录属主或 root 能删除；uid 101 不是 owner-file 的属主。
修复：这是保护机制而不是故障；需要删除时由属主/root 操作，或调整目录策略。
ok   场景 4：sticky 目录下删除他人文件被拒绝
ok   场景 4：删除自己文件成功

== 场景 5：docker.sock 组权限的模拟（660 root:docker） ==
现象：先看真实 docker.sock，再用同 mode/属组的普通文件模拟组权限
real docker.sock: mode=660 type=socket
docker 组 gid=989
-rw-rw---- 1 0 989 15 Oct 18 01:47 /w/socklike
无 docker 组读取: rc=1 输出: cat: /w/socklike: Permission denied
补 docker 组后读取: rc=0 输出: sock-like-data
诊断：stat/ ls -l 看 socket 的属主、属组、mode；id 看自己是否在 docker 组。
根因：660 只允许属主与属组读写；不在 docker 组的进程访问 socket 得到 EACCES。
修复：把用户加入 docker 组（= 给 root 等价权限，需谨慎）；本场景只做文件级模拟，不挂真实 socket。
ok   场景 5：无组权限读取 660 文件被拒绝
ok   场景 5：补组后读取成功

PASS 11 / FAIL 0
```

### 4.2 自测模式（`bash run.sh --quiz`）节选

```text
【--quiz 模式】只显示现象与断言，根因/修复已隐藏；去掉 --quiz 重跑可看答案。

== 场景 1：600 文件，另一个 uid 读不到（EACCES） ==
现象：容器内 uid 101 读取宿主 600 文件
-rw------- 1 1000 1000 10 Oct 18 01:47 /d/data.txt
cat: /d/data.txt: Permission denied
rc=1
ok   场景 1：未授权 uid 读取被拒绝
修复后 rc=0 输出: DRILL1-OK
ok   场景 1：修复后跨 uid 读取成功
...
答案已隐藏。去掉 --quiz 重新运行即可查看每个场景的根因与修复。

PASS 11 / FAIL 0
```

## 五、场景详解（现象 → 诊断 → 根因 → 修复）

### 场景 1：600 文件跨 uid EACCES

- **现象**：容器内 `uid 101` 执行 `cat /d/data.txt` → `Permission denied`。
- **诊断**：`ls -ln /d/data.txt` 看到 `-rw------- 1 1000 1000`；容器内 `id` 确认读取者是 101。
- **根因**：文件只给属主 1000 读；101 不是属主、不在属组、other 为 `---`，`open()` 返回 `EACCES`。
- **修复**：`chmod 644` 后 other 可读；生产上更常见的是 `chown` 给服务用户或用 ACL（[labs/02](../02-acl/)）。

### 场景 2：目录缺 x 位

- **现象**：`cat dir/inner.txt` 报 `Permission denied`，尽管 `inner.txt` 是 644。
- **诊断**：`ls -ldn` 看到目录 `drw-------`；`namei -l` 逐级显示哪一级断了（输出里 `d2` 那行没有 `x`）。
- **根因**：目录的 `x` 是「搜索/遍历」权限，缺它就无法把路径解析到文件，文件自己的 mode 不参与。
- **修复**：`chmod 700 dir`；只读共享目录通常用 `755` 或 `750`，不要用 `644` 这种「有 r 无 x」的组合。

### 场景 3：绑定挂载卷 uid 不匹配

- **现象**：容器 `-u 101:101` 往宿主 `750` 目录 `touch` → `Permission denied`。
- **诊断**：宿主 `ls -ldn` 看目录属主 1000；容器内 `id` 看自己 101；`touch` 的 errno 是 `EACCES`。
- **根因**：bind mount 直接暴露宿主 inode，容器进程的 uid 就是权限判断依据；101 不是属主也不在属组。
- **修复**：容器内 `chown 101:101` 目录；或 `-u` 改成目录属主；或用 ACL（详见 [labs/05](../05-docker-uid/)）。

### 场景 4：sticky 目录删除

- **现象**：1777 目录里，uid 101 删 `owner-file`（属主 1000）→ `Operation not permitted`；删自己的 `other-file` 成功。
- **诊断**：`ls -ldn` 看到目录 `drwxrwxrwt`（t = sticky）；`ls -ln` 看两个文件属主不同。
- **根因**：sticky 位下，只有**文件属主、目录属主或 root** 能 unlink；101 只是「目录可写」，不够。
- **修复**：这是 `/tmp` 这类共享目录的保护机制，不是故障；需要删除时由属主/root 操作。
  把目录改成 777 去掉 sticky 会引入安全问题，不推荐。

### 场景 5：docker.sock 组权限（模拟）

- **现象**：真实 `/var/run/docker.sock` 是 `660 root:docker`；用同 mode/属组的普通文件模拟：
  uid 1000（不在 docker 组）读取 → `Permission denied`；加 `--group-add 989` 后 → 读取成功。
- **诊断**：`stat -c '%a %F' /var/run/docker.sock`、`getent group docker`、`id`。
- **根因**：660 只给属主与属组；docker 组之外的进程连不上 socket。能访问 socket = 能以 root 操作宿主，
  所以「加入 docker 组」是高风险操作（详见 docs/07）。
- **修复**：把用户加入 docker 组（`usermod -aG docker`）后重新登录；更安全的替代是 rootless 容器或 sudo 白名单。
  本 lab 只做文件级模拟，**不挂载真实 socket**。

## 六、`--quiz` 模式怎么用

- 先 `bash run.sh` 看完整版，理解每个场景；
- 再 `bash run.sh --quiz`，只给你现象与断言，先口述「诊断/根因/修复」，再对照完整版；
- `--quiz` 不会跳过任何断言，退出码与正常模式一致（答案隐藏，验证不缩水）。

## 七、清理

`trap` 删除全部一次性容器（`--rm` 本来就自动删）并用一次性容器清理 `.tmp/` 里 101/root 属主的内容，
最后删除 `.tmp/`。手动清理：

```bash
docker run --rm -v "$PWD/.tmp":/w debian:13 sh -c 'rm -rf /w/*'
rm -rf labs/07-drills/.tmp
```

## 八、对应章节

- [docs/09-权限排障手册](../../docs/09-权限排障手册.md)：EACCES/EPERM 区分、5 分钟诊断流程、案例集。
- [docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)：目录 x 位、sticky 位、特殊位。
- [docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md)：卷 uid 不匹配、docker.sock 风险。
- 相邻实验：[labs/02-acl](../02-acl/)、[labs/05-docker-uid](../05-docker-uid/)、[labs/06-nginx-perm](../06-nginx-perm/)。

## 九、延伸练习

1. **自测**：不看 README，先 `--quiz` 跑一遍，把 5 个场景的「诊断命令 → 根因 → 修复」写在纸上，再对照。
2. **加一个场景**：把 nginx 的 `error.log`（[labs/06](../06-nginx-perm/)）改到 700 目录，复现日志写入失败，
   按本 lab 格式补一个场景 6（现象/诊断/根因/修复/断言）。
3. **EACCES vs EPERM**：对比场景 1（EACCES，权限位不够）与场景 4（EPERM，sticky 保护），
   用 `strace -e trace=unlink,openat` 观察两者 errno 差异，并总结排障时如何快速区分。
