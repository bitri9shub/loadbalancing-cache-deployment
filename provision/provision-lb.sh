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

# create nginx config
mkdir -p /etc/nginx-lb

cat > /etc/nginx-lb/nginx.conf << 'NGINXCONF'
events {}

http {
    upstream web_backend {
        server 192.168.56.11:80;
        server 192.168.56.12:80;
        server 192.168.56.13:80;
    }

    server {
        listen 80;

        location / {
            proxy_pass http://web_backend;
        }
    }
}
NGINXCONF

# run nginx container
docker rm -f nginx-lb 2>/dev/null

docker run -d \
  --name nginx-lb \
  --restart unless-stopped \
  -p 80:80 \
  -v /etc/nginx-lb/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx