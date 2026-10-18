# labs/03 · 用户命名空间与从属 uid 动手实验

> **一句话总结**：用 `unshare -Ur` 亲眼看到「内层 root 不是宿主 root」、uid_map 与 65534 溢出。

> **本机验证**：✅ 全部可在宿主完成（不需要 root）；`unshare -Ur` 不可用时自动 `SKIP` 并退出 0。

| 项目 | 内容 |
|---|---|
| 演示现象 | `/etc/subuid`；`unshare -Ur` 的 uid_map；内层 capability；内层 root 创建文件的宿主属主；溢出 UID 65534；未映射 uid 切换 EINVAL；嵌套 userns |
| 运行环境 | 宿主（普通用户），内核支持非特权用户命名空间（本机 Linux 6.12） |
| 预计耗时 | < 3 秒 |
| 对应章节 | [docs/06-命名空间与uid映射](../../docs/06-命名空间与uid映射.md)、[docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md) |

## 一、这个 lab 演示什么

容器里的 `root` 为什么不是宿主 root？`/etc/subuid` 里的数字是谁在用？把这两个问题拆成 8 组可断言的现象：

1. `/etc/subuid` / `/etc/subgid` 给当前用户分配了从属 uid/gid 区间；
2. 本会话自己的 `/proc/self/uid_map`（本机是嵌套 userns，只有一行）；
3. `unshare -Ur` 把当前 uid 映射成内层 uid 0，内层 `CapEff` 非零；
4. **内层 uid 0 创建的文件，在宿主视角仍属于当前用户**——直接证明「内层 root ≠ 宿主 root」；
5. 未映射的属主显示为溢出 UID `65534`；
6. 内层切到未映射的 uid 1 → `setresuid` 返回 `EINVAL`；
7. 两层 `unshare -Ur` 后内层 map 变成 `0 0 1`；
8. 宿主读 `/etc/shadow` 被拒绝（只判断，不打印内容）。

> 锚点：`uid_map` 是「内层 uid ↔ 外层 uid」的翻译表，**只影响映射，不影响宿主 inode 上记录的真实属主**。

## 二、前置条件

- Linux 内核允许非特权用户命名空间（本机可用；若被 `kernel.unprivileged_userns_clone=0` 等限制，脚本会打印
  `SKIP` 并退出 0）。
- 需要命令：`unshare`、`setpriv`（util-linux）、`stat`；不需要 root、docker 或网络。
- `newuidmap`/`newgidmap` 是可选项：本机未安装，因此只能演示单 uid 映射（`unshare -Ur` 的工作方式），
  多行映射与 rootless 容器只在 [docs/06](../../docs/06-命名空间与uid映射.md) 讲原理。
- 脚本只在 `labs/03-userns-subuid/.tmp/` 下创建临时文件，退出时清理。

## 三、运行方式

```bash
cd labs/03-userns-subuid
bash run.sh
```

- 无交互、可重复；退出码 `0` 表示全部断言通过，`1` 表示有 `FAIL`。
- 每行以 `ok` / `FAIL` 开头，`SKIP` 不计入失败；末行固定为 `PASS n / FAIL m`。

## 四、真实运行输出

在本机执行 `bash run.sh` 的输出：

```text
== 1. /etc/subuid 与 /etc/subgid ==
--- /etc/subuid
demo:100000:65536
--- /etc/subgid
demo:100000:65536
ok   /etc/subuid 为 demo 分配了 100000 起的 65536 个从属 uid
ok   /etc/subgid 为 demo 分配了 100000 起的 65536 个从属 gid
SKIP newuidmap 未安装：本机只能做单 uid 映射，多行映射只在文档里讲原理

== 2. 本会话自身的 uid_map ==
      1000          0          1
ok   本会话只有一个 uid 映射区间（1000 0 1）

== 3. unshare -Ur：把当前 uid 映射成内层 root ==
unshare -Ur 内 uid_map: 0 1000 1
ok   内层映射为 0 1000 1（内层 0 = 外层 1000）
unshare -Ur 内 id -u: 0
ok   内层 id -u 为 0
unshare -Ur 内 CapEff: 000001ffffffffff
ok   内层进程拥有相对该 userns 的全部 capability（CapEff 非零）
ok   内层 NoNewPrivs=1（与宿主会话一致）

== 4. 内层 root 创建的文件，在宿主视角仍属于当前用户 ==
内层 uid 0 创建的文件，宿主 stat -c %u: 1000
ok   内层 root 创建的文件在宿主仍属 1000（内层 root 不是宿主 root）

== 5. 未映射 uid 的溢出显示：65534 ==
内层看「外层属于 1000 的本 lab 文件」: uid=0
内层看 /etc/shadow（外层未映射的 root 属主）: uid=65534
ok   被映射的 1000 在内层显示为 0
ok   未映射的属主在内层显示为溢出 UID 65534

== 6. 内层切到未映射 uid：setpriv --reuid=1 报 EINVAL ==
rc=127 输出: setpriv: setresuid failed: Invalid argument
ok   切到 uid 1 失败（rc=127）
ok   错误为 EINVAL（只映射了内层 uid 0，没有 uid 1 可切）

== 7. 嵌套用户命名空间 ==
两层 unshare -Ur 后的 uid_map: 0 0 1
ok   嵌套后内层 map 为 0 0 1（内层 0 = 中间层 0）

== 8. 宿主读 /etc/shadow：拒绝（只判断，不打印内容） ==
ok   宿主 cat /etc/shadow 被拒绝：cat: /etc/shadow: Permission denied

PASS 14 / FAIL 0
```

