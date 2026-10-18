# labs/04 · SUID 与文件 capability 动手实验

> **一句话总结**：在同一台容器里对比 SUID、no_new_privs、file capability 三条提权/降权路径。

> **本机验证**：⚠️ 需要 docker + `debian:13` 镜像 + 宿主 gcc；capability 一节需要容器内 `apt` 装 `libcap2-bin`（网络），失败自动 `SKIP`。

| 项目 | 内容 |
|---|---|
| 演示现象 | 静态编译观察程序；`useradd alice`；SUID → euid 0；`no_new_privs` → SUID 失效；`cap_dac_override=ep` → 非 root 读 root 文件；`getcap`；`CapEff` 位 |
| 运行环境 | 宿主 gcc 编译 + `docker run --rm debian:13`；容器内 `apt-get install --no-install-recommends libcap2-bin` |
| 预计耗时 | 约 10 秒（含一次 apt） |
| 对应章节 | [docs/05-提权与降权机制](../../docs/05-提权与降权机制.md)、[docs/04-进程凭证与权限检查](../../docs/04-进程凭证与权限检查.md)、[docs/10-账户安全基线与审计](../../docs/10-账户安全基线与审计.md) |

## 一、这个 lab 演示什么

同一件事——「让普通用户 alice 读到 root 的 600 文件」——有两条完全不同的授权路径，外加一个开关把它们关掉：

1. **SUID**：root 属主 + `4755` 的程序，alice 执行后 euid=0、saved=0，能读 `/root/secret.txt`；
2. **no_new_privs**：`setpriv --no-new-privs` 之后 execve 忽略 SUID 位，euid 仍是 1000，读取被拒；
3. **file capability**：`setcap cap_dac_override=ep` 的程序，alice 执行时 euid 仍是 1000，
   但 `CapEff=0x2`，照样读得到 `600` 的 root 文件——这是比「SUID root」更小的授权。

宿主 gcc 只负责编译两个观察程序（静态链接，复制进容器即可运行）；所有特权操作都在一次性容器里做，
容器用 `--rm` + 唯一 `--name`，只挂载本 lab 目录。

## 二、前置条件

- 宿主：`gcc`（本机 Debian 13 支持 `-static`）、`docker`、本地已有 `debian:13` 镜像。
- 容器内：网络可用（`apt-get update` + `apt-get install libcap2-bin`）。**若 apt 失败**，脚本把 capability
  一节标记 `SKIP`，SUID / no_new_privs 断言仍照常执行，脚本以 0 退出。
- 安全边界：容器只用 `--rm --name learnugroup-04-setuid-caps-$$`；只挂载本 lab 目录；
  不使用 `--privileged`、不挂载 `/var/run/docker.sock`、不挂宿主根目录。
- 脚本退出时 `trap` 删除容器与 `.tmp/`，不产生 root 属主的宿主文件。

## 三、运行方式

```bash
cd labs/04-setuid-caps
bash run.sh
```

- 无交互、可重复；退出码 `0` 表示全部已执行断言通过，`1` 表示有 `FAIL`。
- 缺少 gcc / docker / 镜像、或静态编译失败时打印 `SKIP` 并退出 0。
- 每行以 `ok` / `FAIL` / `SKIP` 开头，末行固定为 `PASS n / FAIL m`。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. 检查依赖 ==
ok   宿主 gcc 可用（gcc (Debian 14.2.0-19) 14.2.0）
ok   docker 可用且本地存在 debian:13 镜像

== 2. 宿主 gcc 静态编译两个观察程序 ==
/home/demo/code/learn-ugroup/labs/04-setuid-caps/.tmp/bin/uidinfo: ELF 64-bit LSB executable, x86-64, version 1 (GNU/Linux), statically linked, BuildID[sha1]=eff3b830f8c191667468ef6b2db5cc09586dbee4, for GNU/Linux 3.2.0, not stripped
/home/demo/code/learn-ugroup/labs/04-setuid-caps/.tmp/bin/capread: ELF 64-bit LSB executable, x86-64, version 1 (GNU/Linux), statically linked, BuildID[sha1]=40d7827709c42e490fd06e9a3b51a9d4ece3f823, for GNU/Linux 3.2.0, not stripped
ok   两个程序均静态编译成功

