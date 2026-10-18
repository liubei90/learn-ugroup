# 03 文件权限与 ACL：mode、umask、特殊位与访问控制列表

> **一句话总结**：把 12 位 mode、umask、SUID/SGID/sticky、chattr 与 ACL 讲成一套可观测、可计算的规则。

> **本机验证**：✅ 宿主大部分可验证（ext4 支持 ACL、可用 `getfacl/setfacl`）＋ ⚠️ 跨用户实验、`chattr +i/+a`、SUID 提权效果需 `debian:13` 容器；`/home` 是 `nosuid`，宿主上的 SUID 位只用于观察不用于提权。

| 项目 | 内容 |
|---|---|
| 回答的问题 | `ls -l` 那串 `-rwsr-xr-x` 每一位是什么？为什么目录少一个 `x` 就全挂？umask 怎么算出 644/755？ACL 给了权限为什么还是 `Permission denied`？ |
| 适合读者 | 会 `chmod 777` 但解释不清结果的人；被「目录 755 文件 644 却打不开」「ACL 加了不生效」困住的人 |
| 前置阅读 | [01-权限模型全景](01-权限模型全景.md)、[02-用户与组数据库](02-用户与组数据库.md) |
| 主要来源 | `man 2 chmod`、`man 2 chown`、`man 2 open`、`man 2 mkdir`、`man 2 unlink`、`man 2 execve`、`man 5 acl`、`man 1 setfacl`、`man 1 getfacl`、`man 1 chattr`、`man 7 inode` |

## 一、先建立直觉

### 1.1 这一章在全局模型中的位置

权限判断需要两边信息：进程带着哪些数字（[04-进程凭证与权限检查](04-进程凭证与权限检查.md)），资源上写了什么规则（本章）。资源侧由三部分组成：

```text
inode
├── 属主 uid、属组 gid        ← 数字，来自 02 的数据库
├── mode（12 位）             ← 本章 2.1–2.6
│   ├── 4 个特殊位：SUID / SGID / sticky
│   └── 9 个权限位：user / group / other × rwx
├── ACL（可选扩展属性）        ← 本章 2.7
└── 扩展属性（chattr 标志）    ← 本章 2.6
```

图：本章负责「inode 上写了什么规则」，进程侧怎么比较留给 04。两者合起来才解释一条 `Permission denied`。

### 1.2 十二位 mode

`ls -l` 的第一列是 10 个字符，但 inode 里实际存的是 **12 个权限位**：4 个特殊位 + 9 个权限位。用 `stat` 看八进制最清楚（宿主实测）：

```bash
touch m; chmod 4755 m
stat -c 'mode=%a hex=%f type=%F' m
python3 -c 'print(oct(0x89ed))'
```

```text
mode=4755 hex=89ed type=regular empty file
0o104755
```

`%f` 是包含文件类型位的完整 mode：`0o104755` 的低 12 位 `04755` 才是权限（`4` 是 SUID，`755` 是 rwxr-xr-x）。12 个位的位置：

| 位（八进制） | 名称 | 对文件 | 对目录 |
|---|---|---|---|
| `04000` | setuid 位 | `execve` 后 euid = 文件属主 | 在 Linux 上被忽略 |
| `02000` | setgid 位 | `execve` 后 egid = 文件属组 | 新建条目继承目录属组，且目录自身保持 setgid |
| `01000` | sticky 位 | 普通文件上没有可依赖的语义 | 只有文件属主/目录属主/root 能删改条目 |
| `00400` | user r | 读内容 | 列目录名 |
| `00200` | user w | 改内容 | 在目录里创建/删除/改名（还需 x） |
| `00100` | user x | 执行 | 进入/穿过目录（每级都要） |
| `00040/00020/00010` | group r/w/x | 同上，匹配属组或辅助组 | 同上 |
| `00004/00002/00001` | other r/w/x | 同上，兜底 | 同上 |

### 1.3 三个观察面：`ls`、`stat`、`chmod`/`getfacl`

- `ls -l` 给人看：`-rwsr-xr-x`、`drwxrwsr-x`、`drwxrwxrwt`。
- `stat -c '%a %A %U:%G %n'` 给脚本看：八进制、符号、属主属组。
- `chmod` 写权限位；`getfacl/setfacl` 读写 ACL；`chattr/lsattr` 读写扩展属性（本课关注 `+i/+a`）。

### 1.4 匹配只发生一次：属主 → 属组 → other

内核检查一个操作时，先看进程的 fsuid 是否等于文件属主 uid；是就用 user 三位，**不再看** group/other。不是则看进程的 fsgid 或辅助组是否命中文件属组：命中用 group 三位，否则用 other 三位。

```text
操作请求（比如 open(O_RDONLY)）
        │
        ├─ fsuid == inode.uid ?  → 用 user 位判定（结束）
        ├─ fsgid/辅助组 ⊇ inode.gid ? → 用 group 位判定（结束）
        └─ 否则 → 用 other 位判定
```

这解释了两个常见「玄学」：把文件 owner 改成自己后，group 位写得再宽也没用；用户在同一文件上既属属主又属属组时，按属主位判定，不会取两边的并集。

### 1.5 rwx 对**文件**与**目录**的语义完全不同

