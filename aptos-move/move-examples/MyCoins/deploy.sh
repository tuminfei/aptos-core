#!/bin/bash

# 部署 MyCoins 项目的脚本

echo "=== 部署 MyCoins 项目 ==="

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

# 注册 DogCoin
echo "注册 DogCoin..."
aptos move run --package-dir . --script-path scripts/register_dog_coin.move --dev

if [ $? -ne 0 ]; then
    echo "注册 DogCoin 失败！"
    exit 1
fi

# 注册 CatCoin
echo "注册 CatCoin..."
aptos move run --package-dir . --script-path scripts/register_cat_coin.move --dev

if [ $? -ne 0 ]; then
    echo "注册 CatCoin 失败！"
    exit 1
fi

# 注册 BirdCoin
echo "注册 BirdCoin..."
aptos move run --package-dir . --script-path scripts/register_bird_coin.move --dev

if [ $? -ne 0 ]; then
    echo "注册 BirdCoin 失败！"
    exit 1
fi

echo "注册成功！"

echo "\n=== MyCoins 项目部署完成 ==="
echo "您现在可以开始使用 DOG、CAT 和 BIRD 代币了！"
