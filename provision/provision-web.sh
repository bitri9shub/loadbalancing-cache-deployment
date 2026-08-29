#!/bin/bash

# install docker
apt update
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# create docker network shared by flask-app and nginx on this node
docker network create web-net

# create flask app
mkdir -p /opt/app

cat > /opt/app/app.py <<'EOF'
from flask import Flask, jsonify
import redis
import socket
import time

app = Flask(__name__)

r = redis.Redis(host='192.168.56.20', port=6379, decode_responses=True)

CACHE_TTL = 60

def do_expensive_work():
    time.sleep(1)
    return f"generated at {time.time()}"

def handle_request(route_name, use_redis):
    node = socket.gethostname()

    if use_redis:
        cache_key = f"demo:{route_name}"
        cached_value = r.get(cache_key)
        if cached_value is not None:
            return jsonify({
                "source": "redis-cache",
                "data": cached_value,
                "node": node
            })

    value = do_expensive_work()

    if use_redis:
        r.set(cache_key, value, ex=CACHE_TTL)

    return jsonify({
        "source": "db",
        "data": value,
        "node": node
    })

@app.route('/none')
def none():
    return handle_request('none', use_redis=False)

@app.route('/nginx-only')
def nginx_only():
    return handle_request('nginx-only', use_redis=False)

@app.route('/redis-only')
def redis_only():
    return handle_request('redis-only', use_redis=True)

@app.route('/both')
def both():
    return handle_request('both', use_redis=True)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

# run flask app container
docker run -d \
  --name flask-app \
  --restart unless-stopped \
  --network web-net \
  -v /opt/app/app.py:/app/app.py \
  -w /app \
  -p 5000:5000 \
  python:3.11-slim \
  sh -c "pip install flask redis && python app.py"

# create nginx config
mkdir -p /etc/nginx-web

cat > /etc/nginx-web/nginx.conf <<'EOF'
events {}

http {
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=100m inactive=60m use_temp_path=off;

    upstream flask_backend {
        server flask-app:5000;
    }

    server {
        listen 80;

        location /none {
            add_header X-Cache-Status $upstream_cache_status;
            proxy_pass http://flask_backend;
        }

        location /nginx-only {
            proxy_cache my_cache;
            proxy_cache_valid 200 60s;
            add_header X-Cache-Status $upstream_cache_status;
            proxy_pass http://flask_backend;
        }

        location /redis-only {
            add_header X-Cache-Status $upstream_cache_status;
            proxy_pass http://flask_backend;
        }

        location /both {
            proxy_cache my_cache;
            proxy_cache_valid 200 60s;
            add_header X-Cache-Status $upstream_cache_status;
            proxy_pass http://flask_backend;
        }
    }
}
EOF

# run nginx container
docker run -d \
  --name nginx-web \
  --restart unless-stopped \
  --network web-net \
  -p 80:80 \
  -v /etc/nginx-web/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx