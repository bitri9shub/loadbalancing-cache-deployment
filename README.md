# LB-Lab – Mini-Cluster Docker + Redis Cache

> This repo is a **learning lab**.
> It is not intended to be deployed in production without security and performance adjustments.

---

## Table of Contents

| # | Section | Description |
|---|---------|-------------|
| 1 | Architecture | Overview (diagram) |
| 2 | Vagrant Deployment | Vagrant orchestration process |
| 3 | Installation & Startup | How to launch the cluster with Vagrant |
| 4 | Docker Components | Detailed diagram of containers per VM |
| 5 | Key Caching Concepts | TTL, eviction, hit/miss, local vs shared cache |
| 6 | Nginx Caching in Detail | `proxy_cache_path`, `proxy_cache`, and related directives |
| 7 | Benchmark | Tools & commands to measure response times |

> The content below follows the logical build order of the lab: first understand the architecture, then how Vagrant orchestrates it, then how to start it, then the details of the components and caching concepts, and finally how to measure the results.

---

## 1. Architecture

![architecture.png](architecture/architecture.png)

The diagram shows:

- An Nginx load balancer distributing across three Web nodes (`web1`, `web2`, and `web3`).
- Each Web node has its own local Nginx with an HTTP cache (`my_cache`).
- All applications connect to a central Redis server (`192.168.56.20`).

---

## 2. Vagrant Deployment – Orchestration

![vagrant_deployment.png](architecture/vagrant_deployment.png)

The `Vagrantfile` creates five VMs:

```
lb          -> Load Balancer       (192.168.56.10)
redis       -> Central Redis Cache (192.168.56.20)
web{1..3}   -> Three identical Web nodes (192.168.56.11-13)
```

Each VM runs its own provisioning script:

- `provision/provision-lb.sh` → Installs Docker + launches the Nginx container (load balancing).
- `provision/provision-redis.sh` → Installs Docker + launches Redis and Redis Insight.
- `provision/provision-web.sh` → Installs Docker + launches the container stack (Nginx + Python App) on each node.

Private networks allow internal access between all services without public exposure.

---

## 3. Installation & Startup

```bash
# Clone the repo
git clone https://github.com/<your-repo>/lb-lab.git
cd lb-lab

# Verify VirtualBox + Vagrant are installed
vagrant version   # >= 2.x
virtualbox --help

# Start all VMs (5 machines total)
vagrant up

# Wait ~10-15 min: each script provisions Docker, creates a private network and starts the containers.
```

### Accessing the machines

```bash
# Load Balancer (Nginx)
vagrant ssh lb

# Redis Server
vagrant ssh redis

# Web nodes (example web1)
vagrant ssh web1   # same for web2 / web3
```

### Quick verification

- **LB** → `http://192.168.56.10/none` → JSON response `{"source": "db", "data": "...", "node": "webX"}`
- **Redis Insight** → `http://192.168.56.20:5540`
- **Web node** → `http://192.168.56.{11-13}/redis-only` → JSON indicating `"source": "redis-cache"` after the first call

---

## 4. Docker Components – Containers per VM

![docker_components.png](architecture/docker_components.png)

Container distribution per machine:

- **Load Balancer**: a single Nginx container exposing port `80`.
- **Redis Server**: two containers (`redis-cache`, `redis-insight`) sharing the same Docker network (`redis-net`).
- **Web nodes**: two containers per node — one Nginx container (reverse proxy + HTTP cache) and one Python App container (Flask) — sharing the same Docker network (`web-net`), with the HTTP cache volume mounted in the Nginx container.

---

## 5. Key Caching Concepts

- **Local vs shared cache**: the HTTP cache stores a complete response server-side; it is not shared between multiple instances unless configured as a cluster or via a shared backend like Redis or Memcached.
- **TTL (Time-to-Live)**: the duration an entry remains valid in the cache before being invalidated or refreshed.
- **Eviction policy**: the strategy used when the memory pool is full (`allkeys-lru`, etc.).
- **Cache hit/miss ratio**: a key indicator; the closer to 100%, the better the overall performance.

