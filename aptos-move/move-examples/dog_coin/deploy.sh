#!/bin/bash

# 部署 Dog Coin 代币的脚本

echo "=== 部署 Dog Coin 代币 ==="

# 1. 编译 Move 模块
echo "1. 编译 Move 模块..."
aptos move compile --package-dir . --dev

if [ $? -ne 0 ]; then
    echo "编译失败！"
    exit 1
fi

echo "编译成功！"

# 2. 发布 Move 模块
echo "\n2. 发布 Move 模块..."
aptos move publish --package-dir . --dev

if [ $? -ne 0 ]; then
    echo "发布失败！"
    exit 1
fi

echo "发布成功！"

# 3. 注册代币
echo "\n3. 注册代币..."
aptos move run --package-dir . --script-path scripts/register.move --dev

if [ $? -ne 0 ]; then
    echo "注册失败！"
    exit 1
fi

echo "注册成功！"

echo "\n=== Dog Coin 代币部署完成 ==="
echo "您现在可以开始使用 DOG 代币了！"
