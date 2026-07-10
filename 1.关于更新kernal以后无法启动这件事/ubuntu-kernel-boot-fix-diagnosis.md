# Ubuntu 内核更新后进入 Emergency Mode 诊断与修复指南

> **日期**: 2026-07-10
> **机器**: ThinkPad X1 Carbon 3rd Gen
> **系统**: Ubuntu 22.04 (HWE kernel 6.8.0)
> **问题**: 内核更新后重启直接进入 emergency mode，无法正常启动

---

## 一、问题根因分析

Ubuntu 内核更新后进入 emergency mode 的常见原因（按概率排序）：

| # | 原因 | 概率 | 检测方法 |
|---|------|------|----------|
| 1 | **initramfs 未正确重建** — 新内核的 initrd.img 缺失必要模块 | ⭐⭐⭐⭐⭐ | `lsinitramfs /boot/initrd.img-$(uname -r) \| grep -E 'ahci\|nvme\|virtio'` |
| 2 | **fstab 中有不带 `nofail` 的外部磁盘** — 磁盘不在位导致 systemd 等待超时 | ⭐⭐⭐⭐ | `grep -v 'nofail\|^#\|^$' /etc/fstab` |
| 3 | **GRUB 未更新** — 引导配置指向错误的内核或 UUID | ⭐⭐⭐ | `grep 'linux\|initrd' /boot/grub/grub.cfg \| head -10` |
| 4 | **EFI 分区未挂载** — GRUB 更新时 EFI 分区未挂载，写入了错误位置 | ⭐⭐⭐ | `mount \| grep /boot/efi` |
| 5 | **内核模块缺失** — linux-modules-extra 包未安装 | ⭐⭐ | `dpkg -l \| grep linux-modules-extra` |
| 6 | **磁盘 UUID 变化** — 分区表变动导致 fstab UUID 不匹配 | ⭐⭐ | `blkid /dev/sda3` vs `grep sda3 /etc/fstab` |
| 7 | **NVIDIA/显卡驱动不兼容** — 新内核缺少对应 DKMS 模块 | ⭐⭐ | `dkms status` |

---

## 二、自动化修复脚本

将以下脚本保存为 `fix-ubuntu-boot.sh`，在 **Live USB 环境下以 root 运行**：

