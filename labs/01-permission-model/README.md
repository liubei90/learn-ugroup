# labs/01 · 权限模型动手实验

> **一句话总结**：用 15 条断言把「进程凭证 × 文件模式 × 目录 x 位」在宿主上固定成可重复的观察。

> **本机验证**：✅ 全部可在宿主完成，不需要 root、docker 或网络（Debian 13 / Linux 6.12 实测，15 条断言全过）。

| 项目 | 内容 |
|---|---|
| 演示现象 | 进程凭证字段；umask 022/077/002 矩阵；SUID/SGID/sticky 显示；目录缺 x 位；已打开 fd；`nosuid` 挂载 |
| 运行环境 | 宿主（普通用户），`bash` 5、coreutils（`stat`）、util-linux（`findmnt`）、`python3` |
| 预计耗时 | < 5 秒 |
| 对应章节 | [docs/01-权限模型全景](../../docs/01-权限模型全景.md)、[docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)、[docs/04-进程凭证与权限检查](../../docs/04-进程凭证与权限检查.md) |

## 一、这个 lab 演示什么

权限问题的三要素是**谁在访问（进程凭证）× 访问什么（inode 上的 mode/ACL）× 中间经过哪些目录**。
本 lab 用不依赖 root 的方式，把这三件事各固定成一个可断言的现象：

1. 进程侧：`id` 与 `/proc/self/status` 的 `Uid`/`Gid`/`CapEff`/`NoNewPrivs`；
2. 资源侧：`umask` 如何决定新建文件/目录的初始 mode；12 位 mode 中特殊位在 `ls -l` 里长什么样；
3. 检查侧：目录缺 `x` 位时连自己的文件都读不到；`open()` 通过后再 `chmod 000`，已打开的 fd 仍能读；
4. 边界侧：本机 `/home` 带 `nosuid`，所以 SUID 提权实验必须去容器里做（见 [labs/04](../04-setuid-caps/)）。

> 锚点：后文所有「权限不够」都能落回这张图——`进程凭证 → 路径逐级 x 位 → inode 的 rwx/ACL`。

## 二、前置条件

- Linux 宿主，普通用户即可；**不需要 root**、不需要 docker、不需要网络。
- 需要命令：`id`、`stat`、`findmnt`、`python3`（第 5 节按需，缺失会打印 `SKIP`）。
- 本机 `/home` 以 `nosuid,nodev` 挂载；若你的环境没有 `nosuid`，第 6 节断言会 `FAIL`，这是有意的环境检查。
- 脚本只在 `labs/01-permission-model/.tmp/` 下创建临时文件，退出时删除。

## 三、运行方式

```bash
cd labs/01-permission-model
bash run.sh
```

- 无交互、可重复运行；退出码 `0` 表示全部断言通过，`1` 表示有 `FAIL`。
- 每行以 `ok` / `FAIL` 开头，末行固定为 `PASS n / FAIL m`，便于质量门禁统计。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. 进程凭证：id 与 /proc/self/status ==
uid=1000(demo) gid=1000(demo) groups=1000(demo),65534(nogroup)
--- /proc/self/status 关键字段 ---
Uid:	1000	1000	1000	1000
Gid:	1000	1000	1000	1000
Groups:	65534 65534 65534 65534 65534 65534 65534 65534 65534 65534 65534 65534 65534 1000 
CapEff:	0000000000000000
CapBnd:	0000000000000000
NoNewPrivs:	1
ok   id -u 与 /proc/self/status 的 Uid 一致（1000）
ok   本会话存在 NoNewPrivs 字段（1）
本会话 CapEff=0000000000000000（沙箱内无 capability，root 才能绕过的检查在这里也会被拦）

== 2. umask 矩阵：022 / 077 / 002 ==
umask 022 -> 新文件 644，新目录 755
ok   umask 022 得到文件 644 / 目录 755
umask 077 -> 新文件 600，新目录 700
ok   umask 077 得到文件 600 / 目录 700
umask 002 -> 新文件 664，新目录 775
ok   umask 002 得到文件 664 / 目录 775

