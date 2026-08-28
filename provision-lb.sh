#!/bin/bash

apt-get update
apt-get install -y nginx apache2-utils curl jq docker.io

cat > /etc/nginx/sites-available/default << 'EOF'
upstream backend {
    server 192.168.56.11:80;
    server 192.168.56.12:80;
    server 192.168.56.13:80;
}

server {
    listen 80;
    
    location / {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        add_header X-Upstream $upstream_addr;
    }
}
EOF

systemctl restart nginx

# Script de démonstration du cache partagé
cat > /usr/local/bin/demo-cache << 'SCRIPT'
#!/bin/bash
set -e

echo "=========================================="
echo "  DÉMONSTRATION CACHE REDIS CENTRALISÉ"
echo "=========================================="
echo ""

REDIS_IP="192.168.56.20"

echo "1. Vérification Redis central..."
if curl -s http://$REDIS_IP:6379 > /dev/null 2>&1 || true; then
    echo "   ✓ Redis accessible sur $REDIS_IP:6379"
fi
echo ""

echo "2. Test SANS CACHE (/slow) - chaque nœud recalcule"
echo "   3 requêtes, même nœud ou pas → toujours lent"
for i in 1 2 3; do
    time_ms=$(curl -s http://localhost/slow | jq -r '.compute_time_ms')
    node=$(curl -s http://localhost/slow | jq -r '.node')
    echo "   Requête $i: ${time_ms}ms sur $node"
done
echo ""

echo "3. Test CACHE NGINX (/cached) - cache par nœud"
echo "   Premier appel sur un nœud → MISS (lent)"
echo "   Deuxième appel sur MÊME nœud → HIT (rapide)"
echo "   Mais changement de nœud → MISS à nouveau!"
echo ""
echo "   3 requêtes rapides (même nœud probable):"
for i in 1 2 3; do
    cache_status=$(curl -s -I http://localhost/cached | grep -i x-cache-status | awk '{print $2}')
    time_ms=$(curl -s http://localhost/cached | jq -r '.compute_time_ms')
    echo "   Requête $i: $cache_status, ${time_ms}ms"
    sleep 0.1
done
echo ""

echo "4. Test CACHE REDIS CENTRAL (/redis-cache) - PARTAGÉ!"
echo "   Premier appel → MISS (calcul sur un nœud)"
echo "   TOUS les suivants → HIT (même sur AUTRES nœuds)"
echo ""

echo "   Appel 1 (premier, MISS attendu):"
r1=$(curl -s http://localhost/redis-cache)
echo "   Node: $(echo $r1 | jq -r '.node'), Type: $(echo $r1 | jq -r '.type'), Time: $(echo $r1 | jq -r '.total_time_ms')ms"
echo ""

echo "   Appels 2-5 (HIT attendu, nœuds aléatoires):"
for i in 2 3 4 5; do
    ri=$(curl -s http://localhost/redis-cache)
    node=$(echo $ri | jq -r '.node')
    cached=$(echo $ri | jq -r '.cached')
    time_ms=$(echo $ri | jq -r '.total_time_ms')
    echo "   Appel $i: node=$node, cached=$cached, time=${time_ms}ms"
    sleep 0.05
done
echo ""

echo "5. Stats Redis:"
curl -s http://localhost/redis-stats | jq .
echo ""

echo "=========================================="
echo "  CONCLUSION"
echo "=========================================="
echo "Sans cache:        Chaque requête = calcul lent"
echo "Nginx cache:       Rapide, mais isolé par nœud"
echo "Redis central:     Rapide ET partagé entre tous les nœuds!"
echo ""
echo "Le cache centralisé évite que web2 et web3"
echo "recalculent ce que web1 a déjà fait."
SCRIPT

chmod +x /usr/local/bin/demo-cache

# Benchmark comparatif
cat > /usr/local/bin/benchmark-all << 'SCRIPT'
#!/bin/bash
echo "=== Benchmark SANS CACHE ==="
ab -n 30 -c 1 http://localhost/slow 2>&1 | grep -E "(Requests per|Time per|Percentage)"

echo ""
echo "=== Benchmark AVEC CACHE REDIS ==="
ab -n 100 -c 10 http://localhost/redis-cache 2>&1 | grep -E "(Requests per|Time per|Percentage)"
SCRIPT

chmod +x /usr/local/bin/benchmark-all

echo "LB prêt. Commandes disponibles:"
echo "  demo-cache      → Démonstration visuelle du cache"
echo "  benchmark-all   → Tests de charge comparatifs"