| 位 | 文件 | 目录 |
|---|---|---|
| `r` | 读取文件内容（`open`/`read`） | 列出目录项名字（`ls`，需 `readdir`） |
| `w` | 修改文件内容（`write`/`truncate`） | 创建、删除、重命名目录项（**还需要 x**） |
| `x` | 作为程序执行（`execve`） | 进入并穿过目录（路径解析的每一级都要） |
| 组合 | `r` 无 `x` 可读不可执行 | 有 `r` 无 `x` 能列名字但打不开文件；有 `x` 无 `r` 能打开已知名字但不能列目录 |

这张表是本章最值钱的东西。第 2.2 节用跨用户实测把四行分别钉死。

### 1.6 本章边界

- 进程怎么拿到 fsuid、内核 `inode_permission` 怎么走，见 [04-进程凭证与权限检查](04-进程凭证与权限检查.md)。
- SUID/file capability 作为**提权机制**的完整分析见 [05-提权与降权机制](05-提权与降权机制.md)；本章只讲 mode 位上的语义。
- 用户命名空间下的 uid 映射见 [06-命名空间与uid映射](06-命名空间与uid映射.md)。
- Docker/Nginx 场景见 07、08 两章；排障索引见 [09-权限排障手册](09-权限排障手册.md)。

## 二、机制与实测

### 2.1 观测 mode：`ls -l`、`stat`、特殊位显示

宿主一次性造出全部特殊位组合（`chmod` 后立刻 `stat`）：

```bash
mkdir -p bits && cd bits
for t in 4755 2775 1777 4644 2644 1644 6711 7777; do touch "b$t"; chmod "$t" "b$t"; done
stat -c '%a %A %n' b*
```

```text
1644 -rw-r--r-T b1644
1777 -rwxrwxrwt b1777
2644 -rw-r-Sr-- b2644
2775 -rwxrwsr-x b2775
4644 -rwSr--r-- b4644
4755 -rwsr-xr-x b4755
6711 -rws--s--x b6711
7777 -rwsrwsrwt b7777
```

`ls -l` 的 `s/S/t/T` 解读表：

| 显示 | 含义 | 例子 |
|---|---|---|
| `s`（小写，user 位） | setuid 位已设，且属主有 x | `-rwsr-xr-x`（4755） |
| `S`（大写，user 位） | setuid 位已设，但属主无 x | `-rwSr--r--`（4644） |
| `s`（小写，group 位） | setgid 位已设，且属组有 x | `-rwxrwsr-x`（2775） |
| `S`（大写，group 位） | setgid 位已设，但属组无 x | `-rw-r-Sr--`（2644） |
| `t`（小写，other 位） | sticky 位已设，且 other 有 x | `drwxrwxrwt`（1777） |
| `T`（大写，other 位） | sticky 位已设，但 other 无 x | `-rw-r--r-T`（1644） |

记忆法：**大写 = 有特殊位但没有对应的执行位**；`ls` 用大小写区分「这个位能不能真正发挥作用」。

### 2.2 目录的 `r`、`w`、`x` 是三件独立的事

宿主先看「目录缺 x」的单用户版本（属主自己也会被拦）：

```bash
mkdir nosearch; echo data > nosearch/f; chmod 600 nosearch
cat nosearch/f
chmod 700 nosearch; cat nosearch/f
```

```text
cat: nosearch/f: 权限不够
data
```

跨用户的 `r` 与 `x` 分离，在容器内用 bob 访问 root 的目录实测：

```bash
mkdir -p /srv/rx; echo known > /srv/rx/known.txt; chmod 711 /srv/rx
su bob -c 'ls /srv/rx'                 # 只有 x，没有 r
su bob -c 'cat /srv/rx/known.txt'
chmod 744 /srv/rx
su bob -c 'ls /srv/rx'                 # 只有 r，没有 x
su bob -c 'cat /srv/rx/known.txt'
```

```text
ls: cannot open directory '/srv/rx': Permission denied
known
known.txt
cat: /srv/rx/known.txt: Permission denied
```

- `711`（`drwx--x--x`）：bob 能穿过目录、打开**已知文件名**，但不能列目录。
- `744`（`drwxr--r--`）：bob 能列名字，但没有 x 无法进入，拿到文件名也打不开。

**目录 `w` 单独存在也不够。** 删除/创建目录项需要 `w+x`：

```bash
mkdir -p /srv/wnoexec; touch /srv/wnoexec/f; chown -R bob:bob /srv/wnoexec; chmod 200 /srv/wnoexec
su bob -c 'rm -f /srv/wnoexec/f'; echo "bob rm rc=$?"
su bob -c 'echo x > /srv/wnoexec/g'; echo "bob create rc=$?"
```

```text
200 d-w------- bob
rm: cannot remove '/srv/wnoexec/f': Permission denied
bob rm rc=1
bash: line 1: /srv/wnoexec/g: Permission denied
bob create rc=1
```

**路径上每一级目录都要 x。** `/srv/one` 是 700 root，`/srv/one/two` 是 755：

```bash
su bob -c 'cat /srv/one/two/f'; echo "bob cat rc=$?"
cat /srv/one/two/f; echo "root cat rc=$?"
```

```text
cat: /srv/one/two/f: Permission denied
bob cat rc=1
top
root cat rc=0
```

root 能读不是「uid 0 魔法」，而是容器 root 持有 `CAP_DAC_OVERRIDE`（验证：容器内 `grep '^CapEff' /proc/self/status` → `00000000a80427fb`，该位就是 bit 1）。capability 的语义见 [05-提权与降权机制](05-提权与降权机制.md)。

定位路径权限问题用 `namei -l`（宿主实测）：

```bash
mkdir -p np/one/two; touch np/one/two/f; chmod 700 np/one
namei -l np/one/two/f
```

