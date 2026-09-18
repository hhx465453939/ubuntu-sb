#!/usr/bin/env bash
# =============================================================
# selfheal.sh — 开机自愈守护（心跳 / 内存压力哨兵 / 开机守卫 / GRUB 备份）
#
# 源码位置: ./selfheal.sh
# 部署位置: /usr/local/sbin/selfheal.sh（由 install-selfheal.sh 复制）
# 由 systemd 单元调用，一般不手动运行；手动诊断可用:
#   selfheal.sh patrol        # 手动跑一次心跳+压力巡检
#   selfheal.sh boot-guard    # 手动跑一次开机守卫
#   selfheal.sh grub-backup   # 手动备份一次 MBR/GRUB
#   selfheal.sh status        # 查看自愈系统当前状态
# =============================================================
set -u
umask 077

STATE_DIR="/var/lib/selfheal"
HEARTBEAT="$STATE_DIR/heartbeat"            # epoch：最后一次"确认活着"
SHUTDOWN_MARK="$STATE_DIR/shutdown-clean"   # epoch：上次"正常关机"的落盘时间
CRASH_COUNT="$STATE_DIR/crash-count"        # 连续异常开机计数
WATCHDOG_FLAG="$STATE_DIR/WATCHDOG_DISABLED"
SENTINEL_FLAG="$STATE_DIR/SENTINEL_DISABLED"
PSI_COUNT="$STATE_DIR/psi-count"            # 压力哨兵连续超标次数
GRUB_BAK="$STATE_DIR/grub-backup"
HISTORY="$STATE_DIR/boot-history.log"       # 每次开机一行的事件史
WATCHDOG_CONF="/etc/systemd/system.conf.d/90-selfheal-watchdog.conf"

# 压力哨兵阈值：内存 full 停滞 avg10 连续 N 次采样 ≥ P% → 判定整机已抽死 → 强制重启
# （2026-09-18 凌晨那次假死就是这个模式：系统抽搐约 30 分钟后彻底卡死）
PSI_THRESHOLD=90
PSI_MAX_STREAK=6

log()      { logger -t selfheal -p daemon.notice  "$*"; }
log_warn() { logger -t selfheal -p daemon.warning "$*"; }