---

## 6. Nginx Caching in Detail

### `proxy_cache_path` — defining where and how Nginx stores the cache

This directive goes in the `http {}` block and configures a global cache zone, reusable by multiple `location` blocks.

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=100m inactive=60m use_temp_path=off;
```

| Parameter | Role |
|---|---|
| `/var/cache/nginx` | Path on disk (inside the Nginx container) where cache files are physically stored. |
| `levels=1:2` | Organizes cached files into a 2-level subdirectory tree (based on a hash of the URL), to avoid having thousands of files in a single folder — a filesystem optimization with no functional impact. |
| `keys_zone=my_cache:10m` | Creates a named memory zone `my_cache`, of 10 MB, that stores cache metadata (which keys exist, where they point on disk, their state). This name is reused in `proxy_cache` to say "use that zone". |
| `max_size=100m` | Maximum size of cached data on disk before Nginx starts removing the oldest entries. |
| `inactive=60m` | If an entry in the cache is not accessed for 60 minutes, it is removed — regardless of its own freshness TTL. |
| `use_temp_path=off` | Writes directly to the final cache directory rather than to a separate temporary directory — more performant, standard recommended practice. |

### `proxy_cache` and related directives — enabling the cache in a `location`

Once the zone is declared in `http {}`, it is enabled route by route:

```nginx
location /nginx-only {
    proxy_cache my_cache;
    proxy_cache_valid 200 60s;
    add_header X-Cache-Status $upstream_cache_status;
    proxy_pass http://flask_backend;
}
```

| Directive | Role |
|---|---|
| `proxy_cache my_cache` | Enables caching for this `location` block, using the `my_cache` zone defined above. |
| `proxy_cache_valid 200 60s` | Only caches responses with an HTTP 200 (success) status code, and keeps them "fresh" for 60 seconds — consistent with the 60s TTL on the Redis side, for comparing equivalent durations. |
| `add_header X-Cache-Status $upstream_cache_status` | Adds a custom HTTP response header indicating whether it was a `HIT`, `MISS`, or `EXPIRED` — useful for observing live (with `curl -i`) whether Nginx served from its cache or not. |

### Key takeaways

1. The load balancer simply distributes traffic; it does not itself do heavy caching, except for the `proxy_cache` option if enabled there.
2. The real gain comes from *shared caching* — here via Redis — which spares the multiple Web nodes costly recalculations and ensures consistency of temporary data across all instances.

---

## 7. Quick Benchmark

No external benchmarking tool (like ApacheBench) is installed in this lab. Measurement is done simply with `curl`, observing the response time and the `X-Cache-Status` header on each of the 4 routes exposed by a web node:

```bash
# Response time + headers, route by route
curl -w "\ntime: %{time_total}s\n" -i http://192.168.56.10/none
curl -w "\ntime: %{time_total}s\n" -i http://192.168.56.10/nginx-only
curl -w "\ntime: %{time_total}s\n" -i http://192.168.56.10/redis-only
curl -w "\ntime: %{time_total}s\n" -i http://192.168.56.10/both

# Repeat each call a second time to see the cache effect
```

Expected behavior:

```
/none         -> ~1 s on every call, X-Cache-Status: MISS every time (no cache)
/nginx-only   -> ~1 s on the 1st call (MISS), near-instant afterwards (HIT) as long as < 60 s
/redis-only   -> ~1 s on the 1st call, near-instant afterwards (source: redis-cache), but X-Cache-Status stays MISS
/both         -> ~1 s on the 1st call, near-instant afterwards, X-Cache-Status switches to HIT
```

These figures are approximate (the Flask app's `time.sleep(1)` sets the simulated delay); they mainly show **which layer** (Nginx, Redis, or none) is responsible for the observed speedup on each route.