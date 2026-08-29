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

# create docker network
docker network create redis-net

# run redis container
docker run -d \
  --name redis-cache \
  --restart unless-stopped \
  --network redis-net \
  -p 6379:6379 \
  redis

# run redis insight container
docker run -d \
  --name redis-insight \
  --restart unless-stopped \
  --network redis-net \
  -p 5540:5540 \
  redislabs/redisinsight:latest

