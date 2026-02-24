# Hermes

Real-time communication platform with AI-powered translation, built as a Rust microservices system.

## Repositories

| Repo | Description |
|------|-------------|
| [hermes](https://github.com/bulutcan99/hermes) | This repo — top-level infrastructure (Traefik, shared network) |
| [hermes-be](https://github.com/bulutcan99/hermes-be) | Backend — Rust microservices (Axum, Tonic, SQLx) |
| [hermes-fe](https://github.com/bulutcan99/hermes-fe) | Frontend — React + Vite + TypeScript |

## Architecture

```
Browser
  │
  ▼
Traefik :80  (hermes/docker-compose.yml)
  ├── /             → hermes-fe container :3001  (Vite dev server + HMR)
  ├── /api/v1/auth  → auth-service :8081          (public, no JWT)
  ├── /api/v1/users → user-service :8082          (ForwardAuth + rate limit)
  ├── /api/v1/guilds→ guild-service :8086         (ForwardAuth + rate limit)
  └── /api/v1/channels → channel-service :8083   (ForwardAuth + rate limit)

ForwardAuth flow:
  Traefik → GET /internal/verify (auth-service :8081)
              ├── 200 + X-User-Id, X-User-Role, X-User-Email → forward request
              └── 401 → reject
```

Backend services run on the **host** (not containerized). Infrastructure services (PostgreSQL, Redis, NATS, Prometheus, Grafana) run in Docker via `hermes-be`.

## Structure

```
hermes/
├── docker-compose.yml          # Traefik + hermes-network
├── infra/
│   └── traefik/
│       ├── traefik.yml         # Static config (entrypoints, dashboard, providers)
│       └── dynamic/
│           └── routes.yml      # Routers, middlewares (ForwardAuth, rate limit), services
├── hermes_backend/             # → github.com/bulutcan99/hermes-be
└── hermes-fe/                  # → github.com/bulutcan99/hermes-fe
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- Rust toolchain (`rustup`)
- Node.js 22+

### 1. Start Traefik

```bash
cd hermes
docker compose up -d
```

Creates `hermes-network` and starts Traefik on `:80`. Dashboard available at `http://localhost:8080`.

### 2. Start backend infrastructure

```bash
cd hermes/hermes_backend
make setup      # first time: docker up + migrate + seed
# or
make up         # subsequent runs
```

### 3. Start frontend container

```bash
cd hermes/hermes-fe
docker compose up -d
```

### 4. Start Rust services (on host)

```bash
cd hermes/hermes_backend
make run-auth   # auth-service  :8081
make run-user   # user-service  :8082
```

Everything is now accessible at `http://localhost`.

## Traefik Routing

| Path | Service | Auth |
|------|---------|------|
| `/` | frontend :3001 | none |
| `/api/v1/auth/*` | auth-service :8081 | none |
| `/api/v1/users/*` | user-service :8082 | JWT required |
| `/api/v1/guilds/*` | guild-service :8086 | JWT required |
| `/api/v1/invites/*` | guild-service :8086 | JWT required |
| `/api/v1/channels/*` | channel-service :8083 | JWT required |
| `/swagger-ui` | auth-service :8081 | none |

Rate limit: 100 req/s average, burst 50 (all routes).

## Middlewares

**`jwt-auth`** — Traefik ForwardAuth delegates token validation to `auth-service`:
- Sends the original request headers to `GET /internal/verify`
- On success (200): forwards `X-User-Id`, `X-User-Role`, `X-User-Email` to the upstream service
- On failure (401): rejects the request immediately

**`rate-limit`** — Applied globally, 100 req/s average with burst of 50.

## Ports

| Service | Port |
|---------|------|
| Traefik (HTTP) | 80 |
| Traefik dashboard | 8080 |
| auth-service | 8081 |
| user-service | 8082 |
| channel-service | 8083 |
| chat-service | 8084 |
| voice-service | 8085 |
| guild-service | 8086 |
| presence-service | 8087 |
| PostgreSQL | 5432 |
| Redis | 6379 |
| NATS | 4222 |
| Prometheus | 9090 |
| Grafana | 3000 |
| Mailpit UI | 8025 |
