# 06 · 命名空间与 uid 映射

> **一句话总结**：usr namespace 如何把“容器里的 root”翻译成“宿主的某个普通 uid”，以及未映射时为什么显示 65534。

> **本机验证**：⚠️ 部分需容器 —— userns 实验用宿主 `unshare`（可用），容器内 `uid 0` 与宿主 uid 的关系用 `docker run` 实测；本机缺 `newuidmap/newgidmap`，多行 uid_map 与 rootless 容器只能讲原理并标注“未验证”。

| 项目 | 内容 |
|---|---|
| 回答的问题 | 为什么容器里的 root 不是宿主的 root？`uid_map` 的三个数字怎么读？为什么只能写一次、未映射的 uid 显示 65534？容器引擎的 rootful / userns-remap / rootless 三种模式差在哪？ |
| 适合读者 | 读过 04/05，需要解释“容器里 root 写宿主文件为什么属主不对”、或要配置 userns-remap / rootless 的工程师 |
| 前置阅读 | [01-权限模型全景](01-权限模型全景.md)、[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[05-提权与降权机制](05-提权与降权机制.md) |
| 主要来源 | `man 7 user_namespaces`、`man 1 unshare`、`man 2 setns`、`man 8 mount`、本机 `unshare`/`docker` 实测 |

## 一、先建立直觉

### 1.1 一个 uid 数字，两套含义

容器里的进程 `id` 显示 `uid=0(root)`，但这不代表它有宿主 root 的权限。
**uid 是“相对于某个 user namespace 的数字”**；同一个内核对象（进程、文件 inode）
在不同 namespace 里可以显示成不同的数字。

```text
初始 user namespace（宿主）           容器里的 user namespace
uid 0    = 真 root                    uid 0 = 容器里的“root”
uid 1000 = 普通用户 demo            uid 1000 = 容器里的另一个用户
        ▲                                      ▲
        └──────── uid_map 负责翻译 ────────────┘
        容器内 uid 0  →  宿主 uid 0（rootful，无映射）
        容器内 uid 0  →  宿主 uid 100000（userns-remap / rootless）
```

图：user namespace 是“uid 的翻译层”。容器内看到的 0 只是一个标签，
真正决定文件属主与权限的是**内核里的 kuid**（初始 namespace 的数字）是否被映射。

这也是“容器 root 创建的文件在宿主上属主不对”的根源：rootful 容器没有 userns，
容器 uid 0 就是宿主 uid 0；一旦启用 userns，容器 uid 0 会被翻译成 subuid 区间里的某个数字。

### 1.2 namespace 家族：user namespace 是“总开关”之一

Linux 的 namespace 不止 user 一种。与本课程相关的是：

| namespace | 隔离什么 | 非特权用户能否单独创建 | 与 uid 的关系 |
|---|---|---|---|
| user | uid/gid 的映射、capability 的“作用域” | ✅（`unshare -U`） | 本章主角 |
| mount | 挂载点视图 | ❌ 需要 userns 或 CAP_SYS_ADMIN | 文件权限判定受挂载选项影响 |
| pid | 进程号视图 | ❌ 需要 userns | 容器内 PID 1 |
| net | 网络设备/端口 | ❌ 需要 userns | 容器内 `ip_unprivileged_port_start` 可为 0 |
| uts | hostname | ❌ 需要 userns | 无 |
| ipc | SysV IPC / POSIX mqueue | ❌ 需要 userns | 无 |
| cgroup | cgroup 视图 | ❌ 需要 userns | 无 |
| time | 时钟偏移 | ❌ 需要 CAP_SYS_TIME + userns | 无 |

“非特权用户能否单独创建”的实测见 2.5：宿主 `unshare -m` / `-n` / `-p` 都失败，
而 `unshare -Ur -m`（先建 userns 再建 mount ns）成功。

### 1.3 userns 的核心数据结构：uid_map / gid_map

每个 user namespace 都有一张映射表，通过 `/proc/PID/uid_map` 和 `/proc/PID/gid_map` 暴露。
一行三个数字：

```text
<内层起始 uid>   <外层起始 uid>   <长度>
```

例如 `0 1000 1` 的意思是：**这个 namespace 里的 uid 0，对应父 namespace 里的 uid 1000，共 1 个**。
`gid_map` 完全同理（把 uid 换成 gid）。`来源：man 7 user_namespaces`
（User and group ID mappings: uid_map and gid_map）。

### 1.4 本章在全局模型里的位置

- 04 章讲的 `CapEff`、`/proc/PID/status` 的 `Uid:`，在 userns 里**显示的都是内层数字**；
- 05 章讲的“容器 root 只有 14 个 cap”，根源是**容器的 userns 边界 + Docker 的 Bounding 设置**；
- 文件权限判定用的是**内核 kuid**，与你在容器里看到的数字之间隔着 uid_map。

```text
        进程（容器内）                      文件（宿主 inode）
        uid 0（内层）                        kuid 1000（初始 ns）
             │                                     │
             └──── uid_map: 0 → 1000 ──────────────┘
                 内核翻译后比较：1000 vs 1000 → 属主匹配
```

图：权限比较发生在内核的 kuid 层，`id`/`ls -n` 只是把 kuid 按当前 namespace 的映射“反译”成数字。

### 1.5 本机条件

| 能力 | 本机结果 | 命令 |
|---|---|---|
| 非特权创建 userns | ✅ 可用 | `unshare -Ur id` |
| 单 uid 映射 | ✅ 可用 | `unshare -Ur` 自动写 `0 <euid> 1` |
| 多行 uid_map | ❌ 缺 `newuidmap/newgidmap` | `unshare --map-users ...` 报 `failed to execute newuidmap` |
| `/etc/subuid`、`/etc/subgid` | ✅ 存在：`demo:100000:65536` | `cat /etc/subuid /etc/subgid` |
| rootless docker / userns-remap | ❌ 需要改 daemon 配置并重启 | `docker info` |
| 观察父 namespace | ⚠️ 受限：`NS_GET_PARENT` 返回 EPERM | 见 2.4 |

```text
$ cat /etc/subuid /etc/subgid
demo:100000:65536
demo:100000:65536
$ unshare --map-users 0:1000:1 --user id
unshare: failed to execute newuidmap: 没有那个文件或目录
```

验证：上述宿主命令；`newuidmap` 缺失也能从 `command -v newuidmap` 无输出确认。
本机 rootless 容器因此不可实测（原理见 2.6）。

## 二、机制与实测

### 2.1 `uid_map` / `gid_map` 的规则

#### 格式与行数

- 每行三个十进制数字：内层起始、外层起始、长度；长度必须 > 0；
- Linux 4.14 及更早最多 5 行，4.15 起最多 340 行；整个写入必须一次完成、不能 `lseek` 到中间写；
- 区间之间**不能重叠**；至少写一行；格式错误 → `EINVAL`；
- 连续性：Linux 3.8 的早期实现要求两列数值逐行递增（因而隐含“连续/有序”），
  3.9 起只要求各区间不重叠，**不要求连续**（`来源：man 7 user_namespaces`）。

`来源：man 7 user_namespaces`（Defining user and group ID mappings 一节）。

#### 只能写一次

“After the creation of a new user namespace, the uid_map file ... may be written to **once**.
An attempt to write more than once ... fails with the error **EPERM**.”
（`来源：man 7 user_namespaces`）

这条规则是“映射一旦建立不可更改”的安全基础：容器运行时在启动阶段写完映射，
之后进程无法把 id 重新映射成别的宿主 uid。

#### 写入权限：两种模式

`来源：man 7 user_namespaces`（权限要求一节）：

1. 写入者要有目标 namespace 的 `CAP_SETUID`（gid_map 对应 `CAP_SETGID`）；
2. 写入者必须在该 namespace 或它的父 namespace 中；
3. **有父 namespace 的 `CAP_SETUID`**：可以写任意映射（root 写多行）；
4. **没有父 namespace 的 `CAP_SETUID`**（普通用户）：只能写**一行**，且必须把
   “写入者在父 namespace 的 euid”映射到子 namespace 的某个 uid；
5. 映射 uid 0（父 namespace）时额外要求 `CAP_SETFCAP`（Linux 5.12+，防 namespaced file cap 提权）；
6. 写 `gid_map` 前必须先把 `setgroups` 置为 `deny`（否则 `EPERM`）。

这就是为什么普通用户 `unshare -Ur` 只能得到“一个 uid”的映射，而 root 或 `newuidmap`
可以写多行。

#### `setgroups` 的 deny

`/proc/PID/setgroups` 有两个值：

- `allow`：该 namespace 内允许 `setgroups(2)`（初始 namespace 默认）；
- `deny`：永久禁止该 namespace 内调用 `setgroups(2)`。

写 `deny` 必须在写 `gid_map` **之前**，且一旦 `gid_map` 已写、就不能再改回 `deny`
（`来源：man 7 user_namespaces`，The /proc/pid/setgroups file 一节）。
本机的两个 namespace 都是 `deny`：

```text
$ cat /proc/self/setgroups
deny
$ unshare -Ur sh -c 'cat /proc/self/setgroups; id'
deny
uid=0(root) gid=0(root) 组=0(root),65534(nogroup)
```

验证：上述宿主命令。`deny` 是为了防止“先映射 gid，再用 setgroups 加入宿主组”的越权路径。

#### 未映射 uid = 溢出 uid（65534）

当内核要把一个 kuid 显示给某个 namespace 的进程、但该 kuid **不在映射表里**时，
显示为 **65534（`nobody`/`nogroup`）**。`来源：man 7 user_namespaces`；
本机 `/etc/passwd` 中 `nobody:x:65534:65534:...`（`来源：/etc/passwd`）。

最直观的实测（宿主，进入 `unshare -Ur`）：

```text
$ unshare -Ur sh -c 'ls -ldn "$HOME" /etc/shadow'
-rw-r----- 1 65534 65534 1150 ... /etc/shadow
drwx------ 39     0     0 4096 ... (家目录)
```

验证：上述宿主命令。`/etc/shadow` 的 kuid 0（宿主 root）不在本会话的映射里 → 65534；
家目录的 kuid 1000 映射进了新 namespace → 显示 0。

### 2.2 创建 user namespace

#### `unshare -U` 与 `unshare -r`

```text
# 1) 只建 userns，不写映射
$ unshare -U id
uid=65534(nobody) gid=65534(nogroup) 组=65534(nogroup)

$ unshare -U sh -c 'cat /proc/self/uid_map; grep -E "^(Uid|CapEff|CapBnd)" /proc/self/status'
Uid:	65534	65534	65534	65534
CapEff:	0000000000000000
CapBnd:	000001ffffffffff

# 2) -r：把当前 euid 映射成内层 0（util-linux 的 --map-root-user）
$ unshare -Ur id
uid=0(root) gid=0(root) 组=0(root),65534(nogroup)
$ unshare -Ur sh -c 'cat /proc/self/uid_map; cat /proc/self/setgroups; grep -E "^(Uid|CapEff|CapBnd)" /proc/self/status'
         0       1000          1
deny
Uid:	0	0	0	0
CapEff:	000001ffffffffff
CapBnd:	000001ffffffffff
```

验证：上述宿主命令。两个关键差异：

1. `unshare -U` 不写映射时，`cat /proc/self/uid_map` 没有输出（文件为空），进程 euid 是溢出 uid 65534，
   `CapEff=0`——因为随后 exec 的 `sh` 在新 namespace 里不是 uid 0、文件也没有 cap，
   exec 的 capability 重算把 P/E 清空了（04 章 2.2）；
2. `-r` 写了 `0 1000 1`，进程在新 namespace 里是 uid 0，`CapEff` 变成
   **`000001ffffffffff`**——新 namespace 内的全部 capability（相对该 namespace）。

`CapEff` 的 `1ffffffffff` 是 41 个 cap（bit 0~40）全 1
（`cat /proc/sys/kernel/cap_last_cap` 输出 `40`，即最高 bit 为 40）；但这份“全 capability”**只在这个
namespace 内有效**：对宿主文件仍然受限（2.3 实测读 `/etc/shadow` 失败）。

#### 为什么 `setpriv --reuid=1` 会 EINVAL

```text
$ unshare -Ur sh -c 'setpriv --reuid=1 id'
setpriv: setresuid failed: 无效的参数
```

验证：上述宿主命令。因为 `uid_map` 只有 `0 1000 1` 一行，内层 **uid 1 没有映射**；
内核无法把内层 1 翻译成任何父 namespace uid，`setresuid` 返回 `EINVAL`。
这是“容器里 `-u 1234` 显示 65534、要切到该 uid 时 EINVAL”的同一机制：镜像里有 `/etc/passwd` 记录不代表 uid 被映射（2.2、2.4 实测）。

#### 多行映射与 `newuidmap`

普通用户写多行映射需要 `newuidmap/newgidmap` 辅助（setuid root 的小工具，按 `/etc/subuid`
授权）。util-linux 的 `unshare --map-users` 也会调用它：

```text
$ unshare --map-users 0:1000:1 --user id
unshare: failed to execute newuidmap: 没有那个文件或目录
```

验证：上述宿主命令。`/etc/subuid` 的 `demo:100000:65536` 表示“允许 `newuidmap` 把
demo 的 65536 个 subuid 映射给容器”。装了 `uidmap` 包之后，
`newuidmap <pid> 0 100000 65536` 这样的多行/区间映射才成立。本机未安装，**多行映射未验证**，
只验证了单行映射（`unshare -Ur`）与“缺 helper 时失败”。

#### rootless 容器需要什么

要跑 rootless Docker/Podman，至少需要：

1. 内核支持非特权 userns（本机 `kernel.unprivileged_userns_clone=1`；本会话所在 userns
   也证明内核允许嵌套）；
2. `newuidmap`/`newgidmap` + `/etc/subuid`、`/etc/subgid` 有足够区间；
3. 可用的 cgroup v2 委托（rootless 需要）；
4. 端口：< 1024 需要 `net.ipv4.ip_unprivileged_port_start` 或 rootless 的端口转发。

本机缺第 2 项、也未配置 rootless，**未实测**；第 1 项的 sysctl 实测：

```text
$ cat /proc/sys/kernel/unprivileged_userns_clone
1
```

验证：上述宿主命令（Debian 13 默认允许非特权 userns）。

### 2.3 嵌套 userns 与“相对的 root”

#### 嵌套：每层都要映射

```text
$ unshare -Ur unshare -Ur sh -c 'cat /proc/self/uid_map; id; grep -E "^CapEff" /proc/self/status'
         0          0          1
uid=0(root) gid=0(root) 组=0(root),65534(nogroup)
CapEff:	000001ffffffffff
```

验证：上述宿主命令。内层 namespace 的映射是 `0 0 1`（内层 0 映射到父 namespace 的 0）；
在父 namespace 里 0 又映射到宿主的 1000。所以内层 root 的真实 kuid 仍是 1000。

`来源：man 7 user_namespaces`：user namespace 可以嵌套，Linux 3.11+ 最多 32 层。

#### 内层 root 的“全部 capability”只对本 namespace 有效

权限边界（man 7 user_namespaces，Effect of capabilities within a user namespace）：
**在某个 userns 里有 capability，只能对“该 namespace 管辖的资源”行使特权**。

实测：`unshare -Ur` 里 `CapEff` 全 1，但读宿主 root 文件仍然失败：

```text
$ unshare -Ur sh -c 'cat /etc/shadow'
cat: /etc/shadow: 权限不够
```

验证：上述宿主命令。`/etc/shadow` 的 kuid 0 不在本会话的映射里，内层 uid 0 的 kuid 是 1000，
既不是文件属主、也没有 `CAP_DAC_OVERRIDE`（该 cap 只在本 userns 内有效）→ `EACCES`。

#### 文件属主看 kuid 是否被映射

“在 userns 里看到的文件属主”= 把 inode 的 kuid 按当前映射“反译”成数字；
翻译不了就显示 65534。所以同一文件在不同 namespace 里显示不同属主：

| 文件（宿主 kuid） | 当前会话（映射 1000↔0，嵌套） | `unshare -Ur` 内层 |
|---|---|---|
| 家目录（kuid 1000） | 1000（`ls -ld` 显示 demo） | **0**（`ls -ldn`） |
| `/etc/shadow`（kuid 0） | **65534** | **65534** |
| 容器内 `touch` 的文件（kuid 0） | 65534（本会话视角） | — |

实测：

```text
$ ls -ln /etc/shadow
-rw-r----- 1 65534 65534 1150 ... /etc/shadow
$ unshare -Ur sh -c 'ls -ldn "$HOME"; ls -ln /etc/shadow'
drwx------ 39 0 0 4096 ... (家目录)
-rw-r-----  1 65534 65534 1150 ... /etc/shadow
```

验证：上述宿主命令。

#### 在 userns 里创建文件：宿主看到什么

```text
# 宿主：进入 userns 后以“内层 uid 0”创建文件
$ unshare -Ur sh -c 'echo hi > .tmp/userns-created.txt; ls -ln .tmp/userns-created.txt'
-rw-rw-r-- 1 0 0 3 ... .tmp/userns-created.txt
# 退出后回到宿主视角
$ ls -ln .tmp/userns-created.txt
-rw-rw-r-- 1 1000 1000 3 ... .tmp/userns-created.txt
```

验证：上述宿主命令。内核把内层 uid 0 翻译回 kuid 1000 再写 inode，
所以宿主上属主是当前用户，而不是 root。

同样地，`chown` 到未映射的 uid 会失败：

```text
$ unshare -Ur sh -c 'touch .tmp/own.txt; chown 1 .tmp/own.txt'
chown: 更改 '.tmp/own.txt' 的所有者: 无效的参数
```

验证：上述宿主命令。内层 uid 1 没有映射 → `EINVAL`（与 2.2 的 `setuid 1` 同因）。

### 2.4 怎么观测

#### `/proc/PID/uid_map` 的“读者视角”

同一个 `uid_map` 文件，不同 namespace 的进程读到的第二列含义不同（`来源：man 7 user_namespaces`）：

- 读自己 namespace 的 `uid_map` 时，第二列是**父 namespace** 的 uid；
- 读别的 namespace 的 `uid_map` 时，第二列是**读取者所在 namespace** 的 uid。

本会话的 `/proc/self/uid_map` 是 `1000 0 1`：本会话内 uid 1000 ↔ 父 namespace 的 uid 0。
`lsns` 显示 PID 1 是 Bubblewrap（`bwrap`），说明本会话运行在它创建的嵌套 userns 里：

```text
$ cat /proc/self/uid_map
      1000          0          1
$ lsns -t user -o NS,TYPE,PID,USER,COMMAND | head -3
        NS TYPE  PID USER   COMMAND
4026532976 user    1 demo bwrap --ro-bind / / --dev /dev --unshare-pid ...
```

验证：上述宿主命令。`bwrap` 那行说明 PID 1 就是沙箱本身；本会话的 `uid_map`
因此是“相对 bwrap 的父 namespace”的映射，而不是直接对初始 namespace。

尝试用 `NS_GET_PARENT` ioctl 向上读父 namespace 会失败（权限不足，`EPERM`）：

```text
$ python3 - <<'PY'
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open('/proc/self/ns/user', os.O_RDONLY)
print('NS_GET_PARENT ->', libc.ioctl(fd, 0xb702, 0), 'errno=', ctypes.get_errno())
PY
NS_GET_PARENT -> -1 errno= 1
```

验证：上述宿主片段（`errno=1` 即 `EPERM`）。所以本会话**只验证到直接父层**，
更上层的映射链未逐层核对（标注未验证）。

#### `/proc/PID/status` 的 `NSpid`

`NSpid` 只有在 PID namespace 有嵌套时才多列。本机：

```text
$ grep -E '^(NSpid|Uid)' /proc/self/status
Uid:	1000	1000	1000	1000
NSpid:	6
```

验证：上述宿主命令。单列说明本会话在 PID 维度只看到一层（bwrap 只 unshare 了 pid 与 user，
当前 `ps` 里 PID 1 是 bwrap）。

#### 容器内外的 uid 对照

容器内（rootful，无 userns-remap）：

```text
# 容器内
$ id
uid=0(root) gid=0(root) groups=0(root)
$ cat /proc/self/uid_map
         0          0 4294967295
$ cat /proc/self/gid_map
         0          0 4294967295
$ cat /proc/self/setgroups
allow
$ ls -ln /etc/shadow
-rw-r----- 1 0 42 474 ... /etc/shadow
```

验证：`docker run --rm debian:13 sh -c 'id; cat /proc/self/uid_map; cat /proc/self/gid_map; cat /proc/self/setgroups; ls -ln /etc/shadow'`。
`0 0 4294967295` 是初始 namespace 的“恒等映射”（长度为 32 位无符号最大值，
留出 `(uid_t)-1` 不可用），所以容器内 uid == 宿主 uid。

容器内创建文件，两侧视角：

```text
# 容器内（root）
$ touch /w/croot.txt; ls -ln /w/croot.txt
-rw-r--r-- 1 0 0 0 ... /w/croot.txt
# 本会话宿主视角（沙箱自身在 userns 里，root 未映射）
$ ls -ln .tmp/out/croot.txt
-rw-r--r-- 1 65534 65534 0 ... .tmp/out/croot.txt

# 容器内 -u 1000
$ docker run --rm -u 1000:1000 -v "$PWD/.tmp/out":/w debian:13 sh -c 'touch /w/u1000.txt; ls -ln /w/u1000.txt'
-rw-r--r-- 1 1000 1000 0 ... /w/u1000.txt
$ ls -ln .tmp/out/u1000.txt
-rw-r--r-- 1 1000 1000 0 ... .tmp/out/u1000.txt
```

验证：上述容器内命令与宿主 `ls -ln`。`-u 1000` 时容器 uid 1000 直接等于宿主 uid 1000
（无 userns 映射），所以宿主上属主就是 demo；容器 root 创建的文件在**真实宿主**上属主是
uid 0（root），本会话因为自己也在 userns 里，看到的是 65534（与基线 §2 一致）。

这也解释了 07 章的卷属主问题：rootful 容器里“我是 root”在宿主上就是“uid 0”，
而宿主普通用户看到的是 65534（本会话视角）或直接无权访问（初始 namespace 视角属主是 root）。

#### ns 文件与 `lsns`

```text
$ readlink /proc/self/ns/user /proc/self/ns/mnt /proc/self/ns/pid /proc/self/ns/net
user:[4026532976]
mnt:[4026532666]
pid:[4026532974]
net:[4026531840]
```

验证：上述宿主命令。inode 号相同的进程属于同一个 namespace；
`lsns -t user` 可以列出本机能看到的 user namespace（受权限与 `/proc` 可见性限制）。

### 2.5 与其他 namespace 的关系

非特权用户不能**单独**创建 mount/pid/net 等 namespace；但可以先建 userns、
在 userns 里拥有 `CAP_SYS_ADMIN`，再创建其他 namespace。实测：

```text
# 单独创建：失败
$ unshare -m true
unshare: unshare failed: 不允许的操作
$ unshare -n true
unshare: unshare failed: 不允许的操作
$ unshare -p --fork true
unshare: unshare failed: 不允许的操作

# 先 userns 再创建：成功（挂载点用仓库内临时目录）
$ unshare -Ur -m sh -c 'mount -t tmpfs none .tmp/mnt && echo mounted'
mounted
$ unshare -Ur -n sh -c 'ip -o link show | head -1'
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN mode DEFAULT ...
$ unshare -Ur -p --fork --mount-proc sh -c 'echo pid=$$; ps -o pid,cmd -p 1'
pid=1
    PID CMD
      1 sh -c echo pid=$$; ...
```

验证：上述宿主命令（`-Ur -m` 要求挂载点是已存在且可写的目录；这里用仓库内 `.tmp/mnt`）。
这正是“非特权容器”的实现方式：先拥有一个 userns，才有资格创建其他 namespace。

注意 `unshare -Ur -n` 得到的网络 namespace 只有 `lo`，没有宿主网卡——网络隔离也是从零开始。

### 2.6 容器引擎的三种 uid 模式

| 模式 | `uid_map`（容器内） | 容器 uid 1000 在宿主上是 | 配置位置 |
|---|---|---|---|
| rootful 默认（无 userns） | `0 0 4294967295` | uid 1000 | 默认 |
| `--userns=host` | 同上（显式指定宿主 userns） | uid 1000 | `docker run --userns=host` |
| userns-remap（daemon 级） | 如 `0 100000 65536` | subuid（如 101000） | `/etc/docker/daemon.json` + dockremap 用户 |
| rootless docker / podman | 类似 remap，但由用户自己的 subuid 授权 | subuid | rootless 安装 + newuidmap |

本机 Docker 29.8.1 实测：

```text
$ docker run --rm --userns=host debian:13 sh -c 'id; cat /proc/self/uid_map'
uid=0(root) gid=0(root) groups=0(root)
         0          0 4294967295

$ docker run --rm --userns=private debian:13 id
docker: --userns: invalid USER mode
```

验证：上述两条 `docker run`。本机 daemon **未启用 userns-remap**：

```text
$ docker info --format '{{json .SecurityOptions}}'
["name=apparmor,profile=default","name=seccomp,profile=builtin","name=cgroupns"]
$ cat /etc/docker/daemon.json
{
  "registry-mirrors": ["https://mirror.example.com"]
}
```

验证：上述宿主命令。SecurityOptions 里没有 `name=userns`，daemon.json 也没有 `userns-remap`。

userns-remap 的配置片段（**本机未启用，未验证**）：

```json
{
  "userns-remap": "default"
}
```

启用后 Docker 会创建 `dockremap` 用户并在 `/etc/subuid`、`/etc/subgid` 中分配区间，
容器内 uid 0 映射到该区间的第一个数字；此时容器 root 写宿主绑定目录会得到
“uid 不对/不可写”，需要 `chown` 到 subuid 或改用命名卷。`来源：Docker 官方文档`
（本机无法重启 daemon 验证，标注未验证）。

容器内再嵌套 userns 也受限：Docker 默认 seccomp + 缺少 `CAP_SYS_ADMIN`，所以：

```text
$ docker run --rm debian:13 unshare -Ur id
unshare: unshare failed: Operation not permitted
```

验证：上述容器内命令。对比宿主上同样的 `unshare -Ur` 成功，说明“能不能建 userns”
还取决于外层的 seccomp/capability 配置。

#### idmapped mounts（一句话定位）

userns 解决“进程 uid 的翻译”，**idmapped mounts** 解决“同一份文件系统内容按不同映射呈现”。
本机 util-linux 2.41 的 `mount` 已列出 `--map-users/--map-groups/--map-users /proc/<pid>/ns/user`：

```text
$ mount --help | grep -E 'map-users|map-groups'
     --map-groups <inner>:<outer>:<count>
     --map-users <inner>:<outer>:<count>
     --map-users /proc/<pid>/ns/user
```

验证：上述宿主命令（`mount from util-linux 2.41.5`）。
它需要 root/CAP_SYS_ADMIN 才能实际创建，本机**未实测**；容器 runtime 用它解决
“卷里的 uid 与容器内 uid 不一致”的问题（Docker 目前需要额外配置，07 章有讨论）。

## 三、动手验证

本章对应的实验：[labs/03-userns-subuid](../labs/03-userns-subuid/)（宿主可跑：`uid_map`、CapEff、
未映射 uid EINVAL、嵌套 userns、65534）。

10 条命令，按“宿主 → 容器”排列：

```bash
# 1) 进入 userns 并观察 uid_map / setgroups / CapEff
unshare -Ur sh -c 'cat /proc/self/uid_map; cat /proc/self/setgroups; grep -E "^(Uid|CapEff)" /proc/self/status'

# 2) 不写映射的 userns：uid 变 65534、CapEff 为 0（uid_map 为空）
unshare -U id; unshare -U sh -c 'cat /proc/self/uid_map; grep -E "^(Uid|CapEff)" /proc/self/status'

# 3) 未映射 uid 不能切：EINVAL
unshare -Ur sh -c 'setpriv --reuid=1 id'

# 4) 文件属主按映射反译：家目录显示 0，/etc/shadow 显示 65534
unshare -Ur sh -c 'ls -ldn "$HOME"; ls -ln /etc/shadow'

# 5) 嵌套 userns：映射 0 0 1
unshare -Ur unshare -Ur sh -c 'cat /proc/self/uid_map; id'

# 6) userns 里创建文件，宿主属主仍是自己
unshare -Ur sh -c 'echo x > .tmp/u.txt'; ls -ln .tmp/u.txt

# 7) userns 内 root 也读不了宿主 root 文件
unshare -Ur cat /etc/shadow

# 8) 非特权用户单独建 mount/net/pid namespace 失败，先 userns 后成功
unshare -m true; unshare -Ur -m sh -c 'mount -t tmpfs none .tmp/mnt && echo mounted'

# 9) 容器 rootful：uid_map 是恒等映射，容器 root 文件在宿主是 0（真实宿主）/65534（本会话视角）
docker run --rm debian:13 sh -c 'id; cat /proc/self/uid_map; cat /proc/self/setgroups'
docker run --rm -v "$PWD/.tmp/out":/w debian:13 sh -c 'touch /w/rootfile; ls -ln /w/rootfile'

# 10) 容器 -u 1000：无 userns 时容器 uid == 宿主 uid
docker run --rm -u 1000:1000 -v "$PWD/.tmp/out":/w debian:13 sh -c 'id; touch /w/u1000.txt'
```

宿主能做什么 / 容器里能做什么：

| 观察点 | 宿主 | 容器 |
|---|---|---|
| `unshare -Ur`、单 uid 映射 | ✅ | 默认 ❌（seccomp/无 SYS_ADMIN，2.6 实测） |
| 未映射 uid → 65534 | ✅ | ❌（默认恒等映射，无 65534） |
| 嵌套 userns | ✅ | ❌（默认） |
| 容器 uid_map / 容器 root=宿主 root | ❌（看不到容器 init 的 `/proc/<pid>`，本会话 PID ns 隔离） | ✅ |
| userns-remap / rootless | ❌（需改 daemon） | — |

## 四、常见误解

❌ 「容器里的 root 就是宿主机的 root。」 → ✅ rootful 默认没有 userns，容器 uid 0 **确实**是宿主 uid 0（`uid_map` 为 `0 0 4294967295`，2.4 实测）；但启用 userns-remap/rootless 后容器 root 会被映射到 subuid，两者不再等价（2.6，本机未启用 remap）。

❌ 「`unshare -Ur` 里我是 root，就能读宿主 `/etc/shadow`。」 → ✅ 内层 root 的 `CapEff` 虽全 1，但只对本 userns 有效；宿主 root 文件 kuid 0 未映射时仍 `EACCES`（2.3 实测）。

❌ 「`-u 1000` 就是 rootless 容器。」 → ✅ `-u 1000` 只是指定容器进程的 uid；rootful 无 userns 时它等于宿主 uid 1000，与“rootless”无关（2.4 实测：宿主属主就是 1000）。

❌ 「uid_map 可以随时改，映射错了重新写一次就行。」 → ✅ 每个 userns 的 `uid_map` **只能写一次**，再写返回 `EPERM`（2.1，`来源：man 7 user_namespaces`）；改映射只能重建 namespace。

❌ 「容器里看不到某个 uid 的用户，说明这个 uid 不存在。」 → ✅ 只是当前 namespace 的映射看不到；内核 kuid 存在、只是显示为溢出 uid 65534（2.1、2.3 实测）。

❌ 「userns 能防住所有容器逃逸。」 → ✅ userns 是一个隔离层，但仍受内核漏洞、`CAP_SYS_ADMIN` 配置、挂载/设备暴露影响；它降低“容器 root = 宿主 root”的风险，不等于安全边界完整（本机没有攻防实验，属原则性结论）。

❌ 「`unshare -m` 普通用户也能用。」 → ✅ 单独创建 mount namespace 需要 `CAP_SYS_ADMIN`；先建 userns 才能以该 userns 内的 SYS_ADMIN 创建（2.5 实测）。

## 五、速查表

| 命令 / 配置 | 作用 | 现象 / 判读 |
|---|---|---|
| `unshare -Ur id` | 建 userns 并把当前用户映射成内层 root | `uid=0`，`uid_map=0 1000 1` |
| `unshare -U sh -c "id; grep CapEff /proc/self/status"` | 只建 userns 不写映射 | `uid=65534`、`CapEff=0` |
| `cat /proc/PID/uid_map` | 看映射：内层、外层、长度 | 未映射 uid → 65534 |
| `cat /proc/PID/setgroups` | 看能否 `setgroups` | `deny` = 已禁止 |
| `ls -ln` | 按数字看属主 | 65534 = 溢出 uid |
| `unshare -Ur setpriv --reuid=1 id` | 验证未映射 uid | `EINVAL` |
| `unshare -Ur -m` / `-n` / `-p` | userns 里建其他 ns | 成功；单独 `unshare -m` 失败 |
| `readlink /proc/self/ns/user` | 看 namespace inode | 同 inode = 同 namespace |
| `lsns -t user` | 列出 user namespace | 受 `/proc` 可见性限制 |
| `cat /etc/subuid` | 看 subuid 区间 | 多行映射的授权来源 |
| `docker run --userns=host` | 用宿主 userns（无映射） | `uid_map=0 0 4294967295` |
| `docker run -u 1000:1000` | 指定 uid | rootful 下 = 宿主 1000 |
| `docker info` / `daemon.json` | 看是否启用 userns-remap | SecurityOptions 无 userns |
| `mount --map-users` | idmapped mount | 本机工具支持，未实测 |

## 六、延伸阅读

- 本章实验：[labs/03-userns-subuid](../labs/03-userns-subuid/)（宿主可跑）、[labs/05-docker-uid](../labs/05-docker-uid/)（容器 uid 对照）
- 相邻章节：[01-权限模型全景](01-权限模型全景.md)、[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、
  [05-提权与降权机制](05-提权与降权机制.md)、[07-Docker用户与权限实战](07-Docker用户与权限实战.md)（卷属主与 rootless）、
  [09-权限排障手册](09-权限排障手册.md)（65534/权限拒绝的排查）
- man 页：`man 7 user_namespaces`、`man 1 unshare`、`man 1 nsenter`、`man 2 setns`、`man 8 mount`
  （本机未安装这些手册页；内容在 `debian:13` 容器内安装 `manpages` 后核对）