## 五、分步讲解

### 1. `/etc/subuid` 与 `newuidmap`

`/etc/subuid` 每行格式是 `用户名:起始 uid:数量`（来源：`man 5 subuid`）。本机内容：

```text
demo:100000:65536
```

它表示可以把宿主 uid 100000~165535 这段「从属 uid」分配给 `demo` 创建的命名空间。
要让**一段**（多行）映射真正写进 `uid_map`，需要 setuid root 的 `newuidmap`/`newgidmap` 代写；
本机未安装，所以只能演示 `unshare -Ur` 的单 uid 映射。rootless 容器依赖的正是这套机制（见 docs/06）。

### 2. 本会话自己的 uid_map

```text
      1000          0          1
```

三列依次是：内层 uid、外层 uid、长度。本会话只有 `1000 → 0` 这一条映射，说明它自己就在一个
**嵌套用户命名空间**里。这也解释了 [labs/01](../01-permission-model/) 中「宿主 root 的文件显示为 65534」：
宿主 init 命名空间的 root（uid 0）不在本会话的映射链上，只能显示为溢出 UID。

### 3. `unshare -Ur`：内层 root 的来历

`unshare -U` 新建用户命名空间，`-r` 把当前 uid 映射为该命名空间里的 0（来源：`man 1 unshare`）。实测：

```text
unshare -Ur 内 uid_map: 0 1000 1
unshare -Ur 内 id -u: 0
unshare -Ur 内 CapEff: 000001ffffffffff
```

`id -u` 变成 0、`CapEff` 从全 0 变成全 1 位，看起来「像 root」。但这是**相对新命名空间**的 root：
该命名空间里的 uid 0 只映射到外层 uid 1000。

### 4. 关键一击：内层 root 创建的文件在宿主仍属 1000

脚本让内层 uid 0 创建 `$LAB_DIR/.tmp/inner-created`，再回到宿主看它的数值属主：

```text
内层 uid 0 创建的文件，宿主 stat -c %u: 1000
```

原因：文件 inode 上记录的是**映射到宿主命名空间后的 kuid**，不是「内层看起来的 0」。
所以「容器里是 root」与「宿主上是 root」是两件事；这正是 [docs/06](../../docs/06-命名空间与uid映射.md)
要建立的核心直觉。

### 5. 溢出 UID 65534

在 `unshare -Ur` 内看两个文件：

- 本 lab 文件（外层属于 uid 1000，被映射）→ `uid=0`；
- `/etc/shadow`（外层属主 root，未映射）→ `uid=65534`。

未映射的 uid/gid 统一显示为溢出 UID `65534`（通常对应 `nobody`；来源：`man 7 user_namespaces`）。
因此容器里看到「文件属于 nobody」，先怀疑**uid 没被映射**，而不是磁盘上真有一个 nobody 用户。

### 6. 切到未映射 uid：EINVAL

```text
rc=127 输出: setpriv: setresuid failed: Invalid argument
```

因为只映射了内层 uid 0，`setresuid(1, ...)` 没有映射可用，内核返回 `EINVAL`
（来源：`man 2 setresuid` 的 EINVAL 说明）。多 uid 映射（`newuidmap` 写入多行）才能让内层切到 1、2、……

### 7. 嵌套 userns

再套一层 `unshare -Ur` 后，内层 map 变成 `0 0 1`：最内层的 0 映射到中间层的 0，中间层的 0 再映射到
外层 uid 1000。名字空间可以嵌套，但**每多一层就多一次翻译**；排查容器 uid 问题时，要沿着
`/proc/PID/uid_map` 一层层往上对。

### 8. `/etc/shadow`：宿主普通用户读不到

```text
ok   宿主 cat /etc/shadow 被拒绝：cat: /etc/shadow: Permission denied
```

脚本只判断可读性、不打印内容。`/etc/shadow` 的基线权限是 `640 root:shadow`（本机沙箱视角属主显示 65534），
普通用户不在 `shadow` 组，所以拒绝是正常的；要读密码哈希只能走特权路径，且本课程脚本始终不打印它。

## 六、清理

脚本退出时 `trap` 删除 `labs/03-userns-subuid/.tmp/`；所有 `unshare` 子进程随命令结束退出，不留下挂载或命名空间。
手动清理：

```bash
rm -rf labs/03-userns-subuid/.tmp
```

## 七、对应章节

- [docs/06-命名空间与uid映射](../../docs/06-命名空间与uid映射.md)：uid_map/gid_map 规则、溢出 UID、rootless 容器。
- [docs/07-Docker用户与权限实战](../../docs/07-Docker用户与权限实战.md)：容器 root 与宿主 uid 的关系（`userns-remap`、rootless）。
- [docs/04-进程凭证与权限检查](../../docs/04-进程凭证与权限检查.md)：`/proc/PID/status` 的凭证字段。

## 八、延伸练习

1. **手写映射**：尝试 `unshare -U sh -c 'echo $$ > /tmp/pid; ...'` 后再写 `uid_map`，观察「uid_map 只能写一次」
   以及未写 map 前进程没有 capability 的现象（提示：先 `unshare -U` 再在子进程里写 map）。
2. **对照容器**：用 `docker run --rm -u 1000:1000 debian:13 id` 与 `unshare -Ur id` 对比，
   解释两者「看起来都是普通用户/root」但命名空间位置不同。
3. **查一条映射链**：启动一个 `unshare -Ur sleep 60`，从宿主读它的 `/proc/PID/uid_map` 与
   `/proc/PID/status` 的 `NSpid`，再进 `/proc/PID/root` 观察文件属主变化。
