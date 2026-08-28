#!/bin/bash

apt-get update
apt-get install -y docker.io docker-compose

# Créer le réseau Docker pour ce node
docker network create webnet

mkdir -p /opt/app
cd /opt/app

# Application Python - se connecte au Redis central
cat > app.py << 'EOF'
from flask import Flask, jsonify
import redis
import time
import hashlib
import os
import json

app = Flask(__name__)

# Connexion au Redis CENTRALISÉ
redis_client = redis.Redis(
    host='192.168.56.20',
    port=6379,
    decode_responses=True,
    socket_connect_timeout=5,
    socket_timeout=5,
    retry_on_timeout=True
)

def heavy_computation(n=50000):
    """Simule un calcul lourd"""
    result = 0
    for i in range(n):
        result += int(hashlib.md5(str(i).encode()).hexdigest(), 16)
    return result % 1000000

@app.route('/')
def index():
    return jsonify({
        "node": os.environ.get('HOSTNAME', 'unknown'),
        "message": "OK"
    })

@app.route('/slow')
def slow():
    """Sans aucun cache"""
    start = time.time()
    result = heavy_computation()
    elapsed = (time.time() - start) * 1000
    
    return jsonify({
        "type": "SANS CACHE",
        "node": os.environ.get('HOSTNAME'),
        "compute_time_ms": round(elapsed, 2),
        "result": result,
        "cached": False
    })

@app.route('/cached')
def cached():
    """Cache Nginx (header-based)"""
    start = time.time()
    result = heavy_computation()
    elapsed = (time.time() - start) * 1000
    
    response = jsonify({
        "type": "NGINX CACHE",
        "node": os.environ.get('HOSTNAME'),
        "compute_time_ms": round(elapsed, 2),
        "result": result,
        "cached": False
    })
    response.headers['Cache-Control'] = 'public, max-age=30'
    return response

@app.route('/redis-cache')
def redis_cached():
    """Cache Redis CENTRALISÉ"""
    cache_key = "shared:heavy_result"
    start_total = time.time()
    
    # Vérifier Redis central (réseau ~2-5ms)
    try:
        cached = redis_client.get(cache_key)
        redis_time = (time.time() - start_total) * 1000
    except Exception as e:
        return jsonify({
            "error": "Redis unavailable",
            "details": str(e)
        }), 503
    
    if cached:
        return jsonify({
            "type": "REDIS CACHE HIT (central)",
            "node": os.environ.get('HOSTNAME'),
            "total_time_ms": round(redis_time, 2),
            "redis_lookup_ms": round(redis_time, 2),
            "compute_time_ms": 0,
            "result": int(cached),
            "cached": True,
            "cache_shared": True  # Indique que c'est partagé
        })
    
    # Cache miss - calcul lourd
    compute_start = time.time()
    result = heavy_computation()
    compute_time = (time.time() - compute_start) * 1000
    
    # Stocker dans Redis central (visible par tous les nœuds!)
    redis_client.setex(cache_key, 60, result)
    
    total_time = (time.time() - start_total) * 1000
    
    return jsonify({
        "type": "REDIS CACHE MISS (central, stocké pour tous)",
        "node": os.environ.get('HOSTNAME'),
        "total_time_ms": round(total_time, 2),
        "redis_lookup_ms": round((compute_start - start_total) * 1000, 2),
        "compute_time_ms": round(compute_time, 2),
        "result": result,
        "cached": False,
        "cache_shared": True
    })

@app.route('/redis-stats')
def redis_stats():
    """Infos sur le cache Redis"""
    try:
        info = redis_client.info('stats')
        keys = len(redis_client.keys('*'))
        return jsonify({
            "redis_connected": True,
            "total_keys": keys,
            "key_hits": info.get('keyspace_hits', 0),
            "key_misses": info.get('keyspace_misses', 0),
            "hit_rate": f"{info.get('keyspace_hits', 0) / (info.get('keyspace_hits', 0) + info.get('keyspace_misses', 1)) * 100:.1f}%"
        })
    except Exception as e:
        return jsonify({"redis_connected": False, "error": str(e)})

@app.route('/benchmark')
def benchmark():
    return jsonify({"status": "ok", "node": os.environ.get('HOSTNAME')})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

cat > requirements.txt << 'EOF'
flask==2.3.3
redis==4.6.0
gunicorn==21.2.0
EOF

# Docker Compose - seulement Nginx + App (pas de Redis)
cat > docker-compose.yml << 'EOF'
version: '3'

services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./cache:/var/cache/nginx
    networks:
      - webnet
    depends_on:
      - app

  app:
    build: .
    environment:
      - HOSTNAME=${HOSTNAME}
    networks:
      - webnet

networks:
  webnet:
    external: true
EOF

cat > Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "app:app"]
EOF

cat > nginx.conf << 'EOF'
user nginx;
worker_processes auto;
events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=50m inactive=60s;

    upstream app {
        server app:5000;
    }

    server {
        listen 80;

        location /slow {
            proxy_pass http://app;
            proxy_set_header Host $host;
            add_header X-Cache-Status "BYPASS";
        }

        location /cached {
            proxy_pass http://app;
            proxy_cache my_cache;
            proxy_cache_valid 200 30s;
            proxy_cache_key "$scheme$request_method$host$request_uri";
            add_header X-Cache-Status $upstream_cache_status;
        }

        location /redis-cache {
            proxy_pass http://app;
            add_header X-Cache-Status "REDIS-CENTRAL";
        }

        location / {
            proxy_pass http://app;
        }
    }
}
EOF

mkdir -p cache
docker-compose up --build -d

echo "Web node $(hostname) prêt - connecté au Redis central 192.168.56.20"
