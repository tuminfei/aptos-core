#!/bin/bash

# 脚本：推送 topo_framework 到 GitHub
# 使用方法: ./push_topo_framework.sh

set -e

echo "============================================"
echo "推送 topo_framework 到 GitHub"
echo "============================================"

# 配置
REPO_OWNER="tuminfei"
REPO_NAME="topo_framework"
REPO_URL="git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

# 检查网络连接
echo "检查 GitHub 连接..."
if ! curl -s https://github.com > /dev/null; then
    echo "错误：无法连接到 GitHub，请检查网络连接"
    exit 1
fi

# 检查仓库是否存在
echo "检查仓库是否存在..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL")

if [ "$HTTP_STATUS" = "404" ]; then
    echo ""
    echo "============================================"
    echo "错误：仓库不存在！"
    echo "============================================"
    echo ""
    echo "请在 GitHub 上创建仓库："
    echo ""
    echo "方法 1 - 使用 GitHub CLI："
    echo "  gh repo create ${REPO_OWNER}/${REPO_NAME} --public"
    echo ""
    echo "方法 2 - 使用浏览器："
    echo "  1. 访问 https://github.com/new"
    echo "  2. 仓库名称：${REPO_NAME}"
    echo "  3. 选择公开或私有"
    echo "  4. 不要初始化 README 或 .gitignore"
    echo "  5. 点击 'Create repository'"
    echo ""
    echo "方法 3 - 使用 curl："
    echo "  curl -u '你的用户名' https://api.github.com/user/repos -d '{\"name\":\"${REPO_NAME}\"}'"
    echo ""
    echo "============================================"
    exit 1
elif [ "$HTTP_STATUS" = "403" ] || [ "$HTTP_STATUS" = "401" ]; then
    echo "错误：没有权限访问该仓库 (HTTP $HTTP_STATUS)"
    echo "请检查你的 GitHub 凭据和权限"
    exit 1
elif [ "$HTTP_STATUS" != "200" ]; then
    echo "警告：无法验证仓库状态 (HTTP $HTTP_STATUS)"
    echo "继续尝试推送..."
fi

# 创建临时目录
TMP_DIR="/tmp/topo_framework_push_$$"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "克隆 framework-only 分支..."
git clone --branch framework-only --single-branch /Volumes/Data_dev/Documents/Codes/Rust/aptos-core topo_framework

cd topo_framework

echo "重命名分支为 main..."
git branch -m main

echo "设置远程仓库..."
git remote set-url origin "$REPO_URL"

echo "推送到 GitHub..."
git push -u origin main

echo ""
echo "============================================"
echo "推送成功！"
echo "仓库地址: $REPO_URL"
echo "============================================"

# 清理
cd /
rm -rf "$TMP_DIR"
