#!/usr/bin/env bash
# =============================================================
# repair-boot.sh — Ubuntu 引导救援脚本（在 Ventoy U盘的 live 系统里运行）
#
# 场景：主机开不了机（GRUB 挂了 / 文件系统脏了 / MBR 被覆盖）
# 用法：sudo bash repair-boot.sh            → 交互菜单
#       sudo bash repair-boot.sh info       → 只看探测结果
#       sudo bash repair-boot.sh fsck       → 修复根分区文件系统
#       sudo bash repair-boot.sh grub       → chroot 重装 GRUB（进不了 Ubuntu 的主力修法）
#       sudo bash repair-boot.sh restore-mbr → 用备份恢复 MBR（引导代码被覆盖时）
#
# 安全设计：
#   · 只认 ext2/3/4、xfs、btrfs 分区为候选根分区 → exfat/ntfs（Ventoy、Windows 分区）天然被排除
#   · 自动排除 live 启动介质所在的盘
#   · dd 恢复 MBR 前要求手动输入目标盘全名，防止手滑
# =============================================================
set -u

G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[1m'; N='\033[0m'
say()  { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}⚠${N} $*"; }
die()  { echo -e "${R}✗${N} $*"; exit 1; }
CANDIDATES=()

# ---------- 环境 ----------
live_check() {
    if [ ! -d /rofs ] && [ ! -d /cdrom ]; then
        warn "当前环境不像 live U盘系统（没有 /rofs 或 /cdrom）。"
        read -r -p "  确定要在真实系统里继续吗？误操作有风险。(输 yes 继续) " a
        [ "$a" = "yes" ] || die "已退出"
    fi
}

# live 启动介质所在盘（它的分区一律排除）
live_disk() {
    local src
    for m in /cdrom /rofs /run/live/medium; do
        src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
        echo "/dev/$(lsblk -rno PKNAME "$src" 2>/dev/null | head -1)"
        return
    done
    echo ""
}

# ---------- 探测候选根分区 ----------
find_ubuntu_roots() {
    CANDIDATES=()
    local skip_disk; skip_disk=$(live_disk)
    while read -r dev type fstype; do
        [ "$type" = "part" ] || continue
        case "$fstype" in ext2|ext3|ext4|xfs|btrfs) ;; *) continue ;; esac
        local d="/dev/$dev"
        [ -b "$d" ] || continue
        [ -n "$skip_disk" ] && [[ "$d" == "$skip_disk"* ]] && continue
        local mnt; mnt=$(mktemp -d /tmp/probe.XXXXXX)
        if mount -o ro "$d" "$mnt" 2>/dev/null; then
            if [ -d "$mnt/etc" ] && [ -e "$mnt/etc/fstab" ] && [ -d "$mnt/boot" ]; then
                CANDIDATES+=("$d")
            fi
            umount "$mnt"
        fi
        rmdir "$mnt" 2>/dev/null
    done < <(lsblk -rno NAME,TYPE,FSTYPE)
}

show_info() {
    echo; echo "${B}── 磁盘总览 ──${N}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL | grep -vE "^(loop|snap)"
    local ld; ld=$(live_disk)
    [ -n "$ld" ] && warn "live 介质所在盘 $ld（已自动排除）"
    echo; echo "${B}── Ubuntu 根分区候选 ──${N}"
    find_ubuntu_roots
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then die "没找到任何像 Ubuntu 根分区的分区"; fi
    local i=0
    for c in "${CANDIDATES[@]}"; do
        i=$((i+1)); say "[$i] $c"
    done
}

pick_root() {
    find_ubuntu_roots
    [ "${#CANDIDATES[@]}" -ge 1 ] || die "没找到候选根分区"
    if [ "${#CANDIDATES[@]}" -eq 1 ]; then
        warn "自动选定唯一候选根分区: ${CANDIDATES[0]}"
        read -r -p "  就它吗？(回车确认 / 输 n 重选) " a
        [ -z "$a" ] || die "已退出，可手动运行: sudo bash $0 info 查看"
        ROOT="${CANDIDATES[0]}"
    else
        local i=0
        for c in "${CANDIDATES[@]}"; do i=$((i+1)); echo "  [$i] $c"; done
        read -r -p "选哪个根分区？输编号: " n
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#CANDIDATES[@]}" ] \
            || die "无效选择"
        ROOT="${CANDIDATES[$((n-1))]}"
    fi
    ROOTDISK="/dev/$(lsblk -rno PKNAME "$ROOT" | head -1)"
    say "选定根分区 $ROOT（所在盘 $ROOTDISK）"
}

ensure_unmounted() {
    local m
    while m=$(findmnt -rn -S "$ROOT" -o TARGET 2>/dev/null) && [ -n "$m" ]; do
        warn "卸载已挂载的 $ROOT（$m）..."
        umount -l "$m" 2>/dev/null || die "无法卸载 $m，请关掉文件管理器窗口后重试"
    done
}

