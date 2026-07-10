#!/bin/bash
# ============================================================================
# boot-guard 一键安装脚本
# 用法: bash boot-guard-install.sh
# ============================================================================
set -e

echo "=== Boot Guard 安装 ==="
echo ""

# 1. 主脚本
echo "[1/4] 安装主脚本 /usr/local/sbin/boot-guard..."
sudo cp /home/admininistrator/boot-guard /usr/local/sbin/boot-guard
sudo chmod 755 /usr/local/sbin/boot-guard

# 2. 内核钩子
echo "[2/4] 安装内核钩子..."
sudo tee /etc/kernel/preinst.d/boot-guard > /dev/null << 'EOF'
#!/bin/bash
echo "[boot-guard] $(date) pre-install: $1" >> /var/log/boot-guard.log
/usr/local/sbin/boot-guard check-pre 2>&1 | tee -a /var/log/boot-guard.log
exit 0
EOF
sudo chmod 755 /etc/kernel/preinst.d/boot-guard

sudo tee /etc/kernel/postinst.d/zzz-boot-guard > /dev/null << 'EOF'
#!/bin/bash
KVER="${1:-unknown}"
echo "[boot-guard] $(date) post-install: $KVER" >> /var/log/boot-guard.log
sleep 2
/usr/local/sbin/boot-guard validate-kernel "$KVER" 2>&1 | tee -a /var/log/boot-guard.log
RET=$?
if [ $RET -ne 0 ]; then
    echo "" >> /var/log/boot-guard.log
    echo "============================================" >> /var/log/boot-guard.log
    echo " ⚠️  内核 $KVER initramfs 验证失败！" >> /var/log/boot-guard.log
    echo "    重启前运行: sudo boot-guard check" >> /var/log/boot-guard.log
    echo "    或 GRUB 选旧内核启动" >> /var/log/boot-guard.log
    echo "============================================" >> /var/log/boot-guard.log
fi
exit 0
EOF
sudo chmod 755 /etc/kernel/postinst.d/zzz-boot-guard

# 3. systemd 服务
echo "[3/4] 安装 systemd 服务..."
sudo tee /etc/systemd/system/boot-guard-success.service > /dev/null << 'EOF'
[Unit]
Description=Boot Guard - Mark successful boot
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/sbin/boot-guard mark-boot-ok
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable boot-guard-success.service 2>/dev/null || true

# 4. 日志轮转
echo "[4/4] 配置日志轮转..."
sudo tee /etc/logrotate.d/boot-guard > /dev/null << 'EOF'
/var/log/boot-guard.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    create 644 root root
}
EOF
sudo mkdir -p /var/lib/boot-guard

echo ""
echo "=== 安装完成 ==="
echo "运行诊断: sudo boot-guard check"
echo "一键加固: sudo boot-guard harden"
