#!/usr/bin/env bash
#===============================================================================
# 一键安装脚本：最新 Node.js + Claude Code CLI
# 适用于：Ubuntu 24.04+ / Live USB 应急修复 / 裸机快速部署
# 用法：  bash install-claude-code-ubuntu.sh
#        或  curl -fsSL <raw-url> | bash
#===============================================================================
set -euo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}============================================================${NC}"
          echo -e "${CYAN}  $*${NC}"
          echo -e "${CYAN}============================================================${NC}"; }

# ---- 检测是否在 Ubuntu/Debian 上 ----
if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "检测到系统: $NAME $VERSION_ID"
else
    warn "无法检测系统版本，继续尝试安装..."
fi

# ---- 步骤 1: 安装基础依赖 ----
step "1/5 安装基础依赖 (curl, xz-utils, ca-certificates)"
sudo apt-get update -qq
sudo apt-get install -y -qq curl xz-utils ca-certificates

# ---- 步骤 2: 获取最新 Node.js 版本并下载 ----
step "2/5 获取最新 Node.js LTS 版本"

# Node.js 官方 API：latest 重定向到最新版本目录
NODE_BASE_URL="https://nodejs.org/dist"
LATEST_VERSION=$(curl -fsSL "${NODE_BASE_URL}/latest/SHASUMS256.txt" 2>/dev/null \
    | grep 'node-v.*-linux-x64\.tar\.xz$' \
    | head -1 \
    | grep -oP 'node-v\K[0-9]+\.[0-9]+\.[0-9]+' \
    || true)

if [ -z "$LATEST_VERSION" ]; then
    # 兜底：使用已知的最新版本
    LATEST_VERSION="24.18.0"
    warn "无法自动获取最新版本，使用兜底版本: v${LATEST_VERSION}"
fi

NODE_TARBALL="node-v${LATEST_VERSION}-linux-x64.tar.xz"
NODE_DOWNLOAD_URL="${NODE_BASE_URL}/v${LATEST_VERSION}/${NODE_TARBALL}"

info "最新 Node.js 版本: v${LATEST_VERSION}"
info "下载地址: ${NODE_DOWNLOAD_URL}"

# 下载到 /tmp
cd /tmp
if [ -f "$NODE_TARBALL" ]; then
    info "安装包已存在，跳过下载"
else
    info "正在下载 Node.js (约 30MB)..."
    curl -fsSL --progress-bar -o "$NODE_TARBALL" "$NODE_DOWNLOAD_URL"
    info "下载完成"
fi

# ---- 步骤 3: 安装 Node.js ----
step "3/5 安装 Node.js 到 /usr/local/lib/nodejs"

sudo mkdir -p /usr/local/lib/nodejs
sudo tar -xJf "/tmp/${NODE_TARBALL}" -C /usr/local/lib/nodejs

NODE_DIR="/usr/local/lib/nodejs/node-v${LATEST_VERSION}-linux-x64"
NODE_BIN="${NODE_DIR}/bin"

# 清理旧符号链接（如果存在）
sudo rm -f /usr/bin/node /usr/bin/npm /usr/bin/npx 2>/dev/null || true

# 创建新的符号链接
sudo ln -sf "${NODE_BIN}/node" /usr/bin/node
sudo ln -sf "${NODE_BIN}/npm"  /usr/bin/npm
sudo ln -sf "${NODE_BIN}/npx"  /usr/bin/npx

# 同时把 PATH 写进 /etc/profile.d 以便新 shell 直接可用
echo "export PATH=${NODE_BIN}:\$PATH" | sudo tee /etc/profile.d/nodejs.sh > /dev/null
export PATH="${NODE_BIN}:$PATH"

# ---- 步骤 4: 配置 npm 全局安装（免 sudo）----
step "4/5 配置 npm 用户级全局目录（免 sudo）"

NPM_GLOBAL="$HOME/.npm-global"
mkdir -p "$NPM_GLOBAL"
npm config set prefix "$NPM_GLOBAL"

# 写入 shell 启动文件
for RC in "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$RC" ] && ! grep -q '.npm-global/bin' "$RC" 2>/dev/null; then
        echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> "$RC"
    fi
done
export PATH="$NPM_GLOBAL/bin:$PATH"

# ---- 步骤 5: 安装 Claude Code CLI ----
step "5/5 安装 Claude Code CLI"

info "正在安装 @anthropic-ai/claude-code（全局，免 sudo）..."
npm install -g @anthropic-ai/claude-code

# ---- 清理下载的安装包 ----
info "清理临时文件..."
rm -f "/tmp/${NODE_TARBALL}"

# ---- 验证 ----
echo ""
step "安装完成！版本验证"
echo ""

echo -n "Node.js:  "
if command -v node &>/dev/null; then
    echo -e "${GREEN}$(node --version)${NC}"
else
    echo -e "${RED}未找到${NC}"
fi

echo -n "npm:      "
if command -v npm &>/dev/null; then
    echo -e "${GREEN}$(npm --version)${NC}"
else
    echo -e "${RED}未找到${NC}"
fi

echo -n "Claude:   "
if command -v claude &>/dev/null; then
    CLAUDE_VER=$(claude --version 2>/dev/null || claude version 2>/dev/null || echo 'installed')
    echo -e "${GREEN}${CLAUDE_VER}${NC}"
else
    echo -e "${RED}未找到 — 请执行 source ~/.bashrc 后重试${NC}"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  全部安装完成！                              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  启动 Claude Code:  claude                                   ║${NC}"
echo -e "${GREEN}║  如果新终端找不到命令，请执行:                               ║${NC}"
echo -e "${GREEN}║    source ~/.bashrc                                          ║${NC}"
echo -e "${GREEN}║    export PATH=\$HOME/.npm-global/bin:\$PATH                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
