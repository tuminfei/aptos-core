#!/bin/bash

# 部署 MyCoins 项目的脚本

echo "=== 部署 MyCoins 项目 ==="

# 1. 编译 Move 模块
echo "1. 编译 Move 模块..."
aptos move compile --dev --skip-fetch-latest-git-deps

if [ $? -ne 0 ]; then
    echo "编译失败！"
    exit 1
fi

echo "编译成功！"

# 2. 发布 Move 模块
echo "\n2. 发布 Move 模块..."
aptos move publish --dev --skip-fetch-latest-git-deps --profile coin-admin

if [ $? -ne 0 ]; then
    echo "发布失败！"
    exit 1
fi

echo "发布成功！"

# 3. 注册代币
echo "\n3. 注册代币..."

# 注册 DogCoin
echo "注册 DogCoin..."
aptos move run --function-id "0x1::managed_coin::register" --type-args "0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::dog_coin::DogCoin" --profile coin-admin

if [ $? -ne 0 ]; then
    echo "注册 DogCoin 失败！"
    exit 1
fi

# 注册 CatCoin
echo "注册 CatCoin..."
aptos move run --function-id "0x1::managed_coin::register" --type-args "0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::cat_coin::CatCoin" --profile coin-admin

if [ $? -ne 0 ]; then
    echo "注册 CatCoin 失败！"
    exit 1
fi

# 注册 BirdCoin
echo "注册 BirdCoin..."
aptos move run --function-id "0x1::managed_coin::register" --type-args "0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::bird_coin::BirdCoin" --profile coin-admin

if [ $? -ne 0 ]; then
    echo "注册 BirdCoin 失败！"
    exit 1
fi

echo "注册成功！"

echo "\n=== MyCoins 项目部署完成 ==="
echo "您现在可以开始使用 DOG、CAT 和 BIRD 代币了！"

# 4. 铸造代币功能
echo "\n4. 铸造代币功能说明："
echo "您可以使用以下命令进行代币铸造："
echo ""
echo "# 铸造 DogCoin"
echo "aptos move run --function-id 0x1::managed_coin::mint --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::dog_coin::DogCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:100000 --profile coin-admin"
echo ""
echo "# 铸造 CatCoin"
echo "aptos move run --function-id 0x1::managed_coin::mint --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::cat_coin::CatCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:100000 --profile coin-admin"
echo ""
echo "# 铸造 BirdCoin"
echo "aptos move run --function-id 0x1::managed_coin::mint --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::bird_coin::BirdCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:100000 --profile coin-admin"
echo ""
echo "注意：参数之间用空格分隔，不要使用方括号或逗号。"
echo "请将 0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d 替换为实际的接收者地址，将相应的金额替换为要铸造的数量。"


# 5. 转账功能
echo "\n5. 转账功能说明："
echo "您可以使用以下命令进行代币转账："
echo ""
echo "# 转账 DogCoin"
echo "aptos move run --function-id 0x1::coin::transfer --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::dog_coin::DogCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:10000 --profile coin-admin"
echo ""
echo "# 转账 CatCoin"
echo "aptos move run --function-id 0x1::coin::transfer --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::cat_coin::CatCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:20000 --profile coin-admin"
echo ""
echo "# 转账 BirdCoin"
echo "aptos move run --function-id 0x1::coin::transfer --type-args 0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::bird_coin::BirdCoin --args address:0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d u64:30000 --profile coin-admin"
echo ""
echo "注意：参数之间用空格分隔，不要使用方括号或逗号。"
echo "请将 0xb06c20bfc513770514517a4518c2a9a1ecbd6d0be3d40f98675efeeee00ada9d 替换为实际的接收者地址，将相应的金额替换为要转账的数量。"