# ---------- 功能 1：fsck ----------
do_fsck() {
    pick_root
    ensure_unmounted
    echo; warn "将对 $ROOT 运行 fsck -y 自动修复（分区必须未挂载）"
    read -r -p "  确认？(回车继续 / Ctrl+C 取消) " a
    fsck -y "$ROOT"; local rc=$?
    if [ $rc -eq 0 ]; then say "文件系统干净，无需修复"
    elif [ $rc -le 3 ]; then say "fsck 已修复错误（exit=$rc）—— 这类脏状态多半是上次硬关机留下的"
    else die "fsck 失败 exit=$rc —— 反复失败说明盘可能真在坏，先备份数据再换盘"; fi
}

# ---------- 功能 2：chroot 重装 GRUB ----------
do_grub() {
    pick_root
    ensure_unmounted
    local m=/mnt
    echo; warn "将把 $ROOT 挂到 $m，chroot 重装 GRUB 到 $ROOTDISK 的 MBR"
    read -r -p "  确认？(回车继续 / Ctrl+C 取消) " a
    mkdir -p "$m"
    mount "$ROOT" "$m" || die "挂载失败"
    local i
    for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "$m$i"; done
    if ! chroot "$m" grub-install "$ROOTDISK"; then
        die "grub-install 失败。若报错找不到平台目录，试试先在 chroot 里跑: apt install --reinstall grub-pc"
    fi
    chroot "$m" update-grub || die "update-grub 失败"
    say "GRUB 已重装（双系统的话 update-grub 会自动找回 Windows 入口，前提是 os-prober 开着）"
    echo; warn "正在清理挂载..."
    for i in /run /sys /proc /dev/pts /dev; do umount "$m$i" 2>/dev/null; done
    umount "$m" 2>/dev/null
    say "完成！现在可以 reboot 拔 U盘了"
}

# ---------- 功能 3：恢复 MBR ----------
do_restore_mbr() {
    pick_root
    local img=""; local d
    echo; echo "${B}── 搜索 MBR 备份 (mbr-latest.img) ──${N}"
    # ① 脚本所在目录（U盘上）② 系统盘上的 /var/lib/selfheal ③ /media 下自动挂载的
    local script_dir; script_dir="$(cd "$(dirname "$0")" && pwd)"
    for d in "$script_dir/mbr-latest.img" \
             "/media"/*/*/mbr-latest.img "/media"/*/mbr-latest.img "/run/media"/*/*/mbr-latest.img; do
        [ -f "$d" ] && { img="$d"; break; }
    done
    if [ -z "$img" ]; then
        local m; m=$(mktemp -d /tmp/mbro.XXXXXX)
        if mount -o ro "$ROOT" "$m" 2>/dev/null; then
            [ -f "$m/var/lib/selfheal/mbr-latest.img" ] && img="$m/var/lib/selfheal/mbr-latest.img"
            umount "$m"
        fi
        rmdir "$m" 2>/dev/null
    fi
    [ -n "$img" ] || die "没找到 MBR 备份。备用品平时放在系统盘 /var/lib/selfheal/ 和 Ventoy U盘上"
    say "找到备份: $img ($(stat -c %s "$img") 字节)"
    warn "将把该备份写入 ${B}$ROOTDISK${N} 的第一个扇区（512 字节 = 引导代码 + 分区表）"
    warn "!! 只在确认 $ROOTDISK 就是原来的系统盘、且分区布局没变过时才继续 !!"
    read -r -p "  手动输入目标盘全名确认（就是 $ROOTDISK）: " t
    [ "$t" = "$ROOTDISK" ] || die "输入不一致，已取消"
    dd if="$img" of="$ROOTDISK" bs=512 count=1 conv=notrunc
    sync
    say "MBR 已恢复。reboot 拔 U盘试试"
}

menu() {
    while true; do
        echo; echo "${B}════ Ubuntu 引导救援 ════${N}"
        echo "  [1] 探测磁盘/根分区"
        echo "  [2] fsck 修复文件系统（黑屏转圈/掉 initramfs 时用）"
        echo "  [3] chroot 重装 GRUB（No bootable device / 直接进 Windows 时用）"
        echo "  [4] 从备份恢复 MBR（引导代码被覆盖时用）"
        echo "  [5] 退出"
        read -r -p "选什么？: " c
        case "$c" in
            1) show_info ;;
            2) do_fsck ;;
            3) do_grub ;;
            4) do_restore_mbr ;;
            5) exit 0 ;;
        esac
    done
}

live_check
case "${1:-}" in
    info)        show_info ;;
    fsck)        do_fsck ;;
    grub)        do_grub ;;
    restore-mbr) do_restore_mbr ;;
    "")          menu ;;
    *) echo "用法: sudo bash $0 [info|fsck|grub|restore-mbr]"; exit 2 ;;
esac
