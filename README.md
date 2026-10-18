# learn-ugroup · Linux 用户权限与用户组系统学习教程

> 一套「**从进程凭证到 Docker/Nginx 实战**」的中文教程 + 可直接运行的实验。
> 目标不是背命令，而是让你在遇到任何 `Permission denied` / `403` / 容器卷写不进去时，
> **能立刻判断：是谁、在访问什么、被哪条规则拦住了。**

---

## 这套教程解决什么问题

多数 Linux 权限资料要么停在 `chmod 755`，要么一上来就讲内核 `cred` 结构，
中间**缺一张能把「用户/组/进程/文件/容器」连起来的地图**。本教程补的就是这一层：

- **有主干**：三要素模型（进程凭证 × 资源权限 × 检查规则），12 篇内容都挂在这张图上；
- **有锚点**：每条结论都能落到一条命令、一个 `/proc` 字段、一页 man；
- **有验证**：7 个可运行实验 + 每章「动手验证」，输出都是真实跑出来的；
- **有边界**：明确区分「宿主能看」「容器能做」「需要真 root」，不假装全能。

它直接回答两个最常见、也最容易想当然的问题：

| 你的疑问 | 一句话答案 | 详细 |
|---|---|---|
| 为什么普通用户执行 `docker` 就能在容器里当 root、还能挂载宿主目录？ | 客户端只是把请求发给 **root 运行的 dockerd**；容器内 root 默认就是宿主 root（无 userns 映射）；挂载的目录也以宿主 root 身份访问 | [07 章](docs/07-Docker用户与权限实战.md) |
| nginx 为什么必须用 `nginx` 用户跑 worker？为什么文件明明在却 403？ | master 以 root 完成 bind:80/开日志后降权；worker 以 `nginx` 身份读文件，**600 文件 + 父目录缺 x** 都会 403 | [08 章](docs/08-Nginx用户与权限实战.md) |

---

## 30 秒快速开始

```bash
git clone https://github.com/liubei90/learn-ugroup.git
cd learn-ugroup

make env            # 环境自检：本机能跑哪些实验（只读）

# 宿主就能跑（无需 root）：
cd labs/01-permission-model && bash run.sh && cd ../..
cd labs/03-userns-subuid    && bash run.sh && cd ../..

# 需要 docker（容器内是真正的 root）：
cd labs/04-setuid-caps && bash run.sh && cd ../..
cd labs/06-nginx-perm  && bash run.sh && cd ../..

# 全量质量门禁（文档 + 全部实验）
make test
```

> 没有 Docker 也能学：`make fast` 只跑宿主实验；正文里每个容器实验都同时给出
> 「在真实 root 机器上怎么做」的命令。

---

## 全景图（一页纸版本）

```text
          ① 主体：进程凭证                      ② 客体：资源权限
   ┌────────────────────────────┐      ┌────────────────────────────┐
   │ ruid euid suid fsuid        │      │ inode: mode(12位) uid gid   │
   │ rgid egid sgid fsgid + 组    │      │ ACL / xattr / file caps     │
   │ CapEff/Prm/Inh/Bnd/Amb      │      │ 端口 / socket / 设备 / IPC  │
   │ no_new_privs / user_ns      │      │ 挂载选项 / LSM 标签         │
   └─────────────┬──────────────┘      └──────────────┬─────────────┘
                 │                                    │
                 └──────────────┬─────────────────────┘
                                ▼
                 ③ 规则：属主 → 属组/ACL → other
                    → capability → LSM/挂载 → errno(EACCES/EPERM)
                                │
        ┌───────────────────────┼──────────────────────────────┐
        ▼                       ▼                              ▼
   setuid / capability      namespace uid 映射            docker / nginx
   sudo / 降权              溢出 UID(65534)             卷属主 / 403 / 端口
```

完整版（含每一章的定位、检查顺序、真实输出）见
**[docs/01-权限模型全景](docs/01-权限模型全景.md)** —— 建议从这里开始读。

---

## 文档导览（docs/）

