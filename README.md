# DevOps Sandbox Platform

A self-service platform for spinning up isolated, temporary environments on demand. Each environment gets its own Docker network, Nginx route, health monitoring, and auto-destroys after a configurable TTL.

---

## Architecture

```
                          INTERNET
                              │
                         HTTP :80
                              │
                              ▼
                    ┌─────────────────┐
                    │  Nginx Container│  ← single front door
                    │  (port 80)      │
                    └────────┬────────┘
                             │ routes by path /envs/$ENV_ID/
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ env-abc1 │  │ env-def2 │  │ env-ghi3 │  ← app containers
        │ :3000    │  │ :3000    │  │ :3000    │
        └──────────┘  └──────────┘  └──────────┘
              │              │              │
        (own Docker network per env — fully isolated)

  ┌─────────────────────────────────────────────────┐
  │                  Platform Services              │
  │                                                 │
  │  api.py            → HTTP control plane :5000   │
  │  health_poller.py  → polls /health every 30s    │
  │  cleanup_daemon.sh → destroys expired envs      │
  └─────────────────────────────────────────────────┘

  State:  envs/$ENV_ID.json    (runtime, gitignored)
  Logs:   logs/$ENV_ID/        (runtime, gitignored)
  Nginx:  nginx/conf.d/        (generated per env)
```

---

## Prerequisites

- Docker
- Python 3.11+
- `jq` — JSON processor for bash scripts
- `make`

```bash
# Ubuntu/Debian
sudo apt install -y docker.io python3 python3-pip jq make

# Install Python dependencies
pip install flask requests
```

---

## Quick Start

From zero to a running environment in 5 commands:

```bash
# 1. Clone the repo
git clone https://github.com/carvanino/devops-sandbox.git
cd devops-sandbox

# 2. Create required runtime directories
mkdir -p logs/archived envs nginx/conf.d

# 3. Build the demo app image
docker build -t myapp:latest ./platform/app

# 4. Start the platform
make up

# 5. Create your first environment
make create
```

Your environment is live at `http://localhost/envs/<env-id>/`

---

## Full Demo Walkthrough

### Step 1 — Start the platform
```bash
make up
```
Starts Nginx, the cleanup daemon, health poller, and API server.

### Step 2 — Create an environment
```bash
make create
# Enter name: myapp
# Enter TTL [1800]: 300
```
Output:
```
✔ Environment 'myapp' created with ID: env-a1b2
  Access it at: http://localhost/envs/env-a1b2/
  TTL: 300 seconds
```

### Step 3 — Check health
```bash
make health
```
Output:
```
=== Environment Health Status ===
  env-a1b2 (myapp): active
  2026-05-07 10:00:00 - Status: 200, Latency: 0.003s
```

### Step 4 — Simulate an outage
```bash
make simulate ENV=env-a1b2 MODE=pause
```
Wait 90 seconds — the health poller will detect 3 consecutive failures and mark the env as degraded.

### Step 5 — Observe degradation
```bash
make health
# env-a1b2 (myapp): degraded
```

### Step 6 — Recover
```bash
make simulate ENV=env-a1b2 MODE=recover
make health
# env-a1b2 (myapp): active
```

### Step 7 — Auto-destroy
Wait for the TTL to expire (300 seconds from creation). The cleanup daemon destroys the environment automatically. Logs are archived to `logs/archived/env-a1b2/`.

### Step 8 — Tear everything down
```bash
make down
```

---

## API Reference

The control API runs on port 5000.

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/envs` | Create environment |
| GET | `/envs` | List all envs + TTL remaining |
| DELETE | `/envs/:id` | Destroy environment |
| GET | `/envs/:id/logs` | Last 100 lines of app.log |
| GET | `/envs/:id/health` | Last 10 health check results |
| POST | `/envs/:id/outage` | Trigger outage simulation |

### Examples

```bash
# Create
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name": "myapp", "ttl": 600}'

# List
curl http://localhost:5000/envs

# Simulate crash
curl -X POST http://localhost:5000/envs/env-a1b2/outage \
  -H "Content-Type: application/json" \
  -d '{"mode": "crash"}'

# Destroy
curl -X DELETE http://localhost:5000/envs/env-a1b2
```

---

## Makefile Reference

| Target | Description |
|--------|-------------|
| `make up` | Start Nginx, daemon, poller, and API |
| `make down` | Stop everything and destroy all envs |
| `make create` | Create a new environment (interactive) |
| `make destroy ENV=<id>` | Destroy a specific environment |
| `make logs ENV=<id>` | Tail app logs for an environment |
| `make health` | Show health status of all environments |
| `make simulate ENV=<id> MODE=<mode>` | Run outage simulation |
| `make clean` | Wipe all state, logs, and Nginx configs |

---

## Outage Simulation Modes

| Mode | Effect | Recovery |
|------|--------|---------|
| `crash` | Kills the container | Restart manually |
| `pause` | Freezes the container | `MODE=recover` |
| `network` | Disconnects from Docker network | `MODE=recover` |
| `recover` | Restores paused or disconnected container | — |
| `stress` | Spikes CPU for 60 seconds | Auto-recovers |

---

## File Structure

```
devops-sandbox/
├── platform/
│   ├── create_env.sh       # spin up an environment
│   ├── destroy_env.sh      # tear down an environment
│   ├── cleanup_daemon.sh   # TTL-based auto-destroy loop
│   ├── simulate_outage.sh  # chaos engineering tool
│   ├── api.py              # HTTP control plane
│   └── app/                # demo app running inside envs
│       ├── main.py
│       ├── requirements.txt
│       └── Dockerfile
├── nginx/
│   ├── nginx.conf          # main config (includes conf.d/)
│   └── conf.d/             # per-env configs (auto-generated)
├── monitor/
│   └── health_poller.py    # polls /health every 30s
├── logs/                   # gitignored — runtime logs
├── envs/                   # gitignored — runtime state files
├── Makefile
└── README.md
```

---

## Log Shipping Approach

**Approach A (simple)** — on every `create_env.sh`, the script runs:

```bash
docker logs -f $ENV_ID >> logs/$ENV_ID/app.log 2>&1 &
echo $! > logs/$ENV_ID/log_ship.pid
```

The PID is stored so `destroy_env.sh` can kill the process cleanly on teardown. Logs are archived to `logs/archived/$ENV_ID/` before the state file is deleted.

Query logs by env ID:
```bash
make logs ENV=env-a1b2
```

---

## Known Limitations

- **Single VM only** — the platform is not designed for multi-node deployments
- **No persistence** — state lives in JSON files; a VM restart loses all env state
- **Port 80 required** — Nginx must be able to bind port 80 on the host
- **Demo app only** — the platform ships with a simple Flask demo app; production apps would need their own images
- **No authentication** — the API has no auth layer; do not expose port 5000 publicly

---

## GitHub Repository

[https://github.com/carvanino/devops-sandbox](https://github.com/carvanino/devops-sandbox)
