#!/usr/bin/env bash
# =============================================================
# install-selfheal.sh — 开机自愈系统一键安装器
#
# 用法（需要 root）:
#   sudo bash ./install-selfheal.sh
#
# 幂等：重复运行安全，已完成/已达标的步骤自动跳过。
# 装的六层：swap 扩容 → swappiness → zswap → earlyoom → fsck 加固 → 看门狗
# 顺带部署：selfheal 守护 systemd 单元 + MBR 备份 + 救援脚本到 Ventoy
# =============================================================
set -u

if [ "${EUID}" -ne 0 ]; then
    echo "✗ 请用 sudo 运行: sudo bash $0"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_SRC="$SCRIPT_DIR/systemd"
STEP=0
step() { STEP=$((STEP+1)); echo; echo "══ [$STEP/8] $1 ══"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

# 根分区/根盘探测
ROOTDEV=$(findmnt -no SOURCE /)
ROOTDISK=$(lsblk -no PKNAME "$ROOTDEV" | head -1)
ROOTDISK="/dev/$ROOTDISK"
echo "根分区: $ROOTDEV    根盘: $ROOTDISK"

# ─────────────────────────────────────────────
step "swap 容量检查（目标 ≥7G）"
SWAP_SIZE_MiB=$(free -m | awk '/^Swap:/{print $2}')
if [ "${SWAP_SIZE_MiB:-0}" -ge 7168 ]; then
    ok "当前 swap ${SWAP_SIZE_MiB}MiB，已达标，跳过（若刚手动扩过容就是这）"
else
    MEM_AVAIL=$(free -m | awk '/^Mem:/{print $6}')
    SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
    if [ "$MEM_AVAIL" -lt $((SWAP_USED + 1024)) ]; then
        warn "内存装不下已换出的 ${SWAP_USED}MiB（红线），跳过扩容。请空闲时手动按 swap 文档第四节操作"
    else
        echo "  扩容 /swap.img → 8G ..."
        swapoff /swap.img
        rm -f /swap.img
        if ! fallocate -l 8G /swap.img 2>/dev/null; then
            dd if=/dev/zero of=/swap.img bs=1M count=8192 status=progress
        fi
        chmod 600 /swap.img
        mkswap /swap.img >/dev/null
        swapon /swap.img
        ok "swap 已扩到 8G（fstab 已有该路径条目，无需改动）"
    fi
fi

# ─────────────────────────────────────────────
step "内核参数：swappiness=30"
SYSCTL_CONF=/etc/sysctl.d/99-selfheal.conf
cat > "$SYSCTL_CONF" <<'EOF'
# selfheal：开发机内存紧张场景折中值
# 60（默认）太晚动用 swap 会硬扛到抽死；10 太保守、内存更快见顶；30 折中
vm.swappiness = 30
EOF
sysctl -p "$SYSCTL_CONF" >/dev/null
ok "vm.swappiness = $(cat /proc/sys/vm/swappiness)"

# ─────────────────────────────────────────────
step "zswap 压缩缓冲（机械盘收益大）"
if grep -q "zswap.enabled=1" /etc/default/grub 2>/dev/null; then
    ok "已启用，跳过"
else
    cp -a /etc/default/grub "/etc/default/grub.bak-selfheal-$(date +%F)"
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 zswap.enabled=1"/' /etc/default/grub
    if update-grub >/dev/null 2>&1; then
        ok "zswap.enabled=1 已写入内核参数（下次开机生效，原 /etc/default/grub 已备份）"
    else
        warn "update-grub 失败，请检查 /etc/default/grub（已有备份，可回滚）"
    fi
fi

# ─────────────────────────────────────────────
step "earlyoom 内存保镖（第二道保险，systemd-oomd 失守时先杀大户）"
if systemctl is-active --quiet earlyoom; then
    ok "earlyoom 已在运行"
elif command -v earlyoom >/dev/null 2>&1; then
    systemctl enable --now earlyoom && ok "earlyoom 已启用"
else
    if apt-get update -qq 2>/dev/null && apt-get install -y -qq earlyoom >/dev/null 2>&1; then
        systemctl enable --now earlyoom && ok "earlyoom 已安装并启用"
    else
        warn "安装失败（多半是网络问题）。不影响其他层，稍后手动: sudo apt install earlyoom"
    fi
fi

# ─────────────────────────────────────────────
step "fsck 开机自修加固（本层是"开机自动修复"的主力）"
PASSNO=$(awk '!/^#/ && $2=="/" {print $6}' /etc/fstab)
if [ "$PASSNO" = "1" ]; then
    ok "fstab 根分区 passno=1：开机检测到脏文件系统会自动 fsck 修复（systemd 内置，无需额外装）"
else
    warn "fstab 根分区 passno=$PASSNO（应为 1），请人工检查 /etc/fstab"
fi
tune2fs -c 30 -i 1m "$ROOTDEV" >/dev/null 2>&1 \
    && ok "已设置每挂载 30 次或每 1 个月，开机强制深度检查一次 $ROOTDEV" \
    || warn "tune2fs 设置失败（不影响 passno=1 的自动修复）"

# ─────────────────────────────────────────────
step "硬件看门狗（卡死自动重启的兜底层）"
if ls /dev/watchdog* >/dev/null 2>&1 || modprobe iTCO_wdt 2>/dev/null && ls /dev/watchdog* >/dev/null 2>&1; then
    mkdir -p /etc/modules-load.d /etc/systemd/system.conf.d
    echo "iTCO_wdt" > /etc/modules-load.d/selfheal-watchdog.conf
    cat > /etc/systemd/system.conf.d/90-selfheal-watchdog.conf <<'EOF'
# selfheal 看门狗（由 install-selfheal.sh 写入；连续 3 次异常开机后 selfheal.sh 会自动临时停用）
RuntimeWatchdogSec=15s
RebootWatchdogSec=10min
EOF
    systemctl daemon-reexec 2>/dev/null && ok "看门狗已启用：系统卡死 15 秒内硬件强制重启（daemon-reexec 已即时生效）"
else
    warn "本机没有可用的硬件看门狗（无 /dev/watchdog），跳过。压力哨兵层会补位"
fi

# ─────────────────────────────────────────────
step "部署 selfheal 守护（心跳/压力哨兵/开机守卫/关机标记/GRUB 备份）"
install -m 755 "$SCRIPT_DIR/selfheal.sh" /usr/local/sbin/selfheal.sh
install -m 644 "$SYSTEMD_SRC"/selfheal-*.service /etc/systemd/system/
install -m 644 "$SYSTEMD_SRC"/selfheal-*.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now selfheal-heartbeat.timer  >/dev/null 2>&1 && ok "心跳+压力哨兵：每 60 秒巡检"
systemctl enable selfheal-boot-guard.service     >/dev/null 2>&1 && ok "开机守卫：判定上次死法 + fsck 留痕 + 熔断器"
systemctl enable selfheal-shutdown-mark.service  >/dev/null 2>&1 && ok "正常关机标记：关机时落盘留痕"
systemctl enable --now selfheal-grub-backup.timer >/dev/null 2>&1 && ok "GRUB/MBR 备份：每月 1 日自动更新"

# 首次立即执行：备份一份 MBR + 打一个心跳
/usr/local/sbin/selfheal.sh grub-backup && ok "首次 MBR/GRUB 备份完成 → /var/lib/selfheal/"
/usr/local/sbin/selfheal.sh patrol

# ─────────────────────────────────────────────
step "救援脚本派发（放到 Ventoy U盘上，开机进不去时用）"
VENTOY_COPIED=0
for vd in /media/*/Ventoy* /run/media/*/Ventoy* /media/*/*; do
    if [ -d "$vd" ] && mountpoint -q "$vd" 2>/dev/null && df -T "$vd" 2>/dev/null | grep -qiE "exfat|vfat|ntfs"; then
        cp -f "$SCRIPT_DIR/repair-boot.sh" "$vd/" 2>/dev/null \
            && cp -f /var/lib/selfheal/mbr-latest.img "$vd/" 2>/dev/null \
            && ok "已复制 repair-boot.sh + mbr-latest.img → $vd" && VENTOY_COPIED=1 && break
    fi
done
[ "$VENTOY_COPIED" -eq 0 ] && warn "未检测到挂载的 Ventoy U盘。下次插上 U盘后手动复制:
     cp ./repair-boot.sh /var/lib/selfheal/mbr-latest.img <U盘挂载点>/"

# ─────────────────────────────────────────────
echo
echo "════════ 安装完成 · 验证清单 ════════"
echo "  free -h                          # swap 应为 8G"
echo "  sysctl vm.swappiness             # 应为 30"
echo "  systemctl status earlyoom        # 应 active（若装上了）"
echo "  ls /dev/watchdog*                # 看门狗是否可用"
echo "  systemctl list-timers selfheal*  # 两个 timer 应在列"
echo "  /usr/local/sbin/selfheal.sh status   # 自愈系统状态速览"
echo
echo "  重启一次让 zswap 生效；重启后 cat /sys/module/zswap/parameters/enabled 应为 Y"
echo "  事件史看这里: /var/lib/selfheal/boot-history.log"