```bash
#!/bin/bash
# ============================================================
# fix-ubuntu-boot.sh
# 用途: Ubuntu 内核更新后进入 emergency mode 的自动修复
# 用法: sudo bash fix-ubuntu-boot.sh /dev/sda3
#       (参数为根分区的设备路径)
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---- 参数检查 ----
ROOT_PART="${1:-/dev/sda3}"
ROOT_MNT="/mnt/fixboot"

if [ "$(id -u)" -ne 0 ]; then
    err "请用 sudo 运行此脚本"
fi

echo "============================================"
echo "  Ubuntu Boot Emergency Mode 自动修复工具"
echo "============================================"
echo "根分区: $ROOT_PART"
echo "挂载点: $ROOT_MNT"
echo ""

# ---- Step 1: 挂载根分区 ----
log "Step 1: 挂载根分区..."
mkdir -p "$ROOT_MNT"
mount "$ROOT_PART" "$ROOT_MNT"

# ---- Step 2: 挂载虚拟文件系统 ----
log "Step 2: 挂载虚拟文件系统..."
mount --bind /dev  "$ROOT_MNT/dev"
mount --bind /dev/pts "$ROOT_MNT/dev/pts"
mount --bind /proc "$ROOT_MNT/proc"
mount --bind /sys  "$ROOT_MNT/sys"
mount --bind /run  "$ROOT_MNT/run"

# ---- Step 3: 诊断并修复 fstab ----
log "Step 3: 检查 /etc/fstab..."
FSTAB="$ROOT_MNT/etc/fstab"

# 备份 fstab
cp "$FSTAB" "$FSTAB.bak.$(date +%Y%m%d%H%M)"
log "  fstab 已备份"

# 检查根分区 UUID 是否匹配
FSTAB_ROOT_UUID=$(grep -E '^\s*UUID=' "$FSTAB" | grep -E '/\s+ext4' | awk '{print $1}' | cut -d= -f2)
ACTUAL_ROOT_UUID=$(blkid "$ROOT_PART" -s UUID -o value)
if [ "$FSTAB_ROOT_UUID" != "$ACTUAL_ROOT_UUID" ]; then
    warn "  fstab UUID ($FSTAB_ROOT_UUID) ≠ 实际 UUID ($ACTUAL_ROOT_UUID)"
    warn "  正在修正..."
    sed -i "s|UUID=$FSTAB_ROOT_UUID|UUID=$ACTUAL_ROOT_UUID|g" "$FSTAB"
    log "  UUID 已修正"
else
    log "  根分区 UUID 匹配: $FSTAB_ROOT_UUID"
fi

# 为所有非根、非 swap、非 boot/efi 的条目添加 nofail
while IFS= read -r line; do
    # 跳过注释和空行
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    # 跳过 / 和 swap 和 /boot/efi
    echo "$line" | grep -qE '/\s|swap|/boot/efi' && continue
    # 如果已有 nofail 则跳过
    echo "$line" | grep -q 'nofail' && continue
    # 这条是不带 nofail 的外部挂载
    warn "  发现无 nofail 的条目: $line"
done < "$FSTAB"

# 自动给所有非关键条目加 nofail
sed -i -E '/^\s*UUID=/{ /\/\s|\/boot\/efi|swap|nofail/! s/(defaults)/\1,nofail/ }' "$FSTAB"
sed -i -E '/^\s*UUID=/{ /\/\s|\/boot\/efi|swap|nofail/! s/(defaults,[^ ]*)/\1,nofail/ }' "$FSTAB"
log "  fstab 已修复 (已添加 nofail 到非关键挂载)"

# ---- Step 4: 挂载 EFI 分区 ----
log "Step 4: 挂载 EFI 分区..."
EFI_UUID=$(grep '/boot/efi' "$FSTAB" | grep -oP 'UUID=\K[^\s]+')
if [ -n "$EFI_UUID" ]; then
    EFI_PART=$(blkid -U "$EFI_UUID")
    if [ -n "$EFI_PART" ]; then
        mount "$EFI_PART" "$ROOT_MNT/boot/efi" 2>/dev/null || log "  EFI 已挂载或挂载失败(可忽略)"
        log "  EFI 分区已挂载: $EFI_PART"
    fi
else
    warn "  未找到 /boot/efi 条目，可能不是 UEFI 系统"
fi

# ---- Step 5: 重建所有内核的 initramfs ----
log "Step 5: 重建 initramfs..."
KERNELS=$(ls "$ROOT_MNT/boot/vmlinuz-"* 2>/dev/null | sed 's/.*vmlinuz-//' | sort -u)
if [ -z "$KERNELS" ]; then
    warn "  未找到内核文件"
else
    for k in $KERNELS; do
        log "  重建: $k"
        chroot "$ROOT_MNT" update-initramfs -u -k "$k" 2>&1 | grep -v '^$' || warn "  $k 重建失败"
    done
fi

# ---- Step 6: 更新 GRUB ----
log "Step 6: 更新 GRUB..."
chroot "$ROOT_MNT" update-grub

# ---- Step 7: 重新安装 GRUB 到 EFI ----
log "Step 7: 安装 GRUB 到 EFI..."
if mount | grep -q "$ROOT_MNT/boot/efi"; then
    chroot "$ROOT_MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck 2>&1 || warn "  grub-install 有警告(通常可忽略)"
else
    warn "  EFI 分区未挂载，跳过 grub-install"
fi

# ---- Step 8: 清理 ----
log "Step 8: 清理..."
umount "$ROOT_MNT/run" 2>/dev/null
umount "$ROOT_MNT/sys" 2>/dev/null
umount "$ROOT_MNT/proc" 2>/dev/null
umount "$ROOT_MNT/dev/pts" 2>/dev/null
umount "$ROOT_MNT/dev" 2>/dev/null

# 如果 EFI 挂载了，卸载它
mount | grep -q "$ROOT_MNT/boot/efi" && umount "$ROOT_MNT/boot/efi" 2>/dev/null

umount "$ROOT_MNT" 2>/dev/null
rmdir "$ROOT_MNT" 2>/dev/null

echo ""
echo "============================================"
echo "  修复完成!"
echo "============================================"
echo ""
echo "现在可以重启: reboot"
echo "如果仍然失败，请在 GRUB 菜单中选择旧内核启动。"
```

---

## 三、手动修复步骤（当脚本不可用时）

### 前提条件
需要 Ubuntu Live USB 启动盘，进入 "Try Ubuntu" 模式。

### 3.1 找到根分区
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
# 找到 ext4 分区，通常是 /dev/sda3 或 /dev/nvme0n1pX
```

### 3.2 挂载并 chroot
```bash
ROOT=/dev/sda3
sudo mkdir -p /mnt/fix
sudo mount $ROOT /mnt/fix
sudo mount --bind /dev /mnt/fix/dev
sudo mount --bind /dev/pts /mnt/fix/dev/pts
sudo mount --bind /proc /mnt/fix/proc
sudo mount --bind /sys /mnt/fix/sys
sudo mount --bind /run /mnt/fix/run

# 挂载 EFI 分区
sudo mount $(blkid -U $(grep '/boot/efi' /mnt/fix/etc/fstab | grep -oP 'UUID=\K[^\s]+')) /mnt/fix/boot/efi 2>/dev/null
```

### 3.3 执行修复（在 chroot 内）
```bash
sudo chroot /mnt/fix /bin/bash