| 章节 | 一句话 | 读完能回答 |
|---|---|---|
| [00 学习方法与环境准备](docs/00-学习方法与环境准备.md) | 路线图、两套实验环境、工具清单、安全边界 | 我该按什么顺序学？本机缺 root 怎么办？ |
| [01 权限模型全景](docs/01-权限模型全景.md) | **全书之锚**：进程凭证、资源权限、检查规则三要素 | Permission denied 到底卡在哪一步？ |
| [02 用户与组数据库](docs/02-用户与组数据库.md) | passwd/shadow/group、UID 分配、useradd/usermod | uid 1000 对应的「人」是怎么被管理的？ |
| [03 文件权限与ACL](docs/03-文件权限与ACL.md) | 12 位 mode、umask、SUID/SGID/sticky、ACL、chattr | 目录的 x 位为什么是通行证？ACL 为什么「给了却没生效」？ |
| [04 进程凭证与权限检查](docs/04-进程凭证与权限检查.md) | cred、四套 uid、内核检查链、fd 语义、LSM | 内核按什么顺序检查？root 为什么会失败？ |
| [05 提权与降权机制](docs/05-提权与降权机制.md) | setuid、capability 五集合、sudo、降权顺序 | 怎么只给一个程序一项特权？守护进程怎么安全降权？ |
| [06 命名空间与uid映射](docs/06-命名空间与uid映射.md) | userns、uid_map、subuid、rootless、溢出 UID | 容器 root 到底是不是宿主 root？65534 是什么？ |
| [07 Docker用户与权限实战](docs/07-Docker用户与权限实战.md) | docker.sock=root、容器内用户、卷属主 5 种解法 | 为什么 docker 组等于 root？卷写不进去怎么修？ |
| [08 Nginx用户与权限实战](docs/08-Nginx用户与权限实战.md) | master/worker、权限需求矩阵、403 排查、端口与 socket | nginx 用哪个用户？403/502 怎么定位？ |
| [09 权限排障手册](docs/09-权限排障手册.md) | EACCES vs EPERM、5 分钟流程、14 个案例 | 线上报 Permission denied，从哪查起？ |
| [10 账户安全基线与审计](docs/10-账户安全基线与审计.md) | 账户/文件/服务三层基线、审计清单 | SUID 太多怎么办？怎么审计账户风险？ |
| [11 速查表与命令索引](docs/11-速查表与命令索引.md) | 按主题查命令、排障决策树、关键词索引 | 我要的那条命令在哪？ |

---

## 实验导览（labs/）

每个实验都有 `README.md`（含**真实运行输出**）和 `run.sh`。约定：
不需要 root 的实验直接跑；需要容器的实验用 `docker run --rm`，不可用时打印 `SKIP` 并以 0 退出。

| 实验 | 主题 | 环境 | 关键现象 |
|---|---|---|---|
| [01-permission-model](labs/01-permission-model/) | 凭证、umask、特殊位、目录 x、fd 语义 | ✅ 宿主 | `rws/rwS/rwt` 的含义、`chmod 000` 后已打开 fd 仍可读 |
| [02-acl](labs/02-acl/) | ACL、mask、`#effective`、default ACL、备份恢复 | ✅ 宿主（可选容器） | ACL 给了却被 mask 压掉 |
| [03-userns-subuid](labs/03-userns-subuid/) | `unshare -Ur`、uid_map、溢出 UID | ✅ 宿主 | 假 root、`0 1000 1` 映射、65534 |
| [04-setuid-caps](labs/04-setuid-caps/) | setuid、`no_new_privs`、文件 capability、sudo | ⚠️ docker | euid 0、cap 让非 root 读 root 文件 |
| [05-docker-uid](labs/05-docker-uid/) | 容器默认 root、`-u`、卷属主、命名卷 | ⚠️ docker | `Permission denied` 写挂载目录 |
| [06-nginx-perm](labs/06-nginx-perm/) | master/worker、403、日志、chmod 修复 | ⚠️ docker | `13: Permission denied` |
| [07-drills](labs/07-drills/) | 5 个故障场景的排障演练（含 `--quiz`） | ⚠️ docker + 宿主 | 现象 → 诊断 → 根因 → 修复 |

---

## 环境与已知限制（请先读）

本教程在 **Debian 13 / 内核 6.12** 上编写并验证，但会话运行在受限沙箱中（非 root、`NoNewPrivs=1`、
`/home` 为 `nosuid,nodev`）。因此：

- **宿主上能做**：观察凭证/挂载/stat/getfacl、`unshare -Ur`、自有文件的一切操作；
- **需要真 root 的**：`useradd`、`setuid` 提权、文件 capability、`sudo`、`chattr +i`——全部放到
  `docker run --rm ... debian:13` 容器里做（容器 root 在默认配置下就是宿主 root，请只挂载实验目录）；