```text
f: np/one/two/f
drwxrwxr-x demo demo np
drwx------ demo demo one
drwxrwxr-x demo demo two
-rw-rw-r-- demo demo f
```

所以，遇到「文件是 644 却打不开」时看这里：用 `namei -l` 从 `/` 开始看每一级目录的 x。

### 2.3 umask：新文件 666、新目录 777 的来源

创建文件的系统调用传入「期望模式」，内核再减去 umask：普通文件 `open(..., 0666)`，目录 `mkdir(..., 0777)`（来源：`man 2 open`、`man 2 mkdir`，两者都写明 `mode & ~umask`）。公式：

```text
新文件权限 = 0666 & ~umask
新目录权限 = 0777 & ~umask
```

宿主三种 umask 的实测矩阵：

```bash
for u in 022 077 002; do
  d="um$u"; mkdir -p "$d"; ( cd "$d"; umask $u; touch f; mkdir sub; stat -c "umask=$u %a %A %n" f sub )
done
```

```text
umask=022 644 -rw-r--r-- f
umask=022 755 drwxr-xr-x sub
umask=077 600 -rw------- f
umask=077 700 drwx------ sub
umask=002 664 -rw-rw-r-- f
umask=002 775 drwxrwxr-x sub
```

对照公式：`0666 & ~022 = 0644`、`0777 & ~022 = 0755`；`~077` 得 `700`；`~002` 得 `664/775`。**注意是「减」不是「加」**：umask 里的 1 表示「禁止」。

umask 的来源（本机实测）：

| 场景 | umask | 来源 |
|---|---|---|
| 宿主交互登录用户 demo | `0002` | 验证：宿主 `umask`；`/etc/pam.d/common-session` 有 `pam_umask.so` |
| 容器内 root | `0022` | 验证：容器内 `umask` |
| 容器内 `su - alice`（uid==gid 的私有组） | `0002` | 验证：容器内 `su - alice -c umask` |

`pam_umask` 的 `usergroups` 行为解释了为什么私有用户组用户的 umask 从 022 变成 002（来源：`man 8 pam_umask`）：

```text
If the user is not root and the username is the same as primary group
name, the umask group bits are set to be the same as owner bits
(examples: 022 -> 002, 077 -> 007).
```

`/etc/login.defs` 里本机**没有** `UMASK` 项（验证：宿主 `grep -n UMASK /etc/login.defs` 无输出），所以默认值来自 PAM/工具内置默认，改动要落在 PAM 或 shell 配置，不要只改 login.defs。

几个「指定模式」的命令与 umask 的关系：

```bash
mkdir -m 750 md; stat -c '%a %A (mkdir -m 750)' md
install -m 640 /dev/null inst; stat -c '%a %A (install -m 640)' inst
```

```text
750 drwxr-x--- (mkdir -m 750)
640 -rw-r----- (install -m 640)
```

`mkdir -m` 与 `install -m` 给的是**最终模式**，不受 umask 影响（`来源：man 1 mkdir`、`man 1 install`）。而 `cp` 的模式来自源文件（并受 umask 影响），`cp -p` 才原样保留（`来源：man 1 cp`；容器内实测，源文件 666）：

```bash
su alice -c 'umask 022; cp /srv/cpd/src.txt /srv/cpd/copy1.txt'
su alice -c 'umask 077; cp /srv/cpd/src.txt /srv/cpd/copy2.txt'
su alice -c 'umask 022; cp -p /srv/cpd/src.txt /srv/cpd/copy3.txt'
stat -c '%a %A %n' /srv/cpd/src.txt /srv/cpd/copy1.txt /srv/cpd/copy2.txt /srv/cpd/copy3.txt
```

```text
666 -rw-rw-rw- /srv/cpd/src.txt
644 -rw-r--r-- /srv/cpd/copy1.txt
600 -rw------- /srv/cpd/copy2.txt
666 -rw-rw-rw- /srv/cpd/copy3.txt
```

所以，遇到「脚本生成的文件权限不对」时看这里：先看进程 umask（`umask`、`/proc/PID/status` 的 `Umask`），再看程序是 `open(0666)`、`mkdir(0777)` 还是显式 `chmod`。

### 2.4 chmod：符号、八进制、`X`、`--reference` 与递归陷阱

宿主实测：

```bash
touch s1 s2; chmod 640 s1
chmod u+x,g-w,o= s1; stat -c '%a %A %n' s1
mkdir -p dirx; chmod 644 dirx; chmod a+X dirx; stat -c '%a %A %n (目录 a+X)' dirx
chmod --reference=s1 s2; stat -c '%a %A %n (--reference)' s2
```

```text
740 -rwxr----- s1
755 drwxr-xr-x (目录 a+X)
740 -rwxr----- (--reference) s2
```

`X` 只在「目录」或「本来就有某个 x 位」时加执行位；对 644 的普通文件执行 `chmod a+X` 仍是 644（宿主实测）：

```text
644 -rw-r--r-- nox
```

符号模式也支持先设特殊位，宿主实测：

```text
chmod u+s → 4664 -rwSrw-r--
chmod g+s → 6664 -rwSrwSr--
chmod o+t → 7664 -rwSrwSr-T
chmod a=  → 0 ----------
```

**递归陷阱**：`chmod -R` 会先改父目录的 mode。若把目录的执行位一起去掉，命令在遍历子项时就会被自己拦住：

```bash
mkdir -p tree/a/b; touch tree/a/b/file
chmod -R 600 tree
stat -c '%a %A %n' tree
ls tree/a/b
```

