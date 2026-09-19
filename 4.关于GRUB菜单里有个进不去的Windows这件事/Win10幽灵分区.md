# 4. 关于 GRUB 菜单里有个进不去的 Windows 这件事

> **坑龄**：15 年+（os-prober 的 chain 探测和 Windows 7 的「系统保留」分区一样老）
> **症状**：每次开机，GRUB 菜单里端端正正挂着一行 `Windows 10 (on /dev/sda1)`。你从来没选过它，也不敢选它。
> **真相**：它是个鬼。牌位是真的，人早没了。

---

## 👻 病历：最守规矩的幽灵

这台机器的 GRUB 菜单常年是这样：

```
Ubuntu
Advanced options for Ubuntu
Memory test ...
Windows 10 (on /dev/sda1)      ← 就是你
```

主人一直以为自己装了双系统，还盘算着「把 Win10 删了腾空间」。听起来是个**删系统**的活，删错了就是 `/` 分区火葬场——所以第一件事不是动手，是取证。

## 🔬 取证：牌位下面埋的是谁

只读扫一遍，证据链五分钟闭环：

| 检查项 | 结果 | 含义 |
|---|---|---|
| `fdisk -l` | sda1 = **50M**，sda2 = 111.7G ext4（正在运行的 Ubuntu 根） | 整块盘**塞不下任何 Windows** |
| `blkid` | sda1 卷标 = **「系统保留」**，NTFS | Windows 的 "System Reserved" 分区，招牌对上了 |
| 挂载只读看内容 | 只有 `Boot/BCD`、`bootmgr`、多国语言启动字体，共 **19M** | 只有**引导器**，没有**系统**——没有 `Windows` 目录，没有 `system32` |
| MBR 前 446 字节 | `GRUB` 签名 | 引导链是 GRUB 的，跟 Windows 引导代码无关 |
| `grub.cfg:295` | `menuentry 'Windows 10 (on /dev/sda1)' ... chainloader +1` | 菜单条目的来历找到了 |
| Ventoy U盘 | 只有 Ubuntu ISO + 救援脚本 | 排除「Win10 ISO 造成错觉」的备选解释 |

## 🕵️ 案件还原

1. 上古时期，这盘是 Windows 的：50M「系统保留」分区放引导文件，后面跟着一个大 NTFS 的 C: 盘。这是 Windows 7 时代为了分区对齐搞出的标准布局。
2. 某天装 Ubuntu，安装器（curtin）看中了 C: 盘的地盘：**删掉大 NTFS，原地建了 ext4 的 sda2**。50M 的「系统保留」太小，没人稀罕，留下了。
3. Ubuntu 装完第一次 `update-grub`，os-prober 扫盘：`/dev/sda1:Windows 10:Windows:chain`——它的逻辑是「**见到 BCD 就挂牌位**」，至于 BCD 后面还有没有 Windows 本体，它不管。
4. 于是菜单里多了一个 chainloader 条目，指向一个引导管理器，而这个引导管理器配置里指向的系统**已经被合并成了 Linux 根分区**。选它 = 给你表演一个启动失败。

**一句话**：os-prober 只负责发牌位，不负责验尸。

## 🪓 送走它：五步，步步有保险

动手前先想清楚「为什么删它不伤 GRUB」：本机是 BIOS/MBR 引导，GRUB stage1 在 MBR（0 号扇区）、core.img 在 1~2047 扇区的分区间隙里，而 sda1 从 **2048 扇区**才开始——物理上碰不到引导代码。fstab 里也没有它的任何引用。放心指数足够高。

脚本五步（完整脚本见本目录 `remove-win10-ghost.sh`，支持 `DRY=1` 预览）：

1. **防呆校验**：sda1 的 UUID 必须和取证时一致、根分区必须是预期那块——环境对不上直接中止，防的是「脚本跑错了机器」这种史诗级事故
2. **备份**：前 1MiB 引导区镜像 + sda1 全量 tar，进 `/var/backups/`
3. **删分区**：`sfdisk --delete` + `partprobe`
4. **update-grub**：Windows 死牌位自动消失
5. **刷新自愈备份** + 终态校验

执行时的一个小插曲，值得记一笔：

```
The partition table has been altered.
Calling ioctl() to re-read partition table.
Re-reading the partition table failed.: Device or resource busy
The kernel still uses the old table.
```

sfdisk 收尾时想让内核整体重读分区表，但根分区就挂在这块盘上，**整表重读必然 EBUSY**——这不是事故，是物理规律。所以脚本自己用 `partprobe` 单独通知内核，然后校验 `/dev/sda1` 设备节点真的消失了才继续往下走。**别看见报错就慌，先搞清楚它是不是预期行为。**

## 💰 50M 的抉择

删完腾出 50M，要不要并给根分区？**不要。** sda1 在 sda2 **前面**，想把根分区往前扩，得离线移动分区起点（live USB + 分区移动，几十 GB 数据搬一次家）——为 50M 收益冒引导级风险，账算不过来。50M 就让它躺在磁盘头部当纪念币。

## 🏆 结案

- GRUB 菜单：纯 Ubuntu ✓
- 文件管理器：再也没有来路不明的「系统保留」卷 ✓
- 回滚保险：引导区镜像 + 分区全量备份躺在 `/var/backups/`，虽然永远用不上（那个分区唯一的「功能」就是挂假牌位）

> **一句话总结**：Windows 走了，但它的引导文件还在门口替它看店，os-prober 每次路过都还给记一笔「此处有 Windows」。
> 本案告破：不是双系统，是双牌位。

---

*取证工具：`win10-forensic.sh`（全程只读）｜删除工具：`remove-win10-ghost.sh`（带防呆 + DRY 预览 + 自动备份）*
