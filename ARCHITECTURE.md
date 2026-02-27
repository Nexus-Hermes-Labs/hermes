# Hermes Architecture

Hermes is a real-time communication platform with AI-powered translation. The system is built as a Rust microservices backend with a React frontend, unified behind a Traefik reverse proxy.

---

## Repository Layout

```
hermes/
├── docker-compose.yml          # Traefik + shared hermes-network
├── infra/
│   └── traefik/
│       ├── traefik.yml         # Static config (entrypoints, providers, metrics)
│       └── dynamic/
│           └── routes.yml      # Backend routes, ForwardAuth middleware, rate limiting
├── hermes_backend/             # Rust Cargo workspace (12 services + 2 shared crates)
│   ├── Cargo.toml              # Workspace-level deps, lint policy, profiles
│   ├── Makefile                # Dev workflow commands
│   ├── docker-compose.yml      # Infrastructure services (Postgres, Redis, NATS, ...)
│   └── services/
│       ├── common/             # Shared models, errors, JWT, observability, messaging
│       ├── auth-service/       # Authentication & session management (port 8081)
│       ├── user-service/       # User profiles & relationships (port 8082)
│       ├── channel-service/    # Channel CRUD (port 8083)
│       ├── guild-service/      # Guild & invite management (port 8086)
│       └── ...                 # 8 more services (stubbed, see Services section)
└── hermes-fe/                  # React + Vite frontend
    ├── Dockerfile.dev           # node:22-alpine, source-mounted for HMR
    ├── docker-compose.yml       # Traefik-labeled frontend container
    └── vite.config.ts           # host: 0.0.0.0, hmr.clientPort: 80
```

---

## Services

| Service | HTTP Port | gRPC Port | Status | Domain |
|---|---|---|---|---|
| `auth-service` | 8081 | 50051 | Complete | Register, login, logout, token refresh, email verification, ForwardAuth handler |
| `user-service` | 8082 | 50052 | ~60% | User profiles, relationships (friends/block), privacy settings, badges |
| `channel-service` | 8083 | — | Stubbed | Text/voice channels within guilds |
| `chat-service` | 8084 | — | Stubbed | Message storage, history, reactions |
| `voice-service` | 8085 | — | Stubbed | WebRTC signalling |
| `guild-service` | 8086 | — | ~40% | Guild CRUD, member management, invite links |
| `presence-service` | 8087 | — | Stubbed | Online/offline/away tracking via Redis |
| `realtime-service` | 8092 | — | Stubbed | WebSocket gateway, NATS fanout to clients |
| `media-service` | 8088 | — | Stubbed | File uploads, avatar storage |
| `notification-service` | 8089 | — | Stubbed | Push notifications |
| `search-service` | 8090 | — | Stubbed | Full-text search |
| `ai-service` | 8091 | — | Stubbed | Real-time translation pipeline |

### Shared crates

- **`common`** — JWT manager, observability (tracing + metrics), NATS event publisher, Redis helpers, shared domain errors
- **`common-config`** — Figment-based configuration loading from environment / `.env`

---

## Infrastructure Services

All started via `hermes_backend/docker-compose.yml`.

| Container | Port(s) | Purpose |
|---|---|---|
| `hermes-postgres` | 5432 | PostgreSQL 16 — single shared DB (MVP) |
| `hermes-redis` | 6379 | Redis 7 — caching, session tokens, presence |
| `hermes-nats` | 4222 / 8222 | NATS 2.10 with JetStream — async event bus |
| `hermes-prometheus` | 9090 | Metrics scraping |
| `hermes-grafana` | 3000 | Metrics dashboards (admin/admin) |
| `hermes-mailpit` | 1025 / 8025 | SMTP catcher for dev email (UI at :8025) |
| `hermes-schemathesis` | — | API contract testing (profile: `testing`) |

---

## Edge Proxy: Traefik

Traefik v3.3 is the single entry point for all external traffic. It runs in its own top-level `docker-compose.yml` (separate from the infra compose) and creates the shared `hermes-network`.

### Entrypoints

| Entrypoint | Port | Use |
|---|---|---|
| `web` | 80 | All client traffic |
| `traefik` | 8080 | Dashboard (dev only, insecure) |

### Providers

- **Docker provider** — auto-discovers containers on `hermes-network` via Traefik labels (`traefik.enable=true`). Used for the frontend container.
- **File provider** — watches `infra/traefik/dynamic/` for backend route config (hot-reload). Used for the Rust services.

### Middlewares

| Name | Type | Config |
|---|---|---|
| `jwt-auth` | ForwardAuth | Calls `http://hermes-auth-service:8081/internal/verify`; on 200 forwards `X-User-Id`, `X-User-Role`, `X-User-Email` headers |
| `rate-limit` | RateLimit | 100 req/s average, burst 50 |

### Routing Table