```text
chmod: 无法访问 'tree/a': 权限不够
600 drw------- tree
ls: 无法访问 'tree/a/b': 权限不够
```

正确的递归姿势是先保证目录可进入、再收紧文件，并利用 `X`：

```bash
chmod -R a+rX tree2
stat -c '%a %n' tree2 tree2/a tree2/a/b tree2/a/b/f
```

```text
775 tree2
775 tree2/a
775 tree2/a/b
664 tree2/a/b/f
```

所以，遇到「`chmod -R 777` 是万能修复」「递归后目录进不去」时看这里：先想清楚目录需要 `x`，再决定用 `X` 还是显式分两步。

### 2.5 特殊位：SUID、SGID、sticky

#### SUID：可执行文件的 euid 变成属主

`uidinfo` 是 [labs/04-setuid-caps](../labs/04-setuid-caps/) 里的 `src/uidinfo.c` 编译出的静态探针（打印 ruid/euid/suid 与 gid），lab 的 `run.sh` 会用 `gcc -static` 编译它。下文假设已把它编译到当前目录 `./uidinfo`。

容器内把该程序装成 root 属主 + 4755，以 alice 运行：

```bash
cp ./uidinfo /usr/local/bin/uidinfo
chown root:root /usr/local/bin/uidinfo
chmod 4755 /usr/local/bin/uidinfo
su alice -c '/usr/local/bin/uidinfo'
```

```text
-rwsr-xr-x 1 root root 758608 Oct 18 01:41 /usr/local/bin/uidinfo
real=1000 effective=0 saved=0 | gid real=1000 eff=1000 saved=1000
read /root/secret.txt: OK -> root-secret
```

`real=1000 effective=0 saved=0` 是 SUID 的核心：真实 uid 仍是 alice，有效 uid 变成文件属主 root，保存的 uid 也是 0。执行 `passwd`、`su`、`mount` 就靠这套。提权的完整机制见 [05-提权与降权机制](05-提权与降权机制.md)。

**SUID 对脚本无效。** 同样 chmod 4755 的 shell 脚本被执行时 euid 不变：

```bash
cat > /srv/script.sh <<'EOF'
#!/bin/bash
id
EOF
chown root:root /srv/script.sh
chmod 4755 /srv/script.sh
ls -l /srv/script.sh
su alice -c /srv/script.sh
```

```text
-rwsr-xr-x 1 root root 15 Oct 18 01:54 /srv/script.sh
uid=1000(alice) gid=1000(alice) groups=1000(alice)
```

对照同为 4755 的 ELF 程序（`/srv/uidinfo`），euid 变成 0。原因：`execve` 对 `#!` 脚本会以解释器重新执行（来源：`man 2 execve` 的 “interpreter” 说明），`setuid` 位不参与这条执行路径的凭证计算，因此不能靠给脚本加 SUID 提权。

**`nosuid` 挂载会让 SUID 位静默失效。** 容器内用两个 tmpfs 对照（一个显式 `nosuid`，一个 `suid,dev,exec`）：

```text
/mnt   tmpfs  rw,nosuid,nodev,relatime,size=16384k,mode=755,inode64
/mnt2  tmpfs  rw,relatime,size=16384k,inode64
```

```text
--- /mnt（nosuid）:
real=1000 effective=1000 saved=1000 | ...
--- /mnt2（suid,dev,exec）:
real=1000 effective=0 saved=0 | ...
```

宿主当前工作区所在的 `/home` 挂载就带 `nosuid`（验证：宿主 `findmnt -T . -o OPTIONS`）：

```text
OPTIONS
rw,nosuid,nodev,relatime,errors=remount-ro
```

所以本课在宿主只观察 SUID 位，真正的提权实验放容器根文件系统（`/usr/local/bin`）。注意：容器把宿主目录 bind mount 进来时，实测该挂载**没有**继承 `nosuid`（`findmnt -T /w` 的 OPTIONS 里没有 nosuid，SUID 程序仍生效）——不要用容器里的 bind mount 论证宿主挂载行为。

**`chown` 会清掉 SUID/SGID 位**（`man 2 chown`：自 Linux 2.2.13 起 root 的 chown 也按普通用户处理）：

```bash
cp ./uidinfo /usr/local/bin/uidinfo2
chmod 6755 /usr/local/bin/uidinfo2
stat -c '%a %A (chown 前)' /usr/local/bin/uidinfo2
chown alice:alice /usr/local/bin/uidinfo2
stat -c '%a %A (chown 后)' /usr/local/bin/uidinfo2
```

```text
6755 -rwsr-sr-x (chown 前)
755 -rwxr-xr-x (chown 后)
```

#### SGID：文件继承属组，目录继承属组

**SGID 文件**：可执行文件被运行时，egid 变成文件属组。容器内 `/usr/local/bin/uidinfo-sgid` 属组 `devs`、模式 2755：

```text
-rwxr-sr-x 1 root devs 758608 ... /usr/local/bin/uidinfo-sgid
real=1000 effective=1000 saved=1000 | gid real=1000 eff=2000 saved=2000
```

**SGID 目录**：目录内新建文件的属组自动继承目录属组，并且新子目录继续带 setgid 位：

```bash
mkdir -p /srv/shared; chgrp devs /srv/shared; chmod 2775 /srv/shared
su alice -c 'echo alice > /srv/shared/a.txt'
su bob   -c 'echo bob   > /srv/shared/b.txt'
ls -ln /srv/shared
ls -ld /srv/shared
```