== 3. 容器内：useradd alice、放 SUID 程序、跑 no_new_privs、装 libcap2-bin ==
--- 容器内身份
uid=0(root) gid=0(root) groups=0(root)
USER 1000 alice
--- SUID 文件的 ls -l
-rwsr-xr-x 1 root root 793880 Oct 18 01:44 /usr/local/bin/uidinfo
--- SUID 运行（alice 执行 root 属主程序）
SUID real=1000 effective=0 saved=0 | gid real=1000 eff=1000 saved=1000
SUID read /root/secret.txt: OK -> TOP-SECRET
--- no_new_privs 运行
NNP real=1000 effective=1000 saved=1000 | gid real=1000 eff=1000 saved=1000
NNP read /root/secret.txt: DENIED (euid=1000)
--- file capability 部分
GETCAP /usr/local/bin/capread cap_dac_override=ep
CAP uid=1000 euid=1000 CapEff= 0000000000000002
CAP read /root/secret.txt: OK -> TOP-SECRET
APTX ok
ok   容器内脚本正常结束
ok   容器内已创建 alice（uid=1000）
ok   SUID 程序权限位为 -rwsr-xr-x（root 属主）
ok   SUID 执行后 euid=0、saved=0（真实 uid 仍为 alice 1000）
ok   SUID 程序以 euid=0 读到 /root/secret.txt（600）
ok   no_new_privs 下 SUID 失效：euid 保持 1000
ok   no_new_privs 下读取 /root/secret.txt 被拒绝
ok   getcap 显示 cap_dac_override=ep
ok   普通用户执行带 file capability 的程序：CapEff=0x2（CAP_DAC_OVERRIDE）
ok   capability 路径下读到 /root/secret.txt（无需 SUID）

