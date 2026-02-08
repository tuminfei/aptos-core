# PostgreSQL for Aptos

This directory contains a Docker Compose configuration for running PostgreSQL database, which is required for Aptos Indexer and other components.

## Quick Start

### Step 1: Start PostgreSQL

```bash
cd /Users/tuminfei/Documents/Code/Rust/aptos-core/docker/compose/postgres
docker-compose up -d
```

### Step 2: Verify PostgreSQL is running

```bash
# Check container status
docker-compose ps

# Check logs
docker-compose logs postgres

# Test connection
docker exec -it aptos-postgres psql -U aptos -d aptos_indexer -c "SELECT version();"
```

## Configuration

### Environment Variables

The following environment variables are set in the Docker Compose file:

- `POSTGRES_USER`: `aptos` - Database user
- `POSTGRES_PASSWORD`: `aptos123` - Database password
- `POSTGRES_DB`: `aptos_indexer` - Default database name

### Ports

- `5432:5432` - PostgreSQL default port

### Volumes

- `postgres_data`: Persistent volume for database data
- `./init.sql`: Initialization script for database setup

## Connecting to PostgreSQL

### From Host Machine

```bash
# Using psql
psql -h localhost -p 5432 -U aptos -d aptos_indexer

# Using other PostgreSQL clients
# Host: localhost
# Port: 5432
# User: aptos
# Password: aptos123
# Database: aptos_indexer
```

### From Other Docker Containers

If you want to connect to this PostgreSQL instance from other Docker containers, you can use the container name as the hostname:

```yaml
# Example docker-compose.yaml
version: "3.8"

services:
  your-service:
    image: your-image
    depends_on:
      - postgres
    environment:
      DATABASE_URL: postgresql://aptos:aptos123@postgres:5432/aptos_indexer

  postgres:
    image: postgres:14.11
    # Same configuration as above
```

## Maintenance

### Stop PostgreSQL

```bash
docker-compose down
```

### Stop PostgreSQL and remove volumes

```bash
docker-compose down -v
```

### View logs

```bash
docker-compose logs postgres

# Follow logs
docker-compose logs -f postgres
```

### Backup Database

```bash
docker exec -t aptos-postgres pg_dump -U aptos -d aptos_indexer > backup.sql
```

### Restore Database

```bash
docker exec -i aptos-postgres psql -U aptos -d aptos_indexer < backup.sql
```

## Troubleshooting

### Connection Issues

1. **Check if PostgreSQL is running**:
   ```bash
   docker-compose ps
   ```

2. **Check PostgreSQL logs**:
   ```bash
   docker-compose logs postgres
   ```

3. **Verify port is accessible**:
   ```bash
   telnet localhost 5432
   ```

### Performance Issues

1. **Increase memory limit**:
   Edit `docker-compose.yaml` and add `mem_limit` to the postgres service:
   ```yaml
   postgres:
     # ... existing config ...
     mem_limit: 4g
   ```

2. **Adjust PostgreSQL configuration**:
   Create a `postgres.conf` file and mount it to the container:
   ```yaml
   postgres:
     # ... existing config ...
     volumes:
       # ... existing volumes ...
       - ./postgres.conf:/etc/postgresql/postgresql.conf:ro
     command: postgres -c config_file=/etc/postgresql/postgresql.conf
   ```
