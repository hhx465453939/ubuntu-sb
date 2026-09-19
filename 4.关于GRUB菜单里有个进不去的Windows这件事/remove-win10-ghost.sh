#!/usr/bin/env bash
# =============================================================================
# remove-win10-ghost.sh —— 删除 Windows「系统保留」幽灵分区（无痛送鬼指南）
#
# 背景：GRUB 菜单里的 "Windows 10 (on /dev/sda1)" 是 os-prober 给 System
# Reserved 残骸挂的假牌位——分区里只有 bootmgr/BCD（19M），没有 Windows 本体
# （C: 盘早被装 Linux 时合并掉了）。
#
# 安全前提（动手前务必照着取证一遍）：
#   - BIOS/MBR 引导，GRUB 在 MBR + 1~2047 扇区间隙，sda1 从 2048 扇区开始
#   - fstab 无该分区引用
#
# 用法：
#   预览（不改任何东西）： sudo env DRY=1 bash remove-win10-ghost.sh
#   正式执行：             sudo bash remove-win10-ghost.sh
#
# ⚠️ 换机器用之前：先把下面 GHOST_UUID 改成你那块「系统保留」分区的真实 UUID
#    （blkid -o value -s UUID /dev/sdXN 查询），防呆校验靠它兜底。
# =============================================================================
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "✗ 请用 sudo 运行本脚本"; exit 1; }

DISK=/dev/sda
PART=1
DEVP="${DISK}${PART}"
GHOST_UUID="D6361B5F361B4043"   # ← 换机器务必改这里
ROOT_EXPECTED="/dev/sda2"       # ← 你的 Linux 根分区
TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/win10-ghost/$TS"

echo "== 目标：删除 $DEVP（Windows「系统保留」引导残留，非系统本体）=="

echo "== [0/5] 防呆校验 =="
sig="$(blkid -o value -s UUID "$DEVP" 2>/dev/null || true)"
if [ "$sig" != "$GHOST_UUID" ]; then
  echo "✗ $DEVP 的 UUID（${sig:-空}）与预期（$GHOST_UUID）不符，磁盘环境变了，中止"
  exit 1
fi
rootsrc="$(findmnt -n -l -o SOURCE / 2>/dev/null | head -1)"
if [ "$rootsrc" != "$ROOT_EXPECTED" ]; then
  echo "✗ 当前根分区是 ${rootsrc:-未知} 而非 $ROOT_EXPECTED，环境不符，中止"
  exit 1
fi
echo "   ✓ UUID 匹配、根分区吻合，环境与取证时一致"

if [ "${DRY:-0}" = "1" ]; then
  echo "== DRY 预览模式：将执行 备份 → sfdisk 删分区 → partprobe → update-grub → 引导备份刷新 → 校验 =="
  echo "   （未做任何修改；去掉 DRY=1 正式执行）"
  exit 0
fi

mkdir -p "$BK"

echo "== [1/5] 备份（前 1MiB 引导区 + 目标分区全量）=="
dd if="$DISK" of="$BK/mbr-and-gap-1MiB.img" bs=1M count=1 status=none
mount -o ro "$DEVP" /mnt
tar -C /mnt -czf "$BK/partition-backup.tar.gz" .
umount /mnt
echo "   ✓ 备份完成：$BK"

echo "== [2/5] 删除分区 =="
umount "$DEVP" 2>/dev/null || true
sfdisk --delete "$DISK" "$PART"
partprobe "$DISK"
sleep 1
if [ -b "$DEVP" ]; then
  echo "✗ $DEVP 仍在内核中，异常，中止后续步骤（分区表可能已改，重启后再核对）"
  exit 1
fi
echo "   ✓ $DEVP 已删除并从内核消失"
echo "   注：sfdisk 收尾若报 'Re-reading the partition table failed: busy' 属预期"
echo "       （根分区就在这块盘上，内核无法整表重读），partprobe 已单独完成通知。"

echo "== [3/5] 刷新 GRUB 配置（移除幽灵菜单项）=="
update-grub > /tmp/update-grub-ghost.log 2>&1 || { tail -20 /tmp/update-grub-ghost.log; echo "✗ update-grub 失败，上面是日志，中止"; exit 1; }
tail -3 /tmp/update-grub-ghost.log
if grep -q "Windows 10" /boot/grub/grub.cfg; then
  echo "⚠ grub.cfg 仍含 'Windows 10' 字样，请人工检查：grep -n Windows /boot/grub/grub.cfg"
else
  echo "   ✓ grub.cfg 已无 Windows 菜单项"
fi

echo "== [4/5] 刷新引导备份 =="
SH=""
[ -x /usr/local/bin/selfheal.sh ] && SH=/usr/local/bin/selfheal.sh
if [ -z "$SH" ]; then
  for c in "$HOME/运维/selfheal/selfheal.sh" /home/*/运维/selfheal/selfheal.sh; do
    [ -x "$c" ] && { SH="$c"; break; }
  done
fi
if [ -n "$SH" ]; then
  if bash "$SH" grub-backup; then
    echo "   ✓ 引导备份已刷新（$SH grub-backup）"
  else
    echo "⚠ grub-backup 返回非零，请手动重跑：bash $SH grub-backup"
  fi
else
  dd if="$DISK" of=/var/lib/selfheal/mbr-latest.img bs=512 count=1 status=none
  echo "   ✓ 未找到 selfheal.sh，已直接刷新 /var/lib/selfheal/mbr-latest.img"
fi

echo "== [5/5] 结果校验 =="
sfdisk -l "$DISK" 2>/dev/null | grep -E "^/dev" || true
echo
echo "✅ 完成。建议重启一次确认：GRUB 菜单只剩 Linux 条目，系统正常进入。"
echo "   腾出的空间成为磁盘头部未分配（若在被删分区后面才有并入价值；在前就别贪）。"
echo "   如需回滚：$BK 里有引导区镜像与分区全量备份。"