```text
-rw-rw-r-- 1 1000 2000 6 Oct 18 01:41 a.txt
-rw-rw-r-- 1 1001 2000 4 Oct 18 01:41 b.txt
drwxrwsr-x 2 root devs 4096 Oct 18 01:41 /srv/shared
```

alice 与 bob 的主组各自是 1000/1001，但文件的属组都是 2000(`devs`)——这就是共享目录配 SGID 的原因。

#### sticky：目录里的「只能删自己的」

容器内 1777 的目录里，bob 删 alice 的文件被拒：

```text
drwxrwxrwt 2 root root 4096 Oct 18 01:41 /srv/sticky
rm: cannot remove '/srv/sticky/a.txt': Operation not permitted
bob 删 alice 文件 rc=1
alice 删自己文件 rc=0
```

sticky 的规则（来源：`man 2 unlink` 的 restricted deletion flag）：目录带 sticky 时，删除/改名目录项只允许文件属主、目录属主或 root。生产机的 `/tmp` 通常是 1777，就是为了让所有用户能建文件、但不能互删；容器内实测：

```text
1777 drwxrwxrwt root:root /tmp
```

本会话沙箱例外：`/tmp` 是私有 tmpfs、模式 755（验证：宿主 `stat -c '%a %A' /tmp` → `755 drwxr-xr-x`），这恰好演示了「不要假设每台机器的 `/tmp` 都是 1777」。

所以，遇到「共享目录里我能建文件却删不了别人的」时看这里：这不是 bug，是 sticky 或目录属主限制。

### 2.6 扩展属性：`chattr +i` / `+a` 和权限位不是一回事

`chattr` 改的是文件系统扩展属性，root 也不能绕过（与 DAC 权限不同）。宿主缺 `CAP_LINUX_IMMUTABLE`，所以只能在容器里做（基线 §4）：

宿主实测（失败是预期）：

```text
chattr: 不允许的操作 while setting flags on imm
--------------e------- imm
```

容器内 `--cap-add LINUX_IMMUTABLE` 实测：

```bash
touch /srv/imm; chattr +i /srv/imm; lsattr /srv/imm
echo x > /srv/imm; rm -f /srv/imm
chattr -i /srv/imm; rm -f /srv/imm
touch /srv/app; chattr +a /srv/app
echo appended >> /srv/app
echo trunc > /srv/app
lsattr /srv/app; cat /srv/app
```

```text
----i---------e------- /srv/imm
写 immutable 文件 rc=1
删除 immutable 文件 rc=1
chattr -i 后删除 rc=0
追加 append-only rc=0
O_TRUNC 覆盖 append-only rc=1
-----a--------e------- /srv/app
appended
```

两个关键区别：

- `+i`：不可写、不可删、不可改名，连 root 也不行（要 `chattr -i` 才能解除）。
- `+a`：只能追加，不能覆盖（`O_TRUNC` 被拒），也不能删除。

`+i` 还会让 `chmod` 失败（容器内实测 `chmod: changing permissions of '/srv/app': Operation not permitted`），而单纯 `chmod 000` 只挡普通用户，root 仍能写（容器内实测 root 写 000 文件 rc=0）。**排障时看到 `Operation not permitted` 而非 `Permission denied`，要想到 `lsattr`。**

### 2.7 ACL：mask、`#effective`、default ACL 与备份恢复

ACL 是 mode 的扩展：在不改属主/属组/other 的情况下，给额外用户或组授权。本机 ext4 支持（基线 §3.3），宿主可用 `getfacl/setfacl`，但只能操作 `u:1000/demo`（本会话 userns 只映射 1000，写未映射 uid 会报 `setfacl: 无效的参数`，基线 §3.3）。

#### ACL 的结构与 mask

宿主实测：

```bash
echo hi > acl1; setfacl -m u:1000:r acl1; getfacl -p acl1
```

```text
# file: acl1
# owner: demo
# group: demo
user::rw-
user:demo:r--
group::rw-
mask::rw-
other::r--
```

多出来的三行是 ACL 条目：`user:demo:r--` 是命名用户条目，`mask::rw-` 是**命名条目与 group:: 的上限**（掩码）。`getfacl` 显示的 `#effective:` 是「条目权限 ∩ mask」的结果。

**有 ACL 之后，`chmod` 的 group 位改的是 mask，不是 group::**（宿主实测）：

```bash
chmod 640 acl1; getfacl -p acl1
chmod 600 acl1; getfacl -p acl1
```

```text
--- chmod 640 之后:
user::rw-
user:demo:r--	#effective:r--
group::rw-	#effective:r--
mask::r--
other::---

--- chmod 600 之后:
user::rw-
user:demo:r--	#effective:---
group::rw-	#effective:---
mask::---
other::---
```

这就是「ACL 给了却无效」的最常见原因：命名的 `u:x:rwx` 还在，但 mask 被 `chmod 600` 压成 `---`，实际生效权限是空。**修法是调 mask（`setfacl -m m::rwx` 或 `chmod g+rwx`），不是反复加 ACL 条目。**

容器内验证 mask 对写入的影响：

```bash
echo base > /srv/team.txt; chmod 660 /srv/team.txt; setfacl -m u:bob:rw /srv/team.txt
chmod 640 /srv/team.txt        # 把 mask 压成 r--
su bob -c 'echo x >> /srv/team.txt'; echo "bob 追加 rc=$?"
chmod g+w /srv/team.txt        # mask 恢复 rw-
su bob -c 'echo x >> /srv/team.txt'; echo "bob 追加 rc=$?"
```

