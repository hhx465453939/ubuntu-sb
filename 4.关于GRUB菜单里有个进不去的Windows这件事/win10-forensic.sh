#!/usr/bin/env bash
# =============================================================================
# win10-forensic.sh —— "Win10 双系统"只读取证（不做任何修改）
#
# 目的：搞清楚 /dev/sda 上到底还有没有 Windows、引导链长什么样，
#       为"删除 Win10、只留 Ubuntu"的决策提供证据。全程只读。
# 用法： sudo bash win10-forensic.sh
# =============================================================================
set -u
hr() { echo; echo "===== $* ====="; }

hr "[1] 固件启动模式"
[ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/Legacy（MBR 引导）"

hr "[2] 分区表（fdisk）"
fdisk -l /dev/sda 2>/dev/null || echo "(fdisk 失败)"

hr "[3] 分区签名（blkid）"
blkid /dev/sda* 2>/dev/null

hr "[4] MBR 引导代码归属（前446字节可读字符串）"
dd if=/dev/sda bs=446 count=1 status=none | strings -n 4 | head -8
echo "--- MBR 分区表 64 字节 ---"
dd if=/dev/sda bs=1 skip=446 count=64 status=none | xxd

hr "[5] /etc/default/grub 关键项"
grep -vE '^\s*#|^\s*$' /etc/default/grub 2>/dev/null

hr "[6] grub.cfg 菜单项 / Windows 痕迹"
ls -la /boot/grub/grub.cfg 2>&1
grep -nE 'menuentry|Windows|ntldr|chainloader' /boot/grub/grub.cfg 2>/dev/null | head -30 \
  || echo "(grep 无结果或文件不可读)"

hr "[7] os-prober 扫描其他操作系统"
os-prober 2>&1 || true
echo "(空输出 = 没扫到其他系统)"

hr "[8] 只读探查 sda1（50M NTFS）内容"
mkdir -p /mnt/forensic-sda1
if mount -o ro /dev/sda1 /mnt/forensic-sda1 2>&1; then
  find /mnt/forensic-sda1 -maxdepth 3 2>/dev/null | head -50
  echo "---"
  du -sh /mnt/forensic-sda1 2>/dev/null
  umount /mnt/forensic-sda1
else
  echo "(挂载失败，见上方报错)"
fi
rmdir /mnt/forensic-sda1 2>/dev/null

hr "[9] Ventoy U盘（sdb1）里有什么 ISO（只读）"
mkdir -p /mnt/forensic-sdb1
if mount -o ro /dev/sdb1 /mnt/forensic-sdb1 2>&1; then
  ls -lh /mnt/forensic-sdb1 2>/dev/null | head -20
  umount /mnt/forensic-sdb1
else
  echo "(sdb1 挂载失败或不存在，跳过)"
fi
rmdir /mnt/forensic-sdb1 2>/dev/null

hr "[10] 自愈体系引导备份现状"
ls -la /var/lib/selfheal/ 2>/dev/null || echo "(未见 /var/lib/selfheal)"
tail -5 /var/lib/selfheal/boot-history.log 2>/dev/null

echo
echo "===== 取证完成（全程只读，未做任何修改）====="