| Router | Rule | Auth | Backend |
|---|---|---|---|
| `auth-public` | `PathPrefix(/api/v1/auth)` | rate-limit only | auth-service :8081 |
| `user-service` | `PathPrefix(/api/v1/users)` | jwt-auth + rate-limit | user-service :8082 |
| `channel-nested` | `PathRegexp(^/api/v1/guilds/[^/]+/channels)` (priority 30) | jwt-auth + rate-limit | channel-service :8083 |
| `channel-service` | `PathPrefix(/api/v1/channels)` | jwt-auth + rate-limit | channel-service :8083 |
| `guild-service` | `PathPrefix(/api/v1/guilds) \|\| PathPrefix(/api/v1/invites)` | jwt-auth + rate-limit | guild-service :8086 |
| `frontend` | `PathPrefix(/)` (priority 1) | none | hermes-frontend :3001 |

---

## Authentication Flow

```
Client
  │
  ▼
Traefik :80
  │
  ├── /api/v1/auth/** ──────────────────────────────────────► auth-service :8081
  │                                                              (no JWT check)
  │
  └── /api/v1/** ──► ForwardAuth ──► GET /internal/verify
                                          auth-service :8081
                                               │
                              ┌────────────────┴─────────────────┐
                              │ 200 + X-User-Id                   │ 401
                              │      X-User-Role                  │
                              │      X-User-Email                 ▼
                              ▼                              Traefik returns 401
                     upstream service                        to client
                     (headers injected)
```

The `/internal/verify` handler (`auth-service/src/presentation/http/handlers/forward_auth.rs`):
1. Reads `Authorization: Bearer <token>` from the forwarded request
2. Calls `jwt_manager.verify_access_token(token)`
3. Returns `200` with identity headers on success, `401` on any failure

Downstream services read identity from headers via the `RequestUser` Axum extractor (`x-user-id`, `x-user-role`, `x-user-email`). No JWT parsing happens outside auth-service.

---

## Service-to-Service Communication

### Synchronous (gRPC)
Used when one service needs an immediate response from another during a request.

Current usage:
- `auth-service` → `user-service` (gRPC): creates a user profile on registration

Proto definitions live in each service's `proto/` directory. Code is generated at build time via `build.rs` (tonic-build). Generated code is checked into `src/presentation/grpc/proto/`.

### Asynchronous (NATS JetStream)
Used for cross-service notifications and the AI translation pipeline. Publishers fire-and-forget; consumers are independent.

Current usage:
- `auth-service` publishes `user.registered`, `user.logged_in`, `user.logged_out` events

---

## Per-Service Code Structure (DDD)

Every service follows the same 6-layer Domain-Driven Design pattern:

```
services/<name>/
├── src/
│   ├── domain/             # Pure business logic — no I/O
│   │   ├── <entity>/       # Entity, value objects, repository trait, domain errors
│   │   └── ...
│   ├── application/        # Use-case orchestration
│   │   └── services/
│   │       └── <name>/
│   │           ├── service.rs   # Calls domain + infra, publishes events
│   │           └── error.rs     # Application-level error type
│   ├── infrastructure/     # External I/O implementations
│   │   ├── persistence/postgres/  # SQLx repository implementations
│   │   ├── grpc/           # gRPC clients (outbound) and server impls (inbound)
│   │   └── messaging/      # NATS publishers/consumers
│   ├── presentation/       # Transport layer
│   │   ├── http/
│   │   │   ├── routes/     # Axum router wiring
│   │   │   ├── handlers/   # Request handlers (DTOs in/out)
│   │   │   └── middleware/ # Per-route middleware (e.g. require_admin)
│   │   └── grpc/           # Tonic service implementations
│   ├── state/              # AppState, sub-states (composed and passed to Axum)
│   └── bootstrap/          # Service startup: wiring deps, building the router
├── migrations/             # SQLx migrations (per-service schema)
├── seeds/dev/              # Development seed SQL
├── proto/                  # Protocol Buffer definitions
├── tests/                  # Integration tests
│   ├── common/
│   │   ├── setup.rs        # TestHarness (testcontainers: Postgres + Redis + NATS)
│   │   └── helpers.rs      # make_json_request / make_authenticated_request
│   └── <feature>_test.rs
└── build.rs                # tonic-build proto codegen
```

### Key conventions

- **No `unwrap`/`expect`/`panic`** in production code (enforced by clippy `deny`)
- **`thiserror`** for domain/application errors; **`anyhow`** only in bootstrap/main
- **`RequestUser`** extractor reads identity headers (set by Traefik ForwardAuth)
- **`require_admin`** middleware rejects requests where `x-user-role != admin`; used on system-level routes called by other services
- **SQLx compile-time query verification** — `DATABASE_URL` must point to a live DB during `cargo build`

---

## Database

Single shared PostgreSQL database (`hermes`). Each service owns its own tables; no cross-service foreign keys (MVP trade-off).

Migrations are per-service, not global:

```
services/auth-service/migrations/    # 20260122xxxxxx_*.sql
services/user-service/migrations/    # 20260121xxxxxx_*.sql
services/guild-service/migrations/
services/channel-service/migrations/
```

Run all migrations:
```bash
cd hermes_backend && make db-migrate
```