```text
user:bob:rw-	#effective:r--
mask::r--
bash: line 1: /srv/team.txt: Permission denied
bob 追加 rc=1
user:bob:rw-
mask::rw-
bob 追加 rc=0
```

#### 目录 ACL 与 x 位

ACL 里的 `r` 同样不等于「能读目录里的文件」——还要 `x`。容器内：

```text
setfacl -m u:bob:r-- /srv/acl → bob ls rc=0，bob cat rc=1（Permission denied）
setfacl -m u:bob:r-x /srv/acl → bob cat rc=0（data）
```

#### default ACL：新建文件的继承

给目录设 default ACL 后，新建文件继承这些条目，但**新建时的 mode 仍受 umask/`open` 模式约束**，最终以 mask 与 `#effective` 呈现（宿主实测）：

```bash
setfacl -d -m u:1000:rwx acldir; setfacl -m u:1000:rwx acldir
touch acldir/newfile; getfacl -p acldir/newfile
```

```text
user:demo:rwx   #effective:rw-
mask::rw-
```

容器内同样能看到 default ACL 同时影响目录与文件（`/srv/drop`，default 给 bob rwx）：

```text
# file: /srv/drop/alice.txt
user::rw-
user:bob:rwx	#effective:rw-
group::rwx	#effective:rw-
mask::rw-
other::---
```

`alice.txt` 的 user:: 是 `rw-`（`open(0666)` + umask），所以即使 default ACL 里给 bob 的是 `rwx`，实际 effective 也只到 `rw-`。

#### 删除条目、删默认 ACL、备份恢复

宿主实测：

```bash
setfacl -x u:1000 acls/a.txt      # -x 删指定条目
setfacl -b acls/a.txt             # -b 删所有扩展 ACL
setfacl -k acls                  # -k 只删 default ACL
getfacl -R -p acls > acl.bak      # 备份
setfacl --restore=acl.bak         # 恢复
```

```text
--- -x u:1000 之后:
user::rw-
group::rw-
group:demo:r-x
mask::rwx
other::r--

--- -b 之后:
user::rw-
group::rw-
other::r--
```

备份文件就是 `getfacl` 输出本身（含 `# file:` 路径注释，`-p` 保证路径为绝对/调用时形式）；`setfacl --restore=acl.bak` 按文件里的路径恢复。注意 `-b` 会连 default ACL 一起清（容器内 `setfacl -b /srv/drop` 后 `getfacl` 不再显示 `default:` 行）。

典型共享目录配方（把「组内协作 + 不给外人」一次配好）：

```bash
mkdir -p /srv/project
chgrp devs /srv/project
chmod 2770 /srv/project
setfacl -m g:devs:rwx /srv/project
setfacl -d -m g:devs:rwx /srv/project
setfacl -d -m o::- /srv/project
```

含义：SGID 保证新文件属组是 `devs`，default ACL 保证新条目继续带 `devs rwx`，`o::-` 兜底禁止其他人。验证方式：新建文件后 `getfacl -p` 应能看到 `default:` 与 `#effective:` 行。

所以，遇到「ACL 加了不生效」时看这里：先看 `mask`/`#effective`，再看目录 `x`，最后看 default ACL 是否只对**新建**文件生效。

### 2.8 新文件的属主与属组从哪来

新建 inode 时，属主取进程的 fsuid，属组取进程的 fsgid 或父目录的组——取决于是否 SGID：

| 场景 | 属主 | 属组 |
|---|---|---|
| 普通目录里 `touch` | 进程 fsuid | 进程 fsgid（通常是主组或当前组） |
| SGID 目录里 `touch` | 进程 fsuid | **父目录的属组**（2.5 实测 devs） |
| `chown user:group file` | 指定用户（需 CAP_CHOWN） | 指定组（需在用户组集合内） |
| `cp -p` | 默认调用者；root 可保留源属主 | 默认调用者主组；root 可保留 |
| `install -o -g -m` | 可显式指定 | 可显式指定 |

`chown` 的副作用：会清掉 SUID/SGID（2.5 实测 6755→755）。`chown -R` 与 `chmod -R` 一样有遍历风险，且会把整个目录树交给新属主，这是课程禁止随手执行的危险操作之一。

所以，遇到「docker 卷里文件属主不对」「cp 之后属主变了」时看这里：看父目录是否 SGID、命令是否 `-p`、以及进程 fsuid/fsgid（04）。

### 2.9 本章之外的其他关卡

即使 mode 与 ACL 都允许，以下关卡在对应条件下仍会拒绝：

| 关卡 | 表现 | 详见 |
|---|---|---|
| 挂载选项 `nosuid/nodev/noexec` | SUID 失效、不能执行、不能建设备节点 | 本章 2.5，[04-进程凭证与权限检查](04-进程凭证与权限检查.md) |
| 只读挂载 `ro` | `EROFS`（`Read-only file system`） | 05、09 |
| LSM（AppArmor/SELinux） | 日志里出现 `DENIED`，`ls -l` 完全正常 | [09-权限排障手册](09-权限排障手册.md) |
| 文件系统配额 | `EDQUOT` | 本课不展开 |
| Landlock | 进程自我限制，报错同样 `EACCES` | [04-进程凭证与权限检查](04-进程凭证与权限检查.md) |

## 三、动手验证

### 3.1 宿主上可跑的命令（10 条）