== 3. 特殊位在 ls/stat 中的显示 ==
chmod 4755 -> stat %a=4755  %A=-rwsr-xr-x
ok   mode 4755 显示为 -rwsr-xr-x
chmod 2775 -> stat %a=2775  %A=-rwxrwsr-x
ok   mode 2775 显示为 -rwxrwsr-x
chmod 1777 -> stat %a=1777  %A=-rwxrwxrwt
ok   mode 1777 显示为 -rwxrwxrwt
chmod 4644 -> stat %a=4644  %A=-rwSr--r--
ok   mode 4644 显示为 -rwSr--r--
chmod 2644 -> stat %a=2644  %A=-rw-r-Sr--
ok   mode 2644 显示为 -rw-r-Sr--

== 4. 目录缺 x 位：读里面的文件也会失败 ==
chmod 600 nosearch 后执行 cat nosearch/f：
ok   目录无 x 位导致读取失败：cat: /home/demo/code/learn-ugroup/labs/01-permission-model/.tmp/nosearch/f: Permission denied
chmod 700 nosearch 后执行 cat nosearch/f：
data
ok   补上 x 位后读取成功

== 5. 已打开的 fd 不再复查权限（python3） ==
fd-read=payload reopen=DENIED
ok   chmod 000 后，已打开 fd 仍可读，重新 open 被拒绝

== 6. 挂载选项：/home 的 nosuid ==
TARGET       SOURCE                                         FSTYPE OPTIONS
/home/demo /dev/mapper/demo--vg-root[/home/demo] ext4   rw,nosuid,nodev,relatime,errors=remount-ro
ok   本 lab 所在文件系统带 nosuid（rw,nosuid,nodev,relatime,errors=remount-ro）

== 7. 数值属主观察（ls -n / stat） ==
numeric: uid=1000 gid=1000 mode=664 name=/home/demo/code/learn-ugroup/labs/01-permission-model/.tmp/owned
-rw-rw-r-- 1 1000 1000 0 Oct 18 09:41 /home/demo/code/learn-ugroup/labs/01-permission-model/.tmp/owned
ok   自建文件数值属主等于当前 uid（1000）
宿主视角 /etc/shadow 的数值属主: 65534:65534（本会话根文件系统属主显示为 65534:65534）
当前 /proc/self/uid_map:
      1000          0          1