> **Important for tests**: Each service's `tests/common/setup.rs` manually lists all migrations to run in order against a testcontainer Postgres instance. When adding a new migration, it must be added to both the `migrations/` directory **and** the `setup.rs` constants list.

---

## Frontend

React 19 + Vite SPA running in a Docker container on `hermes-network`.

| Tech | Version | Purpose |
|---|---|---|
| React | 19 | UI framework |
| Vite | latest | Dev server + bundler |
| TypeScript | — | Type safety |
| Tailwind CSS | v4 | Styling |
| Zustand | — | Client state management |
| TanStack Query | — | Server state / data fetching |
| TanStack Router | — | Client-side routing |

Vite dev server runs on port 3001 inside the container. Traefik routes `/` (priority 1, lowest) to it. HMR works because `hmr.clientPort: 80` tells the browser to connect back through Traefik rather than directly to :3001.

---

## Networking

All services (Traefik, infra, Rust services, frontend) run as Docker containers on `hermes-network`. Container DNS resolves service names directly.

```
Browser
   │
   ▼
Traefik :80  (hermes-traefik, hermes-network)
   │
   │  hermes-auth-service:8081 / hermes-user-service:8082 / ...
   ▼
Rust services  (hermes-network, built from hermes_backend/Dockerfile)
   │
   │  hermes-postgres:5432 / hermes-redis:6379 / hermes-nats:4222
   ▼
Infra containers  (hermes-network)
```

Stub services (chat, voice, presence, realtime, media, notification, search, ai) use `traefik/whoami` as a placeholder until implemented.

---

## Observability

| Signal | Stack | Endpoint |
|---|---|---|
| Structured logs | `tracing` + `tracing-subscriber` (Pretty dev / JSON prod) | stdout |
| Metrics | `metrics` + `metrics-exporter-prometheus` | `GET /metrics` on each service |
| Prometheus scrape | `hermes-prometheus` | `http://localhost:9090` |
| Dashboards | `hermes-grafana` | `http://localhost:3000` (admin/admin) |
| Traefik metrics | Prometheus exporter (built-in) | scraped by Prometheus |

Each service exposes a `/health/live` and `/health/ready` endpoint.

---

## Development Workflow

### First-time setup

```bash
# 1. Start Traefik (creates hermes-network)
cd hermes
docker compose up -d

# 2. Start infra (Postgres, Redis, NATS, …) and generate SQLx offline metadata
cd hermes/hermes_backend
cp .env.example .env        # edit DATABASE_URL etc. if needed
make up
make db-migrate
make db-seed
make sqlx-prepare           # generates .sqlx/ dirs — commit them before building images

# 3. Build and start all Rust services + stub whoami containers
docker compose up --build -d

# 4. Start frontend container
cd hermes/hermes-fe
docker compose up -d
```

### Daily commands

```bash
make build                  # cargo build --workspace (host compile)
make test                   # cargo test --workspace (requires Docker infra up)
make ci                     # fmt-check + clippy + tests (pre-push gate)
make lint                   # clippy -D warnings
make fmt                    # cargo fmt --all
make db-reset               # clean + up + migrate + seed
docker compose up --build -d  # rebuild and restart all services
```

### Useful URLs (dev)

| URL | Service |
|---|---|
| `http://localhost` | Frontend (Vite dev server via Traefik) |
| `http://localhost:8080` | Traefik dashboard |
| `http://localhost:3000` | Grafana (admin/admin) |
| `http://localhost:9090` | Prometheus |
| `http://localhost:8025` | Mailpit (email catcher) |
| `http://localhost:8222` | NATS monitoring |
| `http://localhost:808{1-6}/swagger-ui` | OpenAPI UI per service |

---

## Testing Strategy

### Unit tests
Inline in `src/` modules, no I/O. Cover domain logic and value-object validation.

### Integration tests
In `services/<name>/tests/`. Use `testcontainers` to spin up real Postgres, Redis, and NATS containers per test binary. The `TestHarness::new()` helper in `tests/common/setup.rs` wires up the full service stack (repos, services, router) against fresh containers.

```bash
cargo test -p auth-service       # runs integration tests for one service
cargo test --workspace           # all services
```

### API contract tests (Schemathesis)
Runs against a live service stack using the OpenAPI spec. Start with:
```bash
make test-api                    # all services
make test-api-auth               # auth-service only
```
The `schemathesis` Docker service is gated behind the `testing` compose profile and reaches services via container names on `hermes-network`.

---

## Lint & Safety Policy

Enforced workspace-wide in `Cargo.toml`:

| Rule | Level |
|---|---|
| `unsafe_code` | **forbidden** |
| `unwrap_used`, `expect_used`, `panic`, `dbg_macro` | **deny** |
| `clippy::all`, `pedantic`, `nursery`, `cargo` | warn |
| `missing_docs`, `missing_debug_implementations` | warn |

Exceptions (allowed): `module_name_repetitions`, `too_many_lines`, `type_complexity`, `needless_pass_by_value`, `struct_excessive_bools`.