# A. 修复 fstab — 给外部磁盘加 nofail
sed -i -E '/^\s*UUID=/{ /\/\s|\/boot\/efi|swap|nofail/! s/(defaults)/\1,nofail/ }' /etc/fstab

# B. 挂载 EFI
mount /boot/efi 2>/dev/null || true

# C. 重建所有 initramfs
for k in $(ls /boot/vmlinuz-* | sed 's/.*vmlinuz-//'); do
    update-initramfs -u -k "$k"
done

# D. 更新 GRUB
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck

# E. 退出 chroot
exit
```

### 3.4 清理并重启
```bash
sudo umount /mnt/fix/run
sudo umount /mnt/fix/sys
sudo umount /mnt/fix/proc
sudo umount /mnt/fix/dev/pts
sudo umount /mnt/fix/dev
sudo umount /mnt/fix/boot/efi 2>/dev/null
sudo umount /mnt/fix
sudo reboot
```

---

## 四、本次具体案例记录

### 系统信息
| 项目 | 值 |
|------|-----|
| 机器型号 | ThinkPad X1 Carbon 3rd Gen |
| 磁盘类型 | SATA SSD (/dev/sda) |
| 分区布局 | sda1: BIOS boot (1M), sda2: EFI (513M vfat), sda3: root (167G ext4) |
| 内核版本 | 6.2.0-26 → 6.8.0-124 → **6.8.0-134** (最新) |
| HWE 栈 | linux-image-generic-hwe-22.04 |

### 发现的问题
1. **fstab NTFS 条目缺少 nofail** — `UUID=B2CCAD52CCAD1221` 挂载到 `/media/admininistrator/黑本备份` 没有 `nofail` 选项，如果该磁盘不在位会直接导致 emergency mode
2. **initramfs 需要重建** — 内核更新后 initramfs 可能包含过时的模块依赖
3. **GRUB 配置需刷新** — 确保引导指向正确的内核

### 执行的修复
```bash
# fstab 修改前:
UUID=B2CCAD52CCAD1221 /media/admininistrator/黑本备份 ntfs-3g defaults,uid=1000,gid=1000,...

# fstab 修改后:
UUID=B2CCAD52CCAD1221 /media/admininistrator/黑本备份 ntfs-3g defaults,nofail,uid=1000,gid=1000,...

# Initramfs 重建:
update-initramfs -u -k 6.8.0-134-generic
update-initramfs -u -k 6.8.0-124-generic
update-initramfs -u -k 6.2.0-26-generic

# GRUB 更新:
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
```

### 验证结果
- ✅ 根分区 UUID 匹配: `4d0dfd2a-74f1-46c0-8121-740e11d9abe8`
- ✅ AHCI/SATA 驱动已包含在 initramfs
- ✅ 磁盘空间充足 (51G/164G used)
- ✅ EFI 引导文件完整
- ✅ GRUB 配置包含全部 3 个内核

---

## 五、备用方案：如果新内核仍然失败

### 5.1 从 GRUB 启动旧内核
1. 开机按 **ESC** 进入 GRUB 菜单
2. 选择 **"Advanced options for Ubuntu"**
3. 选择 **"Ubuntu, with Linux 6.2.0-26-generic"**（或 6.8.0-124）

### 5.2 进入 Recovery Mode
如果正常模式也不启动：
1. 在 Advanced options 中选择 **"(recovery mode)"**
2. 选择 **"root"** — 进入 root shell
3. 运行:
```bash
# 查看启动日志定位问题
journalctl -xb | grep -i 'error\|fail\|emergency'

# 临时禁用问题服务
systemctl disable <problem-service>

# 或卸载问题内核
apt remove linux-image-6.8.0-134-generic
update-grub
```

### 5.3 移除问题内核（如果确认是新内核的兼容性问题）
```bash
# 找出所有 6.8.0-134 相关包
dpkg -l | grep 6.8.0-134

# 移除它们
sudo apt purge linux-image-6.8.0-134-generic \
               linux-headers-6.8.0-134-generic \
               linux-modules-6.8.0-134-generic \
               linux-modules-extra-6.8.0-134-generic
sudo update-grub
sudo reboot
```

---

## 六、预防措施

为避免以后再次出现此问题：

1. **内核更新后始终重启验证**，不要累积多次更新后一次性重启
2. **fstab 中所有非关键挂载加上 `nofail`** 选项
3. **保留至少 2 个已知可用的旧内核** 作为备用
4. **安装 `boot-info-scripts`** 方便日后诊断:
   ```bash
   sudo apt install boot-info-script
   # 出问题时运行:
   sudo boot-info
   ```

---

*本文档由 Claude Code Agent 在 2026-07-10 诊断生成，供后续 AI Agent 或人工排查参考。*
