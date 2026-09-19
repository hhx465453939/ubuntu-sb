#!/usr/bin/env bash
# =============================================================================
# usb-automount —— USB/SD 移动存储自动挂载  v1.1
#
# 调用链：U盘插入 → udev 规则(99-usb-automount.rules)
#         → systemd 模板服务 usb-automount@<设备名>.service → 本脚本
#
# 用法（root）：
#   usb-automount add <kname>     # 挂载，如 usb-automount add sdb1
#   usb-automount remove <kname>  # 卸载并清理挂载点
#   usb-automount status          # 查看本服务管理的挂载（普通用户可用）
#
# 日志：journalctl -t usb-automount -f
# 配置：/etc/default/usb-automount
# =============================================================================
set -u

CONFIG="${USB_AUTOMOUNT_CONFIG:-/etc/default/usb-automount}"
STATE_DIR="/run/usb-automount"

# 默认值，可被配置文件覆盖
MOUNT_BASE="/media/usb"
MOUNT_OWNER="root"
MOUNT_GROUP="root"
UMASK_OPT="022"
SYMLINK_FALLBACK=1

[ -r "$CONFIG" ] && # shellcheck disable=SC1090
  . "$CONFIG"

ACTION="${1:-}"
KNAME="${2:-}"
DEV="/dev/${KNAME}"

log() { echo "[usb-automount] $*"; command -v logger >/dev/null 2>&1 && logger -t usb-automount "$*"; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  cat <<'EOF'
用法: usb-automount <add|remove|status> [设备名]
  add sdb1     挂载 /dev/sdb1 到 /media/usb/<卷标>
  remove sdb1  卸载并清理挂载点
  status       查看当前挂载状态
EOF
}

# ---------- 工具函数 ----------

sanitize_name() {
  # 卷标 → 安全目录名：只留字母数字._-，其余转 _，掐头去尾，限 32 字节
  local n
  n=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed -e 's/_\{2,\}/_/g' -e 's/^[._-]\+//' -e 's/[._-]\+$//')
  printf '%s' "${n:0:32}"
}

probe_fstype() {
  # udev 事件与 blkid 探测可能存在竞态，重试几次
  local i t
  for i in 1 2 3 4 5; do
    t=$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    sleep 0.4
  done
  return 1
}

in_fstab() {
  # fstab 里登记过的设备交还给系统管，不抢。
  # 覆盖第一字段的全部合法写法：<kname>、/dev/<kname>、UUID=、LABEL=、PARTUUID=、PARTLABEL=
  local uuid label puuid plabel
  uuid=$(blkid -o value -s UUID "$DEV" 2>/dev/null || true)
  label=$(blkid -o value -s LABEL "$DEV" 2>/dev/null || true)
  puuid=$(lsblk -no PARTUUID "$DEV" 2>/dev/null | head -1)
  plabel=$(lsblk -no PARTLABEL "$DEV" 2>/dev/null | head -1)
  awk -v d="$KNAME" -v u="UUID=$uuid" -v l="LABEL=$label" \
      -v pu="PARTUUID=$puuid" -v pl="PARTLABEL=$plabel" '
    /^[[:space:]]*#/ { next }
    {
      f = $1
      if (f == d || f == "/dev/" d) { found = 1; exit }
      if (u != "UUID=" && f == u) { found = 1; exit }
      if (l != "LABEL=" && f == l) { found = 1; exit }
      if (pu != "PARTUUID=" && f == pu) { found = 1; exit }
      if (pl != "PARTLABEL=" && f == pl) { found = 1; exit }
    }
    END { exit !found }
  ' /etc/fstab 2>/dev/null
}

pick_name() {
  # 挂载点取名：卷标 → UUID 前 8 位 → 设备名
  local label uuid
  label=$(sanitize_name "$(blkid -o value -s LABEL "$DEV" 2>/dev/null || true)")
  [ -n "$label" ] && { printf '%s' "$label"; return; }
  uuid=$(blkid -o value -s UUID "$DEV" 2>/dev/null || true)
  [ -n "$uuid" ] && { printf '%s' "${uuid:0:8}"; return; }
  printf '%s' "$KNAME"
}

