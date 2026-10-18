# labs/02 · ACL 动手实验

> **一句话总结**：用真实 `getfacl` 输出讲清 ACL 条目、mask 与 default ACL 继承，并验证跨 uid 授权。

> **本机验证**：✅ 宿主部分全部可跑；容器部分可选（需要 docker + gcc，不联网），缺失时打印 `SKIP` 不影响结论。

| 项目 | 内容 |
|---|---|
| 演示现象 | `setfacl/getfacl`；`mask` 与 `#effective`；`chmod` 改 mask；default ACL 继承；`-k/-b`；备份恢复；跨 uid 读取 |
| 运行环境 | 宿主（ext4 + `acl` 包）；容器部分可选：docker + `debian:13` + `gcc` |
| 预计耗时 | 宿主 < 3 秒；带容器约 5 秒 |
| 对应章节 | [docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)、[docs/09-权限排障手册](../../docs/09-权限排障手册.md) |

## 一、这个 lab 演示什么

`rwx` 只有「属主 / 属组 / other」三格，遇到「同一个组里只想让某个人读」「共享目录里新文件自动带权限」
就不够用。ACL 在 inode 上再挂一组条目，本 lab 按顺序验证：

1. 给单个用户加一条 ACL，`getfacl` 里多出 `user:demo:r--` 和自动生成的 `mask`；
2. **mask 是 ACL 的「上限」**：`chmod 640` 改的是 mask，组权限被 `#effective` 标注限制；
3. **default ACL 只对目录有意义**：新建文件自动继承 `default:user:...` 条目；
4. `setfacl -k` 只删 default，`setfacl -b` 删全部扩展 ACL；
5. `getfacl -p -R` 备份 + `setfacl --restore` 恢复；
6. 容器里把 ACL 授给另一个 uid（101），它读到原本 600 的文件，而未授权的 102 仍被拒。

> 锚点：ACL 的匹配顺序是 **属主 → 命名用户 → 组（含命名组）→ other**，其中「命名用户/命名组/组」都还要再过
> 一道 `mask`。任何「ACL 加了却不生效」的问题，先看 `#effective` 和 `mask::`。

## 二、前置条件

- 宿主文件系统支持 POSIX ACL（本机 `/home` 为 ext4，实测可直接用，不需要额外 `mount -o acl`）。
- 需要 `getfacl` / `setfacl`（Debian 包名 `acl`；本机已安装）。
- 第 6 节是**可选**容器演示：需要 `docker`、本地 `debian:13` 镜像、`gcc`（编译一个最小 ACL 写入器）；
  任一缺失会打印 `SKIP` 并继续，脚本仍以 0 退出。**该节不访问网络。**
- 脚本只在 `labs/02-acl/.tmp/` 下工作，退出时清理；容器只挂载本 lab 目录。

## 三、运行方式

```bash
cd labs/02-acl
bash run.sh
```

- 无交互、可重复；退出码 `0` 表示全部已执行断言通过，`1` 表示有 `FAIL`。
- 第 6 节若被跳过，输出中会有 `SKIP`，但 `PASS/FAIL` 汇总行仍然正常打印。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. setfacl / getfacl：给当前用户加一条 ACL ==
# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/acl1
# owner: demo
# group: demo
user::rw-
user:demo:r--
group::rw-
mask::rw-
other::r--

ACL 中 user: 行数 = 2（一条 user:: 属主条目 + 一条扩展条目）
ok   扩展 ACL 条目已存在（user:1000:r--）
ok   setfacl 自动生成了 mask 条目

== 2. chmod 改的是 mask：640 之后 group 受 mask 限制 ==
# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/acl1
# owner: demo
# group: demo
user::rw-
user:demo:r--
group::rw-	#effective:r--
mask::r--
other::---

ok   chmod 640 把 mask 改成 r--
ok   getfacl 标出 group 的 #effective:r--（受 mask 限制）

