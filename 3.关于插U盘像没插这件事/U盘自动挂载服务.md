# 3. 关于插 U 盘像没插这件事

> **坑龄**：自打 u盘发明那天起 ｜ **受害系统**：Ubuntu 全家族（桌面版、服务器版各病一种）
> **症状**：U盘插上了。系统说：我没看见。
> **后遗症**：手动 `mount` 打错字、挂载点建在 `/mnt` 忘了删、FAT 盘里所有文件属主都是 root、直接拔盘数据当场火化。

---

## 🕳️ 病历：四种玄学

Ubuntu 的 U 盘自动挂载，本质上是个「看人下菜」的精分系统：

| 场景 | 行为 | 吐槽 |
|---|---|---|
| **桌面版，图形会话里插** | gvfs 帮你挂到 `/media/<user>/<卷标>` | 能用，但挂载点带着 ACL 和会话魔法，SSH 进来经常看不见 |
| **桌面版，SSH/TTY 里插** | 看心情。gvfs 只伺候本地图形会话 | 同一块盘，白天能用晚上失明 |
| **服务器版，随便怎么插** | 什么都不发生 | 官方态度：服务器要什么 U 盘（→ 那你让救援盘出现在服务器上干嘛） |
| **谁都不管时手动挂** | `mount /dev/sdb1 /mnt` 成功，然后：`ls -l` 全是 root | FAT/exFAT 没有 Unix 属主概念，不传 `uid=` 就默认 root，你连删自己拷的文件都 Permission denied |

然后是拔盘：不 `umount` 直接拔，写缓存还没落盘 → 文件损坏；`umount` 打错路径 → `target is busy` → 你开始逐个 `lsof` 找谁占着。

## 🔬 考古结论

- gvfs 的自动挂载绑死图形会话，无头环境**设计上就不工作**——这不是 Bug，是「特性」。
- `udisksctl` 理论上能用，但内部盘/无人会话场景要跟 polkit 掰手腕，非交互场景直接摆烂。
- `autofs` 能做，但它是「访问时才挂」的懒加载，路径和你想的不一定一样，而且对「插上就想看」的 U 盘场景属于杀鸡用牛刀还削到手。

于是自造了一套：**udev 负责发现，systemd 负责干活，一个 bash 脚本负责所有脏活**。零新依赖（udev/systemd/util-linux 全是系统自带），插上即挂、拔了即清。

## 🏗️ 方案架构

```
U盘插入 → udev 规则(99-usb-automount.rules)
            只匹配 ID_BUS=usb/mmc 且带文件系统的块设备
            └─> SYSTEMD_WANTS → usb-automount@<设备名>.service
                  ├─ 插入: ExecStart → usb-automount add <设备名>
                  │     过滤（fstab/swap/空盘/整盘带分区）
                  │     挂到 /media/usb/<卷标>，FAT 系传 uid/gid/umask
                  └─ 拔出: BindsTo=dev-xxx.device → systemd 自动 stop
                        → ExecStop 卸载 + 删挂载点
```

### 填坑实录（写代码时真踩到的）

1. **udev 里直接跑 mount 是找死**：udevd 事件处理完会清理子进程，长命令随时被杀。正解是 `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}+="xxx@%k.service"`，把活外包给 systemd。
2. **systemd oneshot 服务没有 ExecStop 时刻**：`Type=oneshot` 默认跑完就 inactive，设备拔了也没东西可停。必须 `RemainAfterExit=yes`，再配 `BindsTo=dev-%i.device`——设备单元一消失，systemd 自动停服，`ExecStop` 才有机会清理。这套组合是「拔盘自动清理」的核心，少一个都不行。
3. **`mount -o uid=某用户名` 是无效的**：内核的 vfat/exfat/ntfs3 驱动只认**数字 UID**，传用户名直接 EINVAL。脚本里得先 `id -u` 换算。文档不写，试了才知道。
4. **分区不继承父盘的 udev 属性？继承的**：`ID_BUS=usb` 是父盘的属性，好在 udev 内置 `IMPORT{parent}="ID_*"` 让分区继承，所以规则里分区和整盘都能命中 `ENV{ID_BUS}=="usb"`。
5. **桌面版抢挂竞态**：图形会话里 gvfs 和本服务赛跑，谁先挂上谁算数。输了的正确姿势不是再挂一遍（同设备双挂载，乱），而是**建软链兜底**：`/media/usb/<卷标> → 桌面挂载点`，`cd` 照样进，`df -h` 照样看。
6. **blkid 竞态**：udev 事件到达时文件系统探测可能还没完成，`blkid` 返回空 ≠ 空盘。重试 5 次再下结论。
7. **回环设备测不了 udev 规则**：loop 设备 `ID_BUS` 是空的，永远命中不了 USB 规则。所以自测分两层：udev 规则用 `udevadm verify` 校验语法；脚本+服务全链路用「losetup 虚拟盘 + systemctl start 单元」真刀真枪跑一遍。

### 行为规格

- 挂载点：`/media/usb/<卷标>`（无卷标退 UUID 前 8 位，重名加 `-2`）
- 权限：FAT/exFAT/NTFS 全盘文件归部署用户；ext4 系保持盘上原有属主
- 安全带：`/etc/fstab` 里登记的设备不抢；swap 跳过；整盘带分区表时只挂分区
- 拔出：卸载 → 删挂载点 → 清登记，全程 `journalctl -t usb-automount` 可审计

## 🚀 快速上手

```bash
# 安装（内置自测：32MB 回环盘全链路跑一遍，自动清理）
sudo bash usb-automount/install-usb-automount.sh

# 用
df -h | grep /media/usb
usb-automount status
journalctl -t usb-automount -f

# 拆
sudo bash usb-automount/uninstall-usb-automount.sh
```

## 📦 本目录文件

| 文件 | 说明 |
|---|---|
| `U盘自动挂载服务.md` | 就是本篇：病历 + 考古 + 方案 |
| `usb-automount/usb-automount.sh` | 主脚本（add/remove/status） |
| `usb-automount/systemd/usb-automount@.service` | systemd 模板服务 |
| `usb-automount/udev/99-usb-automount.rules` | udev 触发规则 |
| `usb-automount/config.default` | 配置模板（安装时按部署用户渲染） |
| `usb-automount/install-usb-automount.sh` | 一键安装 + 自测 |
| `usb-automount/uninstall-usb-automount.sh` | 一键卸载 |

## ⚠️ 已知边界

- LUKS/BitLocker 加密盘不自动挂（安全特性，不是 Bug）。
- SATA/NVMe 硬盘盒不自动触发（`ID_BUS` 不是 usb，防止误伤内置盘），手动 `usb-automount add` 即可。
- 开机**前**就插好的盘不会自动挂（开机过程没有「插入事件」），开机后手动 `add` 一下。

## 🏆 一句话总结

> Ubuntu 对 U 盘的态度：桌面会话里是亲儿子，SSH 里是继子，服务器上是空气。
> 本方案：空气、继子、亲儿子，一律按亲儿子办。
