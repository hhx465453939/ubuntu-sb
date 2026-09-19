#!/usr/bin/env bash
# =============================================================================
# uninstall-usb-automount.sh —— 一键彻底卸载 USB 自动挂载服务  v1.1
#
# 用法： sudo bash uninstall-usb-automount.sh
# 卸载前会把组件备份到 /var/backups/usb-automount/uninstall-<时间戳>/
# =============================================================================
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "✗ 请用 sudo 运行本脚本"; exit 1; }

BACKUP_DIR="/var/backups/usb-automount/uninstall-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 先读配置里的挂载根路径（删除配置文件前）
MOUNT_BASE="/media/usb"
if [ -r /etc/default/usb-automount ]; then
  # shellcheck disable=SC1091
  MOUNT_BASE="$( . /etc/default/usb-automount 2>/dev/null; printf '%s' "${MOUNT_BASE:-/media/usb}" )"
fi

echo "==> 停止活跃实例（ExecStop 会顺带卸载并清理各自的挂载点）..."
systemctl list-units 'usb-automount@*' --no-legend --plain 2>/dev/null \
  | awk '{print $1}' \
  | while read -r u; do
      if [ -n "$u" ]; then systemctl stop "$u" || true; fi
    done

echo "==> 备份并移除组件..."
for f in \
  /etc/udev/rules.d/99-usb-automount.rules \
  /etc/systemd/system/usb-automount@.service \
  /usr/local/bin/usb-automount \
  /etc/default/usb-automount; do
  if [ -e "$f" ]; then
    cp -a "$f" "$BACKUP_DIR/"
    rm -f "$f"
  fi
done

systemctl daemon-reload
udevadm control --reload
systemctl reset-failed 'usb-automount@*' 2>/dev/null || true

echo "==> 清理运行时残留（本服务创建的软链与空挂载目录）..."
if [ -d "$MOUNT_BASE" ]; then
  find "$MOUNT_BASE" -maxdepth 1 -type l -delete 2>/dev/null || true
  find "$MOUNT_BASE" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
  rmdir "$MOUNT_BASE" 2>/dev/null \
    || echo "   提示：$MOUNT_BASE 非空（可能仍有挂载未卸），保留待人工检查：findmnt -R $MOUNT_BASE"
else
  echo "   （$MOUNT_BASE 不存在，无需清理）"
fi

echo "✅ 已彻底卸载（备份在 $BACKUP_DIR）"
echo "   如需恢复：把备份文件拷回原路径 + sudo udevadm control --reload + sudo systemctl daemon-reload"