PASS 15 / FAIL 0
```

## 五、分步讲解

### 1. 进程凭证：先看「谁在访问」

- `id` 给出 ruid/euid 与组列表；`/proc/self/status` 的 `Uid:` 行给出 **real/effective/saved/fsuid** 四个值
  （来源：`man 5 proc` 的 `/proc/PID/status` 字段说明）。本机四者都是 `1000`。
- 本会话 `CapEff=0000000000000000`、`NoNewPrivs=1`：说明当前进程**没有任何 capability**，且不能再通过
  exec 获得新特权。于是「root 能绕过权限检查」的机制在这里不可用，后面的目录拒绝才能被观察出来。
- `Groups:` 行在本机出现大量重复的 `65534`，而 `id` 只显示 `1000` 与 `65534(nogroup)`——这是本机受限沙箱的
  组映射结果。判断组归属时应以 `id` / `getent group` 为准，不要只看这一个字段。
- 所以，遇到「我是属主为什么还打不开」时，先看这里：euid/caps 决定内核给不给你特权绕过。

### 2. umask：新建文件的初始 mode 从哪来

公式（来源：`man 2 umask`）：

```text
新文件 mode = 0666 & ~umask
新目录 mode = 0777 & ~umask
```

本 lab 的三行输出正好覆盖三种常见 umask：

| umask | 新文件 | 新目录 | 典型场景 |
|---|---|---|---|
| `022` | `644` | `755` | 系统默认、root 常用 |
| `077` | `600` | `700` | 私有文件 / 密钥 |
| `002` | `664` | `775` | 本机登录默认（`umask` 实测为 `0002`） |

注意：`umask` **只影响创建时刻**，不改变已有文件；它也不会「给」权限，只是从 666/777 里减掉。

### 3. 特殊位：`s`/`S`/`t`/`T` 怎么读

- `4755` → `-rwsr-xr-x`：setuid 位且属主有 x，显示小写 `s`；
- `4644` → `-rwSr--r--`：setuid 位但属主无 x，显示大写 `S`（位在、但对该文件没有执行意义）；
- `2775` → `-rwxrwsr-x`：SGID 位 + 组 x → `s`；`2644` → `-rw-r-Sr--` → `S`；
- `1777` → `-rwxrwxrwt`：sticky 位 + other x → `t`；若 other 无 x 则显示 `T`。

本节故意只对一个普通文件 `chmod 1777` 来观察 `t` 的**显示**；sticky 的**语义**（只有文件属主/目录属主/root
能删）只对目录有效，真实行为见 [labs/07](../07-drills/) 的场景 4。

### 4. 目录 x 位：路径上的每一级都要能「穿过」

`x` 对目录的含义是**搜索/遍历**（来源：`man 7 path_resolution`）。目录 mode `600` 时：

- 属主有 `r` 可以列出目录项，但没有 `x` 就无法把路径解析到目录内的 inode；
- 因此 `cat nosearch/f` 报 `Permission denied`，**即使 `f` 本身是 644 也没用**；
- 补 `chmod 700` 后立即可读。

关键细节：本机 `CapEff=0`，属主也无法像 root 那样用 `CAP_DAC_OVERRIDE` 绕过，所以这个拒绝是真实可观察的。

### 5. 已打开的 fd：权限只在 `open()` 时检查

Python 实验做了三件事：打开并写入 → `chmod 000` → ①从已打开 fd 读，②重新 `open()`：

- ①成功，读回 `payload`；
- ②失败，`Permission denied`。

原因是权限检查发生在 `open()` 路径上（来源：`man 2 open` 的权限检查说明），**已建立的 fd 不再复查**。
这解释了两类现象：守护进程被 `chmod 000` 后仍能写日志（fd 早就打开了）；以及 `/proc/PID/fd` 能读取
「按当前权限已经打不开」的文件——排查时别只看 `ls -l`，要看进程手里已经拿着什么。

### 6. `nosuid`：为什么本机 `/home` 上做不了 SUID 实验

`findmnt -T` 显示本 lab 所在文件系统选项为 `rw,nosuid,nodev,relatime,errors=remount-ro`。

- `nosuid` 让该挂载点上的 setuid/setgid 位**不生效**（来源：`man 8 mount` 的 `nosuid` 说明）；
- 所以宿主上即使造出 `4755` 文件也不会提权，SUID 的真实效果必须到 [labs/04](../04-setuid-caps/) 的容器
  overlayfs 上观察；
- `nodev` 同理会影响设备文件。看挂载选项是排查「为什么特殊位没效果」的第一步。

### 7. 数值属主与 uid_map：`65534` 不是「另一个用户」

- `ls -ln` / `stat -c %u` 直接给数字，避免 `ls -l` 把 uid 解析成名字时产生误判；
- 本会话 `/proc/self/uid_map` 为 `1000 0 1`，是一个嵌套用户命名空间的证据（详见
  [labs/03](../03-userns-subuid/)）；
- 本机根文件系统上的 root 属主（如 `/etc/shadow`）在本会话里显示为 `65534:65534`，这是**未映射 uid 的
  溢出显示**，不代表磁盘上真的有个 uid 65534 的用户。

## 六、清理

脚本用 `trap` 在退出时删除 `labs/01-permission-model/.tmp/`；不产生 root 属主文件，无需容器清理。
手动清理：

```bash
rm -rf labs/01-permission-model/.tmp
```

## 七、对应章节

- [docs/01-权限模型全景](../../docs/01-权限模型全景.md)：本 lab 的「凭证 × 资源 × 路径」总模型。
- [docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)：mode 12 位、umask、特殊位、目录 x 位。
- [docs/04-进程凭证与权限检查](../../docs/04-进程凭证与权限检查.md)：`/proc/PID/status`、已打开 fd 的检查语义。
- 下一步：[labs/02-acl](../02-acl/) 看 ACL 如何补充「只按属主/组/other 分」的不足。

## 八、延伸练习

1. **预测再验证**：把脚本第 2 节改成 `umask 027`，先手算新文件/新目录 mode，再运行确认
   （提示：`666 & ~027`、`777 & ~027`）。
2. **补全 `T` 的显示**：对一个文件执行 `chmod 1755`（sticky 位 + other 无 x），观察 `ls -l` 是否显示大写 `T`，
   再对比 `chmod 1777` 的小写 `t`。
3. **路径逐级检查**：用 `namei -l .tmp/nosearch/f`（或 `namei -l` 一个真实路径）查看每一级的 mode，
   人为去掉中间某一级的 `x`，解释报错位置。
