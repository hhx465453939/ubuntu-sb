#!/usr/bin/env bash
# =============================================================================
# install-usb-automount.sh —— 一键部署 USB 自动挂载服务（内置回环设备自测）  v1.1
#
# 用法： sudo bash install-usb-automount.sh
# 逆向： sudo bash uninstall-usb-automount.sh
#
# 部署内容：
#   /usr/local/bin/usb-automount              主脚本（挂载/卸载/状态）
#   /etc/systemd/system/usb-automount@.service  systemd 模板服务
#   /etc/udev/rules.d/99-usb-automount.rules    udev 触发规则
#   /etc/default/usb-automount                配置文件
# 覆盖旧文件前自动备份到 /var/backups/usb-automount/<时间戳>/
# 自测失败时以退出码 1 结束（组件已装但自动挂载暂不可信）
# =============================================================================
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "✗ 请用 sudo 运行本脚本"; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_USER="${SUDO_USER:-}"
[ -n "$REAL_USER" ] || REAL_USER="$(id -un 1000 2>/dev/null || echo root)"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

BIN=/usr/local/bin/usb-automount
UNIT=/etc/systemd/system/usb-automount@.service
RULE=/etc/udev/rules.d/99-usb-automount.rules
CONF=/etc/default/usb-automount
BACKUP_DIR="/var/backups/usb-automount/$(date +%Y%m%d-%H%M%S)"

echo "==> 部署用户: ${REAL_USER} (${REAL_USER}:${REAL_GROUP})"

# 0) 备份旧文件（如有）
backed=0
for f in "$BIN" "$UNIT" "$RULE" "$CONF"; do
  if [ -e "$f" ]; then
    mkdir -p "$BACKUP_DIR"; cp -a "$f" "$BACKUP_DIR/"; backed=1
  fi
done
[ "$backed" = 1 ] && echo "==> 旧文件已备份到 $BACKUP_DIR"

# 1) 主脚本
install -m 755 "$SRC_DIR/usb-automount.sh" "$BIN"
echo "==> 已安装 $BIN"

# 2) systemd 模板服务
install -m 644 "$SRC_DIR/systemd/usb-automount@.service" "$UNIT"
systemctl daemon-reload
echo "==> 已安装 $UNIT（daemon-reload 完成）"

# 3) udev 规则
install -m 644 "$SRC_DIR/udev/99-usb-automount.rules" "$RULE"
if udevadm verify "$RULE" >/dev/null 2>&1; then
  echo "==> udev 规则语法校验通过"
else
  echo "!! udevadm verify 不可用或有告警（不阻塞安装，继续）"
fi
udevadm control --reload
echo "==> udev 规则已生效"

# 4) 配置文件（已存在则保留用户配置）
if [ -e "$CONF" ]; then
  echo "==> 已存在 $CONF，保留不覆盖（重置办法见运维文档）"
else
  sed -e "s/@MOUNT_OWNER@/${REAL_USER}/g" -e "s/@MOUNT_GROUP@/${REAL_GROUP}/g" \
    "$SRC_DIR/config.default" > "$CONF"
  chmod 644 "$CONF"
  echo "==> 已生成 $CONF"
fi

# 5) 内置自测：回环设备模拟一块 FAT32 U盘，全链路走一遍
#    （loop 设备不走 udev USB 规则，这里直接 start 单元验证 脚本+服务 全链路；
#      udev 规则本身已通过语法校验，真机插拔是最后一道验证，见运维文档）
echo "==> 开始自测（32MB 回环设备模拟U盘）..."
SELFTEST_IMG="$(mktemp /var/tmp/usb-automount-selftest.XXXXXX.img)"
LOOPDEV=""
KN=""
MP=""
# 自测用实际生效的挂载属主（保留旧配置时 MOUNT_OWNER 可能不是部署用户）
TEST_OWNER="$REAL_USER"
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  TEST_OWNER="$( . "$CONF" 2>/dev/null; printf '%s' "${MOUNT_OWNER:-$REAL_USER}" )"
  id -u "$TEST_OWNER" >/dev/null 2>&1 || TEST_OWNER="$REAL_USER"
fi