== 3. default ACL：新文件自动继承 ==
# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/acldir
# owner: demo
# group: demo
user::rwx
user:demo:rwx
group::rwx
mask::rwx
other::r-x
default:user::rwx
default:user:demo:rwx
default:group::rwx
default:mask::rwx
default:other::r-x

# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/acldir/newfile
# owner: demo
# group: demo
user::rw-
user:demo:rwx	#effective:rw-
group::rwx	#effective:rw-
mask::rw-
other::r--

ok   目录带 default ACL 条目
ok   新建文件继承 default ACL，并被 mask 限制为有效 rw-

== 4. setfacl -k / -b：分别删默认 ACL 与全部 ACL ==
# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/acl2
# owner: demo
# group: demo
user::rwx
user:demo:rwx
group::rwx
mask::rwx
other::r-x

ok   -k 只删除 default 条目
ok   -k 保留了普通访问 ACL 条目
ok   -b 清除了全部扩展 ACL（只剩 user:: 属主条目）

== 5. 备份与恢复：getfacl -p -R > bak + setfacl --restore ==
备份文件条目数: 2
ok   setfacl -bR 后 ACL 已清除
ok   setfacl --restore 恢复了目录 default ACL 与文件 ACL

== 6. 可选：容器内把 ACL 授给 uid 101（不联网，直接写 ACL xattr） ==
宿主文件: secret.txt 属主 1000、模式 600（其他 uid 不可读）
容器内（root）授予 uid 101 r--：acl-set uid=101 file=/lab/.tmp/cross/secret.txt
ok   容器内成功写入 uid 101 的 ACL 条目
容器内以 uid 101 读取: CROSS-UID-OK
ok   uid 101 通过 ACL 读到了原本 600 的文件
对照：未授权的 uid 102 读取: cat: /lab/.tmp/cross/secret.txt: Permission denied
ok   未授权的 uid 102 仍被拒绝（ACL 精确到 uid）
宿主视角（本会话 userns 未映射 uid 101，数值显示为 4294967295 属正常）：
# file: /home/demo/code/learn-ugroup/labs/02-acl/.tmp/cross/secret.txt
# owner: demo
# group: demo
user::rw-
user:4294967295:r--
group::r--
mask::r--
other::---


PASS 14 / FAIL 0
```

## 五、分步讲解

### 1. ACL 的基础条目

`getfacl -p` 里的条目分两类：

- `user::` / `group::` / `other::`：对应传统 mode 的三格，**没有** id；
- `user:demo:r--`：命名用户条目（带 uid），这是 `setfacl -m u:1000:r` 加出来的；
- `mask::rw-`：只要存在命名用户/命名组条目，内核就要求有 mask，`setfacl` 会自动补。

`getfacl -c` 会去掉 `# file/owner/group` 注释，脚本里用 `getfacl -cp` 做断言，便于稳定匹配条目。

### 2. mask 与 `#effective`：ACL 的上限

第 2 节先有 `user:demo:r--`、`group::rw-`、`mask::rw-`，再执行 `chmod 640`，结果：

```text
user:demo:r--
group::rw-	#effective:r--
mask::r--
other::---
```

关键结论：**只要文件上有扩展 ACL，`chmod` 改的就是 `mask`（传统 group 位也映射进 mask）**，
所以「组权限写着 rw-，实际却只有 r--」。`#effective` 是 `getfacl` 算给你看的最终生效权限。
遇到「ACL 明明给了 rw 却写不进去」，先核对 `mask::`。

### 3. default ACL：目录上的「权限模板」

default ACL 只能设在目录上（`setfacl -d -m ...`），作用是对**之后新建的子项**施加初始 ACL：

- 目录自身显示 5 条 `default:*`；
- `touch acldir/newfile` 后，新文件继承了 `user:demo:rwx`，但因为文件创建 mode 只有 `rw-`（`touch` 默认 666
  经 umask 后）且 mask 为 `rw-`，所以显示 `#effective:rw-`。