```bash
umask
mkdir -p .tmp-03 && cd .tmp-03 && umask 022 && touch f && mkdir d && stat -c '%a %A %n' f d
stat -c '%a %f' /etc/passwd
touch m; chmod 4755 m; stat -c '%a %A' m
mkdir s; chmod 2775 s; stat -c '%a %A' s
touch t; chmod 1777 t; stat -c '%a %A' t
mkdir nosearch2; echo data > nosearch2/f; chmod 600 nosearch2; cat nosearch2/f; chmod 700 nosearch2; cat nosearch2/f
namei -l /usr/bin/passwd
touch acl-demo; setfacl -m u:demo:r acl-demo; getfacl -p acl-demo; chmod 600 acl-demo; getfacl -p acl-demo
chattr +i acl-demo; lsattr acl-demo
cd .. && rm -rf .tmp-03
```

每条要看什么：

1. `umask` 在当前会话的值，以及 `0666 & ~umask` 的结果。
2. `stat %a %f` 的八进制与十六进制对照，理解 `%f` 含类型位。
3. `4755`/`2775`/`1777` 的 `ls -l` 显示与 2.1 的表对应。
4. 目录 600 时属主自己也读不了文件；700 立刻恢复。
5. `namei -l` 逐级列出路径上每级目录的权限，是排查 403/EACCES 的第一条命令。
6. `setfacl` 后 `chmod 600` 会压 mask，`#effective:---` 是「ACL 有了但不生效」的直接证据。
7. 宿主 `chattr +i` 会因缺 `CAP_LINUX_IMMUTABLE` 失败（预期），对应容器实验。

### 3.2 容器内做跨用户与 root 实验

> 需要：docker / 网络（apt 装 acl、attr、e2fsprogs、libcap2-bin）

```bash
docker run --rm --name learnugroup-03-$$ --cap-add LINUX_IMMUTABLE -v "$PWD":/w debian:13 bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends acl attr e2fsprogs libcap2-bin >/dev/null 2>&1
  groupadd -g 2000 devs
  useradd -m -u 1000 -s /bin/bash alice
  useradd -m -u 1001 -s /bin/bash bob
  usermod -aG devs alice; usermod -aG devs bob
  mkdir -p /srv/shared; chgrp devs /srv/shared; chmod 2775 /srv/shared
  su alice -c "echo alice > /srv/shared/a.txt"
  su bob -c "echo bob > /srv/shared/b.txt"
  ls -ln /srv/shared
  mkdir -p /srv/sticky; chmod 1777 /srv/sticky
  su alice -c "echo a > /srv/sticky/a.txt"
  su bob -c "rm -f /srv/sticky/a.txt" || echo "sticky 生效: bob 删不掉"
  mkdir -p /srv/rx; echo known > /srv/rx/known.txt; chmod 711 /srv/rx
  su bob -c "ls /srv/rx" || echo "无 r: 不能列目录"
  su bob -c "cat /srv/rx/known.txt"
  setfacl -m u:bob:r /srv/rx; setfacl -m m::r /srv/rx
  getfacl -p /srv/rx
  touch /srv/imm; chattr +i /srv/imm; echo x > /srv/imm || echo "immutable 拒绝写入"
  chattr -i /srv/imm
'
```

在容器内要看的点：

- `ls -ln /srv/shared` 两行的属组都是 `2000`（SGID 目录）。
- bob 删 alice 文件报 `Operation not permitted`（sticky）。
- `/srv/rx` 是 711：bob `ls` 失败但 `cat` 已知文件成功。
- `getfacl` 里 `user:bob:r--` 与 `mask::r--` 同时出现，`#effective` 说明生效权限。
- `chattr +i` 后写文件失败，而 `chmod` 无法改 `ls -l` 之外的属性。

### 3.3 本章对应的 lab

- [labs/01-permission-model](../labs/01-permission-model/)：umask 矩阵、SUID/SGID/sticky 的 `stat` 显示、目录缺 x、已打开 fd 与 `chmod 000`、`/home` 的 `nosuid`。
- [labs/02-acl](../labs/02-acl/)：`setfacl/getfacl`、mask 与 `#effective`、chmod 改 mask、default ACL 继承、`-b/-k`、`getfacl -R` 备份与恢复、可选跨 uid 读取。
- [labs/04-setuid-caps](../labs/04-setuid-caps/)：SUID 程序 euid、`no_new_privs`、file capability。
- [labs/07-drills](../labs/07-drills/)：600 文件 EACCES、目录缺 x、sticky 删除等排障演练。

本机边界：

- 宿主 `/home` 是 `nosuid`，SUID 提权在宿主无效；宿主也没有 root 与 `setcap`，SUID/capability 实验一律进容器。
- 宿主 ACL 只能写 `u:1000/demo`，写未映射 uid（如 65534）会 `setfacl: 无效的参数`；跨 uid 的 ACL 演示用容器。
- `chattr +i/+a` 需要 `CAP_LINUX_IMMUTABLE`，宿主没有，容器需显式 `--cap-add LINUX_IMMUTABLE`（这是本课唯一使用 `--cap-add` 的地方）。

## 四、常见误解

