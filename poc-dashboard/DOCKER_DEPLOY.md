# POC Dashboard Docker 部署

本文档用于在服务器上直接用 Docker 构建并启动 POC Dashboard 前后端服务。

## 文件说明

- `backend/Dockerfile`: 构建 FastAPI 后端镜像。
- `frontend/Dockerfile`: 构建 React/Vite 静态前端，并用 Nginx 提供服务。
- `frontend/nginx.conf`: 前端静态服务配置，同时反向代理 `/api/v1` 和 `/ws` 到后端容器。
- `docker-compose.yml`: 编排前后端服务。

`docker-compose.yml` 已为每个服务设置资源限制：

```yaml
cpus: "2.0"
mem_limit: 2g
```

## 配置

Compose 默认挂载当前目录的 `config.docker.yaml` 到后端容器 `/app/config.yaml`。该文件已经把 SQLite 数据库放到 `/app/data/poc_dashboard.db`，并通过 `./data:/app/data` 持久化到宿主机。

如果 Dashboard 需要自动读取本机测试集群目录，保留：

```yaml
cluster_dir: "/app/poc-validator-cluster"
```

`docker-compose.yml` 已将宿主机 `./poc-validator-cluster` 只读挂载到该路径。

默认配置假设链节点运行在 Docker 宿主机上：

```yaml
chain:
  rest_url: "http://host.docker.internal:36183/v1"
  chain_id: 4
```

此时链节点 REST 服务需要监听 `0.0.0.0:36183` 或宿主机网卡地址；如果只监听 `127.0.0.1:36183`，容器通常无法访问。

如果链节点在另一台机器上，把 `config.docker.yaml` 中的 REST 地址改成服务器 IP 或域名：

```yaml
chain:
  rest_url: "http://链节点IP或域名:36183/v1"
```

## 构建并启动

在 `poc-dashboard` 目录执行：

```bash
mkdir -p data
docker compose build
docker compose up -d
```

查看状态：

```bash
docker compose ps
docker compose logs -f backend
docker compose logs -f frontend
```

访问：

```text
http://服务器IP或域名:35173
```

后端健康检查：

```bash
curl http://服务器IP或域名:35173/api/v1/system/health
```

## 更新部署

拉取或上传新代码后执行：

```bash
docker compose build --no-cache
docker compose up -d
```

停止服务：

```bash
docker compose down
```