claim_mountpoint() { # $1=路径基座 —— mkdir(无-p) 原子抢占，抢不到自动换下一候选
  local base="$1" i cand
  for i in "" -2 -3 -4 -5 -6; do
    cand="${base}${i}"
    [ -L "$cand" ] && continue
    [ -e "$cand" ] && continue
    mkdir "$cand" 2>/dev/null && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

pick_link_path() { # $1=路径基座 —— 返回一个不存在的路径，配合不带 -f 的 ln -s 原子占位
  local base="$1" i cand
  for i in "" -2 -3 -4 -5 -6; do
    cand="${base}${i}"
    if [ ! -e "$cand" ] && [ ! -L "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

unmount_path() { # $1=挂载点  退出码: 0=完全卸载 1=懒卸载(占用) 2=失败仍挂着
  local p="$1" i
  mountpoint -q "$p" 2>/dev/null || return 0
  for i in 1 2 3; do
    umount "$p" 2>/dev/null && return 0
    sleep 0.5
  done
  if umount -l "$p" 2>/dev/null; then
    log "警告：$p 正被占用，已懒卸载——后台写入可能尚未落盘，请勿立即拔盘，等 10 秒再拔更稳妥"
    return 1
  fi
  log "警告：$p 卸载失败，挂载仍存在"
  return 2
}

record_state() { # record_state <mount|symlink> <路径>
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$1" "$2" > "$STATE_DIR/${KNAME}.state"
}

# ---------- add：插入时挂载 ----------

do_add() {
  [ -n "$KNAME" ] || die "add 需要设备名，如: usb-automount add sdb1"
  [ -b "$DEV" ] || die "$DEV 不存在或不是块设备"

  # 纵深防御：mmc 设备（内核名无法区分内置 eMMC 与 SD 卡）必须是可移除介质，
  # 防止规则被改/失效时把内置存储挂进 MOUNT_BASE
  case "$KNAME" in
    mmcblk*)
      local rem
      rem=$(cat "/sys/block/${KNAME%%p*}/removable" 2>/dev/null || echo 0)
      [ "$rem" = "1" ] || { log "跳过 $KNAME：非可移除 mmc 介质（内置 eMMC？）"; exit 0; }
      ;;
  esac

  # 整盘带分区表的情况：交给分区自己的事件处理
  local devtype children
  devtype=$(lsblk -no TYPE "$DEV" 2>/dev/null | head -1)
  if [ "$devtype" = "disk" ]; then
    children=$(lsblk -no NAME "$DEV" 2>/dev/null | tail -n +2 | wc -l)
    if [ "$children" -gt 0 ]; then
      log "跳过 $KNAME：整盘含 $children 个分区，由分区事件处理"
      exit 0
    fi
  fi

  if in_fstab; then
    log "跳过 $KNAME：已在 /etc/fstab 登记，交给系统处理"
    exit 0
  fi

  mkdir -p "$MOUNT_BASE"

  # 清扫历史悬空软链（/run 状态重启即失，软链在持久盘会变孤儿）
  local l
  for l in "$MOUNT_BASE"/*; do
    [ -L "$l" ] || continue
    if [ ! -e "$l" ]; then rm -f "$l"; log "清理悬空软链 $l"; fi
  done

  # 已经挂在任何地方（比如桌面环境抢先挂了）：软链兜底，避免双重挂载
  local mp
  mp=$(findmnt -n -l -o TARGET -S "$DEV" 2>/dev/null | head -1)
  if [ -n "$mp" ]; then
    case "$mp" in
      "$MOUNT_BASE"/*) log "$KNAME 已由本服务挂载于 $mp"; exit 0 ;;
    esac
    if [ "$SYMLINK_FALLBACK" = 1 ]; then
      local link
      link=$(pick_link_path "$MOUNT_BASE/$(pick_name)") || die "无法分配软链路径"
      ln -s "$mp" "$link" 2>/dev/null || die "软链创建失败（并发冲突？）"
      record_state symlink "$link"
      log "$KNAME 已被挂载于 $mp（桌面环境？），已建软链 $link"
    else
      log "$KNAME 已挂载于 $mp，按配置不建软链"
    fi
    exit 0
  fi

  local fstype
  fstype=$(probe_fstype) || { log "跳过 $KNAME：未探测到文件系统（空盘/未知签名）"; exit 0; }
  case "$fstype" in
    swap) log "跳过 $KNAME：swap 分区"; exit 0 ;;
  esac

  # mkdir 原子占位，杜绝同卷标并发触发时互相 overmount
  mp=$(claim_mountpoint "$MOUNT_BASE/$(pick_name)") || die "无法分配挂载点"
  mountpoint -q "$mp" 2>/dev/null && die "$mp 意外成为挂载点（并发冲突），放弃本次挂载"

  # 按文件系统决定挂载选项：FAT/exFAT/NTFS 系让当前用户拥有文件（经典权限坑）
  local uid gid opts=""
  uid=$(id -u "$MOUNT_OWNER" 2>/dev/null) || log "警告：MOUNT_OWNER=$MOUNT_OWNER 无法解析，FAT 系将以 root 属主挂载（请检查 $CONFIG）"
  uid=${uid:-0}
  gid=$(id -g "$MOUNT_GROUP" 2>/dev/null) || true
  gid=${gid:-0}
  case "$fstype" in
    vfat)               opts="uid=${uid},gid=${gid},umask=${UMASK_OPT},utf8" ;;
    exfat)              opts="uid=${uid},gid=${gid},umask=${UMASK_OPT},iocharset=utf8" ;;
    ntfs|ntfs3|fuseblk) opts="uid=${uid},gid=${gid},umask=${UMASK_OPT}" ;;
  esac

  local ok=0
  if [ -n "$opts" ]; then
    mount -o "$opts" "$DEV" "$mp" && ok=1
  else
    mount "$DEV" "$mp" && ok=1
  fi
  # NTFS 双保险：内核 ntfs3 不行就退 ntfs-3g(FUSE)
  if [ "$ok" = 0 ] && [ "$fstype" = "ntfs" ]; then
    mount -t ntfs-3g -o "uid=${uid},gid=${gid},umask=${UMASK_OPT}" "$DEV" "$mp" && ok=1
  fi
  [ "$ok" = 1 ] || { rmdir "$mp" 2>/dev/null; die "$DEV 挂载失败（fstype=$fstype）"; }

  case "$fstype" in
    ext2|ext3|ext4|xfs|btrfs|f2fs)
      # Linux 原生盘：只改挂载点目录属主，盘内文件保持盘上原有属主
      chown "$MOUNT_OWNER:$MOUNT_GROUP" "$mp" 2>/dev/null
      chmod 755 "$mp" 2>/dev/null
      ;;
  esac

  record_state mount "$mp"
  log "已挂载 $DEV ($fstype) → $mp"
  df -h "$mp" 2>/dev/null || true
}

# ---------- remove：拔出时清理 ----------

do_remove() {
  [ -n "$KNAME" ] || die "remove 需要设备名"

  local removed=0 lazy=0 failed=0 rc t p

  # 1) 按状态文件精确清理（add 时登记的）
  if [ -f "$STATE_DIR/${KNAME}.state" ]; then
    while IFS=$'\t' read -r t p; do
      case "$t" in
        mount)
          rc=0; unmount_path "$p" || rc=$?
          [ "$rc" = 1 ] && lazy=1
          [ "$rc" = 2 ] && failed=1
          if [ "$rc" != 2 ]; then
            [ -d "$p" ] && rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null
          fi
          removed=1
          ;;
        symlink)
          [ -L "$p" ] && rm -f "$p"
          removed=1
          ;;
      esac
    done < "$STATE_DIR/${KNAME}.state"
    rm -f "$STATE_DIR/${KNAME}.state"
  fi

  # 2) 兜底：内核挂载表里还有这个设备就扫掉（状态文件丢失/重启后残留）
  #    while-read 按行读，含空格的外来挂载点（桌面 gvfs 按卷标挂载）不会被切词
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rc=0; unmount_path "$p" || rc=$?
    [ "$rc" = 1 ] && lazy=1
    [ "$rc" = 2 ] && failed=1
    case "$p" in
      "$MOUNT_BASE"/*) [ "$rc" != 2 ] && rmdir --ignore-fail-on-non-empty "$p" 2>/dev/null ;;
    esac
    removed=1
  done < <(findmnt -n -l -o TARGET -S "$DEV" 2>/dev/null)

  if [ "$failed" = 1 ]; then
    log "$KNAME 清理未完成：仍有挂载未卸载，请检查 findmnt -R ${MOUNT_BASE}"
  elif [ "$lazy" = 1 ]; then
    log "$KNAME 已清理（含懒卸载，注意上方警告）"
  elif [ "$removed" = 1 ]; then
    log "已清理 $KNAME 的挂载"
  else
    log "$KNAME 无需清理（无关联挂载）"
  fi
}

# ---------- status：状态查看 ----------

do_status() {
  echo "== ${MOUNT_BASE} 下的挂载 =="
  local mounts
  mounts=$(findmnt -n -l -o TARGET,SOURCE,FSTYPE,SIZE 2>/dev/null | grep "^${MOUNT_BASE}/" || true)
  if [ -n "$mounts" ]; then printf '%s\n' "$mounts"; else echo "  (无)"; fi

  echo
  echo "== 软链 =="
  local found=0 l
  for l in "$MOUNT_BASE"/*; do
    [ -L "$l" ] || continue
    echo "  $l -> $(readlink "$l")"
    found=1
  done
  [ "$found" = 0 ] && echo "  (无)"

  echo
  echo "== 活跃服务单元 =="
  local units
  units=$(systemctl list-units 'usb-automount@*' --no-legend --plain 2>/dev/null || true)
  if [ -n "$units" ]; then printf '%s\n' "$units"; else echo "  (无)"; fi
}

# ---------- 入口 ----------

case "$ACTION" in
  add)    do_add ;;
  remove) do_remove ;;
  status) do_status ;;
  *)      usage; exit 2 ;;
esac