1. ❌ `chmod 777` 能解决权限问题 → ✅ 它只放宽 DAC；目录缺 x、挂载 `nosuid/noexec`、ACL mask、LSM 都会在对应条件下继续拒绝（验证：2.2 目录 600、2.5 nosuid、2.7 mask）。
2. ❌ 目录 0777 无所谓 → ✅ 目录 w 让任何人能删/改名目录项，配合 sticky 才安全；容器内 `/tmp` 是 `1777` 而不是 `0777`（验证：容器内 `stat -c '%a %A' /tmp`；宿主本会话 `/tmp` 为 755，见 2.5）。
3. ❌ ACL 加了条目就生效 → ✅ 还要看 `mask` 与 `#effective`；`chmod 600` 会把 mask 压成 `---`（验证：2.7 宿主实测）。
4. ❌ `chmod 000` 会立刻断掉正在读文件的进程 → ✅ 权限在 `open()` 时检查一次；已打开的 fd 仍可读（宿主实测：`chmod 000` 后旧 fd 读出 `payload`，重新打开报 `Permission denied`；机制见 04）。
5. ❌ SUID 脚本能提权 → ✅ SHELL 脚本的 setuid 位不生效，euid 保持调用者（验证：2.5 脚本 `-rwsr-xr-x` 但执行后 `uid=1000(alice)`）。
6. ❌ 文件有 r 就能读 → ✅ 路径上每一级目录都要 x（验证：2.2 `/srv/one` 700 时 bob 读不到其中 644 文件）。
7. ❌ root 是「uid 0 魔法」 → ✅ root 能绕过 DAC 是因为持 `CAP_DAC_OVERRIDE`（容器内 `CapEff=00000000a80427fb`）；`chattr +i` 这类扩展属性 root 也绕不过（验证：2.6）。
8. ❌ 递归 `chmod -R 777` 是最快的修复 → ✅ 先把目录 x 补回来，再用 `X`/显式模式收紧；直接 `-R 600` 会让命令自己无法遍历（验证：2.4 递归陷阱）。
9. ❌ `ls -l` 显示 `s` 就一定提权 → ✅ 还要求所在挂载没有 `nosuid`、文件系统支持 SUID；本机 `/home` 的 SUID 位在宿主上不生效（验证：2.5 与 `findmnt`）。

## 五、速查表

| 想看什么 | 命令 | 现象/结论 |
|---|---|---|
| 八进制/符号 mode | `stat -c '%a %A' f` | 4755 / `-rwsr-xr-x` |
| 含类型位 mode | `stat -c '%f' f` | 0o104755 形式 |
| 递归看路径权限 | `namei -l /a/b/c` | 每级目录的 mode |
| 当前 umask | `umask` | 本机宿主 0002 |
| 新文件/目录预期权限 | `0666 & ~umask` / `0777 & ~umask` | 实用 `umask 022` → 644/755 |
| 精确模式 | `mkdir -m 750 d`、`install -m 640 src dst` | 不受 umask 影响 |
| 只给目录加 x | `chmod -R a+rX dir` | 文件不乱加 x |
| SUID/SGID/sticky | `chmod 4755/2775/1777 f` | 用 `ls -l` 看 `s/S/t/T` |
| 挂载是否 nosuid | `findmnt -T /path -o OPTIONS` | 本机 `/home` 带 nosuid |
| 扩展属性 | `lsattr f`、`chattr +i/+a f` | `i` 不可改、`a` 只可追加 |
| 看 ACL | `getfacl -p f` | mask 与 `#effective` |
| 加命名用户 | `setfacl -m u:bob:rw f` | 记得 mask |
| 改 mask | `setfacl -m m::rwx f` 或 `chmod g+rwx f` | 有 ACL 时 chmod 改 mask |
| 默认 ACL | `setfacl -d -m u:bob:rwx dir` | 只影响新建条目 |
| 删 ACL | `setfacl -x u:bob f` / `-b` / `-k dir` | 删条目/全部/默认 |
| 备份恢复 | `getfacl -R -p d > acl.txt`；`setfacl --restore=acl.txt` | 文本即备份 |
| 新文件属组 | `ls -ln`、父目录 SGID | SGID 目录继承组 |
| 共享目录配方 | `chgrp g d; chmod 2770 d; setfacl -d -m g:g:rwx d` | 组内协作 |
| 已打开 fd 是否受 chmod 影响 | 见 04 章的 fd 实验 | 不受影响 |

## 六、延伸阅读

- 本章 lab：[labs/01-permission-model](../labs/01-permission-model/)、[labs/02-acl](../labs/02-acl/)、[labs/04-setuid-caps](../labs/04-setuid-caps/)、[labs/07-drills](../labs/07-drills/)。
- 相邻章节：[01-权限模型全景](01-权限模型全景.md)、[02-用户与组数据库](02-用户与组数据库.md)、[04-进程凭证与权限检查](04-进程凭证与权限检查.md)、[05-提权与降权机制](05-提权与降权机制.md)、[06-命名空间与uid映射](06-命名空间与uid映射.md)、[07-Docker用户与权限实战](07-Docker用户与权限实战.md)、[08-Nginx用户与权限实战](08-Nginx用户与权限实战.md)、[09-权限排障手册](09-权限排障手册.md)、[10-账户安全基线与审计](10-账户安全基线与审计.md)。
- man 页：`man 2 chmod`、`man 2 chown`、`man 2 open`、`man 2 mkdir`、`man 2 unlink`、`man 2 execve`、`man 5 acl`、`man 1 setfacl`、`man 1 getfacl`、`man 1 chattr`、`man 1 lsattr`、`man 7 inode`、`man 8 mount`、`man 8 pam_umask`。
- 本机文件：`/etc/fstab`、`/proc/mounts`、`/etc/pam.d/common-session`、`/etc/login.defs`。