- 各实验对缺失依赖会打印 `SKIP` 而不是失败；每章也会标注「宿主 / 容器 / 需要 root」。

**安全提醒**：`docker` 组成员 ≈ 宿主 root 权限；`--privileged`、`-v /:/host`、把 `docker.sock`
挂进容器，都是把 root 交给对方。课程里只演示原理，实验脚本不执行这些操作。

---

## 质量门禁

```bash
make test          # = bash scripts/verify.sh
make fast          # 只跑宿主实验
```

门禁检查：12 篇文档的结构/行数/占位符/相对链接、README 与 Makefile 目标、
7 个实验的实际运行结果（`PASS n / FAIL m`）、`scripts/env-check.sh` 退出码。
任何一项失败都会以非 0 退出并打印具体文件与原因。

---

## 三条学习路线

| 路线 | 适用 | 顺序 | 时间 |
|---|---|---|---|
| 速成 | 明天就要排查线上问题 | 01 → 03 → 04(§2.3) → 07 → 08 → 09 | 4~6 小时 |
| 系统 | 想真正建立模型 | 00 → 01 → … → 11 + 全部实验 | 每天 1.5h，约 1 周 |
| 实战 | 只解决手头问题 | 09 案例 → 回溯对应章节 + 对应 lab | 30 分钟/问题 |

---

## 目录结构

```text
learn-ugroup/
├── README.md
├── Makefile                  # make env/test/fast/list/clean
├── docs/                     # 12 篇课程正文
│   ├── 00-学习方法与环境准备.md
│   ├── 01-权限模型全景.md
│   ├── ...
│   └── 11-速查表与命令索引.md
├── labs/                     # 7 个可运行实验（每个含 README + run.sh）
│   ├── 01-permission-model/
│   ├── ...
│   └── 07-drills/
└── scripts/
    ├── env-check.sh          # 环境能力自检
    └── verify.sh             # 质量门禁
```

---

## 常见问题（FAQ）

**Q：容器里 `id` 是 root，宿主机上文件却显示 65534，谁错了？**
A：都没错。默认 Docker 是 rootful，容器 uid 0 = 宿主 root；你的宿主会话在 user namespace 里，
未映射的 uid 显示成溢出值 65534。见 [06 章](docs/06-命名空间与uid映射.md)、[07 章](docs/07-Docker用户与权限实战.md)。

**Q：`docker run -u 1000:1000` 是不是就完全安全了？**
A：不是。`-u` 只改容器内进程身份；`docker.sock`、`--privileged`、挂载的宿主目录、capability 都可能越界。
见 [07 章](docs/07-Docker用户与权限实战.md) 的安全小节。

**Q：nginx 报 403，文件权限是 644，为什么还不行？**
A：先看 worker 的 uid（`ps -o user -C nginx`），再用 `namei -l` 看**每一级目录**的 x 位。
见 [08 章](docs/08-Nginx用户与权限实战.md)、[09 章](docs/09-权限排障手册.md)。

**Q：setuid 程序为什么没有提权？**
A：常见原因：挂了 `nosuid`、进程有 `no_new_privs`、写成了脚本、文件在容器里但容器 cap 被裁剪。
见 [05 章](docs/05-提权与降权机制.md)、[labs/04-setuid-caps](labs/04-setuid-caps/)。

**Q：ACL 明明 `setfacl` 成功了，目标用户还是没权限？**
A：看 `getfacl` 的 `#effective`——mask 会压掉具名条目的权限；`chmod` 改的是 mask。
见 [03 章](docs/03-文件权限与ACL.md)、[labs/02-acl](labs/02-acl/)。

---

## 约定

- 正文事实优先来自 **man 页 / 本机文件 / 实际命令输出**，并标注「验证：」或「来源：」；
- 为保护隐私与可移植性，文中主机用户名统一脱敏为 `demo`，LVM 设备名、容器 ID、镜像源等本机标识用占位符替代；命令、数值与结论不受影响；
- 容器内得到的输出会标注「容器内」，宿主输出不标注；
- 发行版差异（Debian/RHEL、`www-data`/`nginx`、`sites-enabled`/`conf.d`）会单独说明；
- 发现错误欢迎直接改文档或在实验里加断言——`make test` 会替你回归。

---

> 建议的第一站：[docs/01-权限模型全景](docs/01-权限模型全景.md)。
> 想先动手：[labs/01-permission-model](labs/01-permission-model/)。
