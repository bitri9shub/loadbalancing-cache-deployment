#!/bin/bash

apt-get update
apt-get install -y docker.io

# Créer réseau Docker
docker network create redisnet

mkdir -p /opt/redis
cd /opt/redis

# Redis avec persistance et monitoring
cat > docker-compose.yml << 'EOF'
version: '3'

services:
  redis:
    image: redis:7-alpine
    container_name: redis
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro
    command: redis-server /usr/local/etc/redis/redis.conf
    networks:
      - redisnet

  # Redis Insight (UI web optionnelle)
  insight:
    image: redis/redisinsight:latest
    ports:
      - "5540:5540"
    volumes:
      - insight-data:/data
    networks:
      - redisnet

volumes:
  redis-data:
  insight-data:

networks:
  redisnet:
EOF

# Configuration Redis optimisée pour le caching
cat > redis.conf << 'EOF'
# Mémoire max 256MB, eviction LRU quand plein
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistance optionnelle (pour démo, on désactive pour max perf)
save ""

# Logs
loglevel notice

# Accepter connexions externes
bind 0.0.0.0
protected-mode no

# Timeout connexions
timeout 0
tcp-keepalive 300
EOF

docker-compose up -d

echo "Redis centralisé prêt sur 192.168.56.20:6379"
echo "Redis Insight (UI) sur http://192.168.56.20:5540"
