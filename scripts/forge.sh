#!/bin/bash

# 打印启动信息
echo "============================================"
echo "启动 Aptos 本地节点集群"
echo "============================================"
echo "测试套件: run_forever"
echo "验证节点数量: 4"
echo "数据目录: ./my-swarm-data"
echo "============================================"
echo "正在启动节点..."
echo "============================================"

# 执行 forge 命令在后台运行
./target/release/forge --suite "run_forever" --num-validators 4 test local-swarm --swarmdir ./my-swarm-data > forge.log 2>&1 &

# 保存进程ID
FORGE_PID=$!

# 等待一段时间让节点启动
echo "等待节点启动..."
sleep 10

# 打印API信息
echo "============================================"
echo "节点启动完成"
echo "============================================"
echo "API 端点信息:"
echo "============================================"

# 检查并打印每个节点的API地址
for i in 0 1 2 3; do
  if [ -f ./my-swarm-data/$i/node.yaml ]; then
    API_ADDRESS=$(grep -A 1 "api:" ./my-swarm-data/$i/node.yaml | grep "address:" | awk '{print $2}' | tr -d '"')
    echo "节点 $i API 地址: http://$API_ADDRESS"
  fi
done

echo "============================================"
echo "Forge 进程正在后台运行 (PID: $FORGE_PID)"
echo "日志输出到: forge.log"
echo "要停止进程，请运行: kill $FORGE_PID"
echo "============================================"