# 清理顺序：停服务(触发ExecStop卸载) → 兜底umount → 分离loop → 分离成功才删镜像
cleanup() {
  if [ -n "$KN" ]; then systemctl stop "usb-automount@$KN.service" 2>/dev/null || true; fi
  if [ -n "$MP" ] && mountpoint -q "$MP" 2>/dev/null; then
    umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
  fi
  if [ -n "$LOOPDEV" ]; then
    if losetup -d "$LOOPDEV" 2>/dev/null; then
      rm -f "$SELFTEST_IMG"
    else
      echo "!! 自测清理：loop $LOOPDEV 分离失败，镜像保留待手动处理：$SELFTEST_IMG"
    fi
  else
    rm -f "$SELFTEST_IMG"
  fi
}
trap cleanup EXIT

truncate -s 32M "$SELFTEST_IMG"
LOOPDEV="$(losetup -f --show "$SELFTEST_IMG")"
KN="$(basename "$LOOPDEV")"
mkfs.vfat -n USBTEST "$LOOPDEV" >/dev/null || { echo "✗ mkfs.vfat 失败（dosfstools 未装？）"; exit 1; }

echo "    （自测属主：$TEST_OWNER）"
if ! systemctl start "usb-automount@$KN.service"; then
  echo "    ✗ systemctl start 失败（单元日志：journalctl -u usb-automount@$KN --no-pager -n 20）"
fi

FAIL=0
MP="$(findmnt -n -l -o TARGET -S "$LOOPDEV" 2>/dev/null | head -1 || true)"
if [ -n "$MP" ] && df -h "$MP" >/dev/null 2>&1; then
  echo "    ✓ 挂载成功且 df -h 可见: $MP"
else
  echo "    ✗ 未挂载或 df -h 不可见"; FAIL=1
fi

if [ "$FAIL" = 0 ] && sudo -u "$TEST_OWNER" touch "$MP/.write_test" 2>/dev/null \
   && rm -f "$MP/.write_test"; then
  echo "    ✓ 挂载属主 $TEST_OWNER 可读写"
else
  [ "$FAIL" = 0 ] && { echo "    ✗ 挂载属主不可写（检查 $CONF 的 MOUNT_OWNER）"; FAIL=1; }
fi

if ! systemctl stop "usb-automount@$KN.service"; then
  echo "    ✗ systemctl stop 失败"; FAIL=1
fi
LEFT_MNT="$(findmnt -n -l -o TARGET -S "$LOOPDEV" 2>/dev/null | head -1 || true)"
if [ -z "$LEFT_MNT" ] && { [ -z "$MP" ] || [ ! -e "$MP" ]; }; then
  echo "    ✓ 卸载并清理挂载点成功"
else
  echo "    ✗ 卸载/清理不彻底（mount=${LEFT_MNT:-无} dir=${MP:-无}）"; FAIL=1
fi

cleanup
trap - EXIT

if [ "$FAIL" = 0 ]; then
  echo "✅ 自测通过：挂载 / df -h 可见 / 属主读写 / 卸载清理，全链路 OK"
else
  echo "❌ 自测未通过，排查命令：journalctl -t usb-automount --no-pager -n 30"
  echo "   组件已安装但自动挂载暂不可信：修复后重跑本脚本，或用 uninstall-usb-automount.sh 回退"
  exit 1
fi

# 6) 补触发：装服务之前就已插着的盘收不到"插入事件"，这里统一补一发
#    （规则自带 ID_BUS=usb / ID_FS_USAGE 过滤，系统盘和 loop 设备不会命中）
udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
echo "==> 已为当前在位的移动存储补发插入事件（装服务前就插着的盘现在也挂上了）"

# 7) 收尾提示
echo
echo "==> 部署完成。以后U盘插上即自动挂到 /media/usb/<卷标>，拔出自动清理。"
echo "==> 现在已插着的U盘补挂（设备名用 lsblk 看）：sudo usb-automount add sdb1"
echo "==> 或一把触发当前所有块设备重新走规则（规则自带过滤，安全）："
echo "      sudo udevadm trigger --subsystem-match=block --action=add"
echo "==> 查状态：usb-automount status    看日志：journalctl -t usb-automount -f"