# ---------- 心跳 + 内存压力哨兵（每分钟由 timer 调用） ----------
do_patrol() {
    mkdir -p "$STATE_DIR"

    # --- ① 心跳：记录"此刻还活着" ---
    date +%s > "$HEARTBEAT.tmp" && mv -f "$HEARTBEAT.tmp" "$HEARTBEAT"

    # --- ② 压力哨兵：抓"整机抽死"的死法，提前强制重启 ---
    if [ -f "$SENTINEL_FLAG" ]; then
        return 0   # 已被熔断（连续异常开机过），等人工排查，见 boot-history.log
    fi
    if [ ! -r /proc/pressure/memory ]; then
        return 0   # 内核没开 PSI，哨兵不可用（本机 6.17 内核有）
    fi

    local psi_full psi_int n
    psi_full=$(awk '/^full/ {for(i=1;i<=NF;i++) if($i ~ /^avg10=/){split($i,a,"=");print a[2]}}' /proc/pressure/memory)
    psi_full=${psi_full:-0}
    psi_int=${psi_full%%.*}
    psi_int=${psi_int:-0}

    if [ "$psi_int" -ge "$PSI_THRESHOLD" ]; then
        n=$(cat "$PSI_COUNT" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$PSI_COUNT"
        log_warn "内存压力哨兵：full 停滞 ${psi_full}%（连续 $n/$PSI_MAX_STREAK 次）"
        if [ "$n" -ge "$PSI_MAX_STREAK" ]; then
            log_warn "内存 full 停滞连续 $n 分钟 ≥${PSI_THRESHOLD}%，判定系统已抽死，强制重启自救"
            echo "$(date '+%F %T') FORCE-REBOOT psi_full=${psi_full}% streak=$n" >> "$HISTORY"
            sync
            # reboot -f 是跳过优雅关机的强制重启：会留下脏文件系统，
            # 由开机时 systemd-fsck-root（fstab passno=1）自动 fsck 修复 —— 这是有意设计的闭环
            systemctl reboot -f || echo b > /proc/sysrq-trigger
        fi
    else
        if [ -f "$PSI_COUNT" ] && [ "$(cat "$PSI_COUNT" 2>/dev/null || echo 0)" -ge 3 ]; then
            log "内存压力哨兵：压力已回落（${psi_full}%），解除警戒"
        fi
        echo 0 > "$PSI_COUNT"
    fi
}

# ---------- 正常关机标记（关机流程末尾由 ExecStop 调用） ----------
do_shutdown_mark() {
    mkdir -p "$STATE_DIR"
    date +%s > "$SHUTDOWN_MARK.tmp" && mv -f "$SHUTDOWN_MARK.tmp" "$SHUTDOWN_MARK"
}

# ---------- 开机守卫（每次开机调用一次） ----------
# 判定上次是怎么死的：关机标记比心跳新 = 正常关机；否则 = 异常掉线
do_boot_guard() {
    mkdir -p "$STATE_DIR"
    local verdict="clean" n

    if [ -f "$HEARTBEAT" ]; then
        if [ -f "$SHUTDOWN_MARK" ] && [ "$SHUTDOWN_MARK" -nt "$HEARTBEAT" ]; then
            verdict="clean"
        else
            verdict="crash"   # 心跳还在、却没有正常关机痕迹 → 崩溃/看门狗重启/断电
        fi
    fi

    if [ "$verdict" = "crash" ]; then
        n=$(cat "$CRASH_COUNT" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$CRASH_COUNT"
        log_warn "检测到异常重启（连续第 $n 次）"
        if [ "$n" -ge 3 ]; then
            circuit_break "连续 $n 次异常开机"
        fi
    else
        echo 0 > "$CRASH_COUNT"
        echo 0 > "$PSI_COUNT"
        # 正常开机 → 自动恢复曾被熔断的自救机制
        if [ -f "$WATCHDOG_FLAG" ] || [ -f "$SENTINEL_FLAG" ]; then
            rm -f "$WATCHDOG_FLAG" "$SENTINEL_FLAG"
            write_watchdog_conf 15
            systemctl daemon-reexec 2>/dev/null || true
            log "正常开机确认，自愈机制（看门狗/压力哨兵）恢复启用"
        fi
    fi

    # --- 记录本次开机 fsck 结果 ---
    local fsck_status="ok" fsck_out
    fsck_out=$(journalctl -b -u systemd-fsck-root.service --no-pager -o cat 2>/dev/null || true)
    if echo "$fsck_out" | grep -qiE "modified|repaired|fixed"; then
        fsck_status="FIXED"
        log_warn "开机 fsck 自动修复了文件系统错误；若频繁出现请检查硬盘健康（smartctl -a）"
    fi

    echo "$(date '+%F %T') verdict=$verdict crash_streak=$(cat "$CRASH_COUNT" 2>/dev/null || echo 0) fsck=$fsck_status" >> "$HISTORY"
    tail -n 100 "$HISTORY" > "$HISTORY.tmp" 2>/dev/null && mv -f "$HISTORY.tmp" "$HISTORY"
}

# ---------- 熔断器：连续 3 次异常开机 → 停掉所有自动自救，防止重启循环 ----------
circuit_break() {
    local reason="$1"
    write_watchdog_conf 0
    systemctl daemon-reexec 2>/dev/null || true
    touch "$WATCHDOG_FLAG" "$SENTINEL_FLAG"
    log_warn "$reason → 自救机制已熔断（看门狗+压力哨兵停用，防止重启循环）。人工排查后正常重启一次即自动恢复。"
}

write_watchdog_conf() {
    local sec="$1"
    mkdir -p /etc/systemd/system.conf.d
    cat > "$WATCHDOG_CONF" <<EOF
# selfheal 看门狗配置（由 selfheal.sh 管理，勿手改）
RuntimeWatchdogSec=${sec}s
RebootWatchdogSec=10min
EOF
}

# ---------- GRUB/MBR 备份（安装时 + 每月定时） ----------
do_grub_backup() {
    local rootdev disk day dir
    rootdev=$(findmnt -no SOURCE / 2>/dev/null) || { log_warn "找不到根分区，跳过备份"; return 1; }
    disk=$(lsblk -no PKNAME "$rootdev" 2>/dev/null | head -1)
    [ -n "$disk" ] || { log_warn "找不到根盘，跳过备份"; return 1; }
    disk="/dev/$disk"

    day=$(date +%F)
    dir="$GRUB_BAK/$day"
    mkdir -p "$dir"
    dd if="$disk" of="$dir/mbr.img" bs=512 count=1 status=none
    cp -a /boot/grub/grub.cfg   "$dir/" 2>/dev/null
    cp -a /etc/default/grub     "$dir/grub-default" 2>/dev/null
    cp -a /etc/fstab            "$dir/" 2>/dev/null
    echo "$rootdev $disk" > "$GRUB_BAK/target.txt"
    cp -f "$dir/mbr.img" "$STATE_DIR/mbr-latest.img"

    # 只保留最近 3 份日期目录
    ls -1dt "$GRUB_BAK"/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
    log "GRUB/MBR 备份完成 → $dir（根盘 $disk）"
}

# ---------- 状态速览（人工诊断用） ----------
do_status() {
    echo "== selfheal 状态 =="
    echo "状态目录: $STATE_DIR"
    if [ -f "$HEARTBEAT" ]; then
        echo "心跳: $(( $(date +%s) - $(cat "$HEARTBEAT") )) 秒前"
    else
        echo "心跳: 无（守护未运行？）"
    fi
    echo "连续异常开机: $(cat "$CRASH_COUNT" 2>/dev/null || echo 0)"
    echo "压力哨兵计数: $(cat "$PSI_COUNT" 2>/dev/null || echo 0)"
    echo "看门狗熔断: $([ -f "$WATCHDOG_FLAG" ] && echo 是 || echo 否)"
    echo "哨兵熔断:   $([ -f "$SENTINEL_FLAG" ] && echo 是 || echo 否)"
    echo "看门狗配置: $(grep RuntimeWatchdogSec "$WATCHDOG_CONF" 2>/dev/null || echo '未配置')"
    echo "MBR 备份:   $(ls -lh "$STATE_DIR/mbr-latest.img" 2>/dev/null | awk '{print $5, $9}' || echo 无)"
    echo
    echo "== 最近开机史 =="
    tail -n 10 "$HISTORY" 2>/dev/null || echo "（暂无记录）"
}

case "${1:-}" in
    patrol)        do_patrol ;;
    shutdown-mark) do_shutdown_mark ;;
    boot-guard)    do_boot_guard ;;
    grub-backup)   do_grub_backup ;;
    status)        do_status ;;
    *) echo "用法: selfheal.sh {patrol|shutdown-mark|boot-guard|grub-backup|status}" >&2; exit 2 ;;
esac