注意：default ACL 不会追溯修改已有文件；它也不能让新建文件获得「比创建 mode 更多」的位，这一点和第 2 节的
mask 限制是同一套规则。

### 4. `-k` 与 `-b` 的区别

- `setfacl -k DIR`：只删 `default:*`，普通访问 ACL 保留（输出中 `user:demo:rwx` 仍在）；
- `setfacl -b FILE|DIR`：删掉所有扩展 ACL（包括 default 和 mask），只剩 `user::/group::/other::`。

清理共享目录时可先用 `-k` 关掉继承，再决定是否 `-b` 清掉现存条目。

### 5. 备份与恢复：`-p` 很关键

```bash
getfacl -p -R DIR > acl.bak
setfacl -bR DIR
setfacl --restore=acl.bak
```

本机实测：不带 `-p` 时 `getfacl -R` 会打印 `Removing leading '/' from absolute path names`，备份里的路径
变成相对路径；`setfacl --restore` 再按当前工作目录解析，就会报
`No such file or directory`。**恢复用途的备份必须加 `-p`**，保持绝对路径。

### 6. 跨 uid 授权：ACL 是 `chown` 之外的另一种修法

容器部分把宿主的 600 文件授权给容器内 `uid 101`。因为 `debian:13` 基础镜像没有 `acl` 包，而本 lab 约定
不联网（只有 [labs/04](../04-setuid-caps/) 允许 apt），脚本改用**直接写 `system.posix_acl_access` 扩展属性**
的最小 C 程序（`gcc -static` 编译后由容器 root 执行）：

- 容器 root 拥有 `CAP_FOWNER`，可以给属主为 1000 的文件写 ACL；
- 结果：`uid 101` 能读到原本 600 的文件，`uid 102` 仍被拒绝，证明条目精确到 uid；
- 宿主 `getfacl` 里该条目显示为 `user:4294967295:r--`：因为本会话的 userns 只映射了部分 uid，101 未映射，
  这是**显示层面的数值**，容器内看到的是 101。

生产环境更简单：安装 `acl` 包后用 `setfacl -m u:101:r FILE`；或直接 `chown 101:101 FILE`。
两条路的取舍是：ACL 只加一个 uid 的读权限、不动属主；`chown` 改属主、影响所有权限判断。

## 六、清理

脚本退出时 `trap` 删除 `labs/02-acl/.tmp/`；容器全部 `--rm`，不残留。手动清理：

```bash
rm -rf labs/02-acl/.tmp
```

第 6 节的 ACL 只写在 `.tmp` 内的临时文件上，随文件一起删除；没有创建 root 属主的宿主文件。

## 七、对应章节

- [docs/03-文件权限与ACL](../../docs/03-文件权限与ACL.md)：ACL、mask、default ACL、共享目录配方。
- [docs/09-权限排障手册](../../docs/09-权限排障手册.md)：`getfacl` / `namei -l` 在排障流程中的位置。
- 相关实验：[labs/07-drills](../07-drills/) 场景 3（卷 uid 不匹配）可以用 ACL 作为不 `chown` 的修法。

## 八、延伸练习

1. **mask 陷阱复现**：给自己的用户加 `u:$USER:rwx`，再 `chmod 640`，用 `getfacl` 解释为什么 effective 不是 rwx；
   然后 `setfacl -m m::rwx` 手动把 mask 提回去。
2. **共享目录配方**：建一个组可写的目录，`setfacl -d -m g:devs:rwx`，用 `touch` 验证新文件组权限；
   再结合 [labs/07](../07-drills/) 的卷 uid 场景，说明「加 ACL」与「改属主」的适用边界。
3. **备份恢复踩坑**：分别用 `getfacl -R` 和 `getfacl -p -R` 生成两份备份，在副本目录上 `--restore`，
   对比哪一份会报 `No such file or directory`，并解释原因。
