-- 创建扩展
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 授予权限
GRANT ALL PRIVILEGES ON DATABASE aptos_indexer TO aptos;

-- 切换到 aptos_indexer 数据库\c aptos_indexer;

-- 创建必要的 schema（如果不存在）
CREATE SCHEMA IF NOT EXISTS public;

-- 授予 schema 权限
GRANT ALL ON SCHEMA public TO aptos;

-- 设置默认 schema
ALTER USER aptos SET search_path TO public;