PASS 13 / FAIL 0
```

## 五、分步讲解

### 1. 为什么在宿主编译、在容器里运行

- 容器基础镜像不需要装编译器；宿主编译一次，`-static` 链接后不依赖容器里的 glibc 版本；
- 容器只挂载 lab 目录，编译产物在 `.tmp/bin/`，用完随 `.tmp/` 删除；
- 这一步同时说明：**SUID 位属于文件 inode，不属于镜像**——把程序放进容器 overlay 后 `chown root` +
  `chmod 4755` 才生效；宿主的 `/home` 带 `nosuid`（见 [labs/01](../01-permission-model/)），做不了这个实验。

### 2. SUID：一条 `4755` 就够了

容器里 `chown root:root /usr/local/bin/uidinfo; chmod 4755` 后：

```text
-rwsr-xr-x 1 root root 793880 ... /usr/local/bin/uidinfo
SUID real=1000 effective=0 saved=0 | gid real=1000 eff=1000 saved=1000
SUID read /root/secret.txt: OK -> TOP-SECRET
```

- alice 的真实 uid 仍是 1000，但 execve 后 **euid 变成文件属主 root(0)**，saved uid 也记成 0；
- 因此 `fopen("/root/secret.txt")` 以 euid=0 检查权限，`/root` 的 700 与文件的 600 都不再是障碍；
- 程序内部可用 `seteuid(0)` / `seteuid(1000)` 在 root 与 alice 之间切换（saved 的作用）；
- 前提：属主必须是 root、文件的 `x` 位要真实存在（`4755` 是小写 `s`；`4644` 的 `S` 不具执行语义），
  且所在挂载点不能带 `nosuid`。

### 3. `no_new_privs`：让 SUID 当场失效

```text
NNP real=1000 effective=1000 saved=1000 | gid real=1000 eff=1000 saved=1000
NNP read /root/secret.txt: DENIED (euid=1000)
```

`setpriv --no-new-privs` 设置进程的 `no_new_privs` 标志；此后 execve **不再因为 SUID/SGID/file capability
而提升权限**（该标志一旦置位不可撤销，并会被子进程继承）。所以同一份 `4755` 程序，euid 保持 1000，
读取被拒。容器/服务的最小权限加固里常用它（`NoNewPrivileges=yes`）。

### 4. file capability：不换 euid，只给一项能力

```text
GETCAP /usr/local/bin/capread cap_dac_override=ep
CAP uid=1000 euid=1000 CapEff= 0000000000000002
CAP read /root/secret.txt: OK -> TOP-SECRET
```

- `setcap cap_dac_override=ep` 把「绕过 DAC 读写检查」这一项能力挂到**文件**上；alice 执行时
  euid 仍是 1000（没有变成 root），但 `CapEff` 的第 1 位被置起（`0x2`）；
- 与 SUID root 对比：SUID 给的是「uid 0 的全部能力」，file capability 只给**一项**，爆炸半径更小；
- 查位：`0x2 = 1 << 1` 对应 `CAP_DAC_OVERRIDE`。`getcap -r /` 是账户安全审计的常用命令（见 docs/10）；
- 这也解释了很多「程序没 SUID 却能 bind 80 / 读 shadow」的现场：先 `getcap` 看文件能力，别只 `ls -l`。

### 5. 三条路径的对照

| 路径 | 执行后 euid | 生效依据 | 典型风险 |
|---|---|---|---|
| SUID root | `0` | 文件属主 + `4755` | 整个 root 权限，漏洞影响最大 |
| no_new_privs | 不变（1000） | 内核标志，阻止上述提升 | 加固手段，不是授权 |
| file capability | 不变（1000） | `setcap` 的 `e/i/p` 标志 | 只放大一项能力，仍需审计 |

## 六、清理

脚本的 `trap` 会执行 `docker rm -f learnugroup-04-setuid-caps-$$` 并删除 `.tmp/`。容器内创建的
`alice`、`/root/secret.txt`、`/usr/local/bin/*` 都在容器 overlay 里，容器删除即消失；宿主的 `.tmp/`
只含 gcc 产物，属主是当前用户，直接删除即可。手动清理：

```bash
docker rm -f learnugroup-04-setuid-caps-$$ 2>/dev/null || true
rm -rf labs/04-setuid-caps/.tmp
```

## 七、对应章节

- [docs/05-提权与降权机制](../../docs/05-提权与降权机制.md)：SUID 原理、capability 五集合与 exec 转换规则、sudo。
- [docs/04-进程凭证与权限检查](../../docs/04-进程凭证与权限检查.md)：ruid/euid/suid、`no_new_privs`、`/proc/status`。
- [docs/10-账户安全基线与审计](../../docs/10-账户安全基线与审计.md)：SUID 清单与 `getcap -r /` 审计。
- 相邻实验：[labs/02-acl](../02-acl/)（不 chown 也能授权）、[labs/07-drills](../07-drills/)（故障演练）。

## 八、延伸练习

1. **去掉 x 位**：把 `/usr/local/bin/uidinfo` 改成 `4644` 再执行，观察 `ls` 显示 `S` 以及 execve 的行为；
   再对比 `4755`，解释「位在」与「位生效」的差别。
2. **最小能力**：把 `cap_dac_override` 换成 `cap_net_bind_service`，写一个绑定 80 端口的程序并 `setcap`，
   验证非 root 也能 bind（容器内 `ip_unprivileged_port_start=0`，注意别和宿主 1024 的默认值混淆）。
3. **加固组合**：在 `docker run` 上加 `--security-opt no-new-privileges` 跑 SUID 程序，
   对比本 lab 第 3 节的 `setpriv` 结果，说明容器级加固与进程级标志的关系。
