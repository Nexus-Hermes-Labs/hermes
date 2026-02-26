# Hermes

Real-time communication platform with AI-powered translation, built as a Rust microservices system.

## Repositories

| Repo | Description |
|------|-------------|
| [hermes](https://github.com/bulutcan99/hermes) | This repo — top-level orchestration (Traefik, Makefile, shared network) |
| [hermes-be](https://github.com/bulutcan99/hermes-be) | Backend — Rust microservices (Axum, Tonic, SQLx) |
| [hermes-fe](https://github.com/bulutcan99/hermes-fe) | Frontend — React + Vite + TypeScript |

## Architecture

```
Browser
  │
  ▼
Traefik :80  (hermes/docker-compose.yml)
  ├── /                 → frontend :3001        (Vite dev / serve static)
  ├── /api/v1/auth/*    → auth-service :8081    (public, no JWT)
  ├── /api/v1/users/*   → user-service :8082    (ForwardAuth + rate limit)
  ├── /api/v1/guilds/*  → guild-service :8086   (ForwardAuth + rate limit)
  ├── /api/v1/invites/* → guild-service :8086   (ForwardAuth + rate limit)
  └── /api/v1/channels/*→ channel-service :8083 (ForwardAuth + rate limit)

ForwardAuth flow:
  Traefik → GET /internal/verify (auth-service :8081)
              ├── 200 + X-User-Id, X-User-Role → forward request
              └── 401 → reject

gRPC (service-to-service, not through Traefik):
  guild-service  → channel-service :50053  (CreateDefaultChannels)
  guild-service  → user-service    :50052  (GetUserProfile)
  channel-service→ guild-service   :50056  (GetGuild / ownership check)
```

All services — backend, frontend, and infrastructure — run as Docker containers orchestrated from the root `Makefile`.

## Structure

```
hermes/
├── Makefile                        # Root orchestrator (make dev / up / down / logs)
├── docker-compose.yml              # Traefik + hermes-network
├── infra/
│   └── traefik/
│       ├── traefik.yml             # Static config (entrypoints, dashboard, providers)
│       └── dynamic/
│           └── routes.yml          # Routers, middlewares (ForwardAuth, rate limit), services
├── hermes_backend/                 # → github.com/bulutcan99/hermes-be
│   ├── docker-compose.yml          # All Rust services + PostgreSQL, Redis, NATS, Prometheus, Grafana
│   └── services/
│       ├── auth-service/           # :8081 / gRPC :50051
│       ├── user-service/           # :8082 / gRPC :50052
│       ├── channel-service/        # :8083 / gRPC :50053
│       ├── guild-service/          # :8086 / gRPC :50056
│       └── ...
└── hermes-fe/                      # → github.com/bulutcan99/hermes-fe
    ├── docker-compose.yml          # frontend-dev (hot-reload) / frontend (static)
    ├── Dockerfile                  # Production: node build → serve@14
    └── Dockerfile.dev              # Development: Vite dev server with HMR
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- `make`

### One command

```bash
git clone --recurse-submodules https://github.com/bulutcan99/hermes
cd hermes
make dev
```

`make dev` will:
1. Create `hermes-network` (if not exists)
2. Start Traefik
3. Build and start all backend services + infrastructure (PostgreSQL, Redis, NATS, Prometheus, Grafana)
4. Start the frontend dev server (Vite + HMR)
5. Run all database migrations

Everything is then available at **http://localhost**.

### Other useful commands

```bash
make up          # Start all containers (skip migrations/seed)
make down        # Stop and remove all containers
make restart     # down + dev
make clean       # down + remove volumes

make logs        # Tail all logs
make logs-fe     # Frontend logs
make logs-auth   # auth-service logs
make logs-guild  # guild-service logs
make logs-channel# channel-service logs

make db-migrate  # Run migrations only
make db-seed     # Seed dev data
make db-reset    # Clean + migrate + seed
```

## Traefik Routing

| Path | Service | Auth |
|------|---------|------|
| `/` | frontend :3001 | none |
| `/api/v1/auth/*` | auth-service :8081 | none |
| `/api/v1/users/*` | user-service :8082 | JWT required |
| `/api/v1/guilds/*` | guild-service :8086 | JWT required |
| `/api/v1/invites/*` | guild-service :8086 | JWT required |
| `/api/v1/channels/*` | channel-service :8083 | JWT required |

Rate limit: 100 req/s average, burst 50 (all routes).

## Middlewares

**`jwt-auth`** — Traefik ForwardAuth delegates token validation to `auth-service`:
- Sends the original request headers to `GET /internal/verify`
- On success (200): forwards `X-User-Id`, `X-User-Role` to the upstream service
- On failure (401): rejects immediately

**`rate-limit`** — Applied globally, 100 req/s average with burst of 50.

## Ports

| Service | HTTP | gRPC |
|---------|------|------|
| Traefik (entry) | 80 | — |
| Traefik dashboard | 8080 | — |
| auth-service | 8081 | 50051 |
| user-service | 8082 | 50052 |
| channel-service | 8083 | 50053 |
| guild-service | 8086 | 50056 |
| PostgreSQL | 5432 | — |
| Redis | 6379 | — |
| NATS | 4222 | — |
| Prometheus | 9090 | — |
| Grafana | 3000 | — |
| Mailpit UI | 8025 | — |
