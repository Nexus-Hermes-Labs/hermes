# Hermes — Technology Stack

Quick reference for every external technology Hermes depends on: what it is, why we picked it over alternatives, and where it lives in the repo. Companion to [`ARCHITECTURE.md`](ARCHITECTURE.md), which covers the *shape* of the system rather than the tools.

> **How to read this:** each section answers three questions — *what is it*, *why is it here*, and *where in Hermes do I see it*. Skip to the section that matches the area you're touching.

---

## Table of contents

- [Edge / Reverse proxy](#edge--reverse-proxy)
  - [Traefik](#traefik)
- [Backend runtime & framework](#backend-runtime--framework)
  - [Rust](#rust)
  - [Tokio](#tokio)
  - [Axum + Tower / tower-http](#axum--tower--tower-http)
  - [Tonic (gRPC)](#tonic-grpc)
- [Persistence & messaging](#persistence--messaging)
  - [PostgreSQL](#postgresql)
  - [SQLx](#sqlx)
  - [Redis](#redis)
  - [NATS (JetStream)](#nats-jetstream)
- [Configuration](#configuration)
  - [Consul KV + figment](#consul-kv--figment)
- [Security](#security)
  - [JWT (jsonwebtoken)](#jwt-jsonwebtoken)
  - [Argon2 + SHA-256](#argon2--sha-256)
- [Observability](#observability)
  - [tracing + tracing-subscriber](#tracing--tracing-subscriber)
  - [Loki](#loki)
  - [Promtail](#promtail)
  - [Prometheus](#prometheus)
  - [OpenTelemetry + Tempo](#opentelemetry--tempo)
  - [Grafana](#grafana)
- [Frontend](#frontend)
  - [React + Vite + TypeScript](#react--vite--typescript)
  - [TanStack Router + TanStack Query](#tanstack-router--tanstack-query)
  - [Zustand + Zod + react-hook-form](#zustand--zod--react-hook-form)
  - [Tailwind CSS + Radix + shadcn/ui](#tailwind-css--radix--shadcnui)
- [Dev tooling & test infra](#dev-tooling--test-infra)
  - [Docker + docker-compose](#docker--docker-compose)
  - [Mailpit](#mailpit)
  - [Schemathesis](#schemathesis)
  - [Testcontainers](#testcontainers)
- [Stack diagram](#stack-diagram)

---

## Edge / Reverse proxy

### Traefik

**What.** A cloud-native reverse proxy that auto-discovers backends by reading Docker labels.

**Why.** We have ~13 services. Hand-managing `nginx` configs would mean editing a config file every time a service is added. Traefik picks up new containers automatically from labels in their `docker-compose.yml`, and its **ForwardAuth middleware** lets us put one centralised auth check (`auth-service`) in front of every protected route — no JWT validation duplicated across services.

**Where in Hermes.**
- Static config: `infra/traefik/traefik.yml` (entrypoints, metrics endpoint).
- Dynamic routes + ForwardAuth + rate-limit: `infra/traefik/dynamic/routes.yml`.
- Each service registers itself via labels in its `services/<name>/docker-compose.yml`.

**Example flow.** Browser hits `/api/v1/guilds` → Traefik calls `auth-service:8081/internal/verify` → on 200 it adds `X-User-Id` / `X-User-Role` headers and forwards to `guild-service`. The guild service trusts those headers because the request can only reach it through Traefik on the internal network.

---

## Backend runtime & framework

### Rust

**What.** Systems language with no GC, ownership-based memory safety, and compile-time concurrency guarantees.

**Why.** Real-time chat is latency-sensitive; we want sub-ms p50 routing without GC pauses. Rust also gives us cheap concurrency (millions of tasks via Tokio) and a strong type system that catches whole classes of bugs (null, data races) at compile time. The trade-off is build times — we accept that.

**Lint policy** (`hermes-be/Cargo.toml`): `unwrap_used`, `expect_used`, `panic`, `dbg_macro` are **deny**. The only acceptable `#[allow(clippy::unwrap_used)]` is on infallible static initialisation (e.g. compiled regex via `Lazy<Regex>`).

### Tokio

**What.** Async runtime — event loop, timers, channels, tasks.

**Why.** Everything is I/O-bound (DB, Redis, NATS, gRPC, HTTP). Tokio's work-stealing scheduler scales to many connections without one-thread-per-request.

**Where.** `#[tokio::main]` at every service entrypoint; `task_local!` is used for the `REQUEST_ID` propagation in `services/common/src/observability/request_context.rs`.

### Axum + Tower / tower-http

**What.** Axum is a minimal HTTP framework on top of Hyper. Tower provides composable middleware as `Layer`s.

**Why.** Axum has near-zero runtime overhead and uses extractors instead of attribute macros, so handler signatures *are* the contract. Tower's `Layer` model means cross-cutting concerns (auth, tracing, request-id, CORS, rate limit) compose cleanly — no monkey-patched globals.

**Example.** A guild handler:
```rust
pub async fn create_guild(
    State(state): State<AppState>,
    user: RequestUser,                  // 401 if X-User-Id header missing
    Json(req): Json<CreateGuildRequest>, // validated via `validator`
) -> Result<Json<GuildResponse>, AppError> { ... }
```

The router stack in every service follows the same shape (see `services/auth-service/src/presentation/http/routes/mod.rs`):
```rust
.layer(cors)
.layer(trace_layer)              // structured spans, latency
.layer(PropagateRequestIdResponseLayer)
.layer(RequestIdScopeLayer)      // task-local request_id
.nest("/metrics", metrics_routes())  // outside layers — Prometheus scrapes don't pollute traces
```

### Tonic (gRPC)

**What.** Pure-Rust gRPC server + client, generated from `.proto` files via `tonic-build` at compile time.

**Why.** Inter-service calls (e.g. `auth-service` → `user-service` for profile lookup) want strong types, codegen, and binary efficiency. JSON-over-HTTP between services would mean re-validating shapes everywhere. Protobuf gives us a single `.proto` source of truth and 50× faster serialization.

**Gotcha worth knowing.** Axum 0.7 links `http 1.x` while Tonic 0.11 still links `http 0.2`. They are *different* `http::Request` types. We have separate `Service` impls for axum and tonic in `RequestIdScopeLayer` (`services/common/src/observability/request_context.rs`); a single generic impl over `Request<B>` will not compile.

**Where.** `proto/` holds `.proto` files. Each service has a `presentation/grpc/` for the server side and `infrastructure/grpc/` for outbound clients (with `RequestIdInterceptor` attached so request-ids propagate).

---

## Persistence & messaging

### PostgreSQL

**What.** Relational database. We run 16-alpine in compose.

**Why.** Mature, ACID, rich type system (UUID, JSONB, arrays), excellent ecosystem. Each service owns its own database (`hermes_auth`, `hermes_user`, `hermes_guild`, …) so schema changes in one service don't break another — bounded contexts at the storage layer.

**Where.** Compose config + `init.sql` at `hermes-be/infra/postgres/`. Per-service migrations under `services/<name>/migrations/`. Migrations run automatically on service startup via `sqlx::migrate!()`.

### SQLx

**What.** Async SQL toolkit with compile-time–verified queries.

**Why.** The `query!` / `query_as!` macros connect to a development database at *compile* time and verify your SQL is valid against the schema. A typo or column-renamed-without-migration becomes a compile error, not a 500 in production. We lean on this hard.

**Trade-off.** You need either a live DB during development *or* a checked-in `.sqlx/` directory of cached query metadata for offline builds (CI / Docker). We use the offline approach — `make sqlx-prepare` regenerates it.

**Example.** From `auth-service/src/infrastructure/persistence/postgres/auth_credential.rs`:
```rust
sqlx::query_as!(
    AuthCredentialRow,
    "SELECT user_id, email, password_hash FROM credentials WHERE email = $1",
    email
)
.fetch_optional(&self.pool)
.await
```
The macro proves `email` is `&str`, the row has those three columns, and returns are nullable. No runtime reflection.

### Redis

**What.** In-memory key-value store with pub/sub, TTLs, atomic ops.

**Why.** Three jobs in Hermes:
1. **Session storage** for refresh tokens — `auth-service` writes hashed tokens with TTL = refresh expiry.
2. **Presence tracking** — `presence-service` (planned) updates per-user heartbeats with short TTLs; the absence of a key = "offline".
3. **Rate-limit counters** — sliding-window counters at the edge.

Postgres could do all three but at 100× the latency. Redis fits these access patterns by design.

**Where.** `redis = { features = ["tokio-comp", "connection-manager"] }` in workspace deps. `ConnectionManager` is constructed once per service in `bootstrap/`.

### NATS (JetStream)

**What.** Lightweight pub/sub message broker with persistence (JetStream).

**Why.** Cross-service events should not be synchronous — when a user registers, `user-service` doesn't want to wait for `notification-service` and `search-service` to also acknowledge. NATS gives us fan-out plus, with JetStream, durable replay if a consumer was offline. Compared to Kafka: orders of magnitude lighter to run, with similar at-least-once guarantees for our scale.

**Where.** `services/common/src/infrastructure/messaging/` wraps `async-nats` behind an `EventPublisher` trait. Domain events (e.g. `UserRegistered`, `GuildCreated`) are emitted with `service` set as the publisher name. Subjects follow `<domain>.<event>` (`auth.user.registered`).

**Example.** Auth-service publishing on registration:
```rust
event_publisher.publish(
    "auth.user.registered",
    &UserRegisteredEvent { user_id, email, .. },
).await?;
```

Future: `notification-service` subscribes to `auth.user.registered` and sends the welcome email — no synchronous coupling between the two.

---

## Configuration

### Consul KV + figment

**What.** [Consul](https://www.consul.io) is HashiCorp's service-mesh / KV store; we use only the KV side. [`figment`](https://docs.rs/figment) is the Rust config-merging library that layers `.env`, env vars, and Consul JSON into one `Config` struct.

**Why.** With 13 services, copying the same JWT secret / NATS URL / DB password into 13 `docker-compose.yml` files invites drift. Consul KV gives one place to store cross-service defaults; `figment` lets each service merge those defaults with environment-specific overrides.

**How the layers stack** (last layer wins, see `services/common/common-config/src/lib.rs::Config::load`):

1. **Consul `config/application/data`** — shared baseline migrated from workspace `.env.example` (DB user, JWT secret, default log level, etc.).
2. **Consul `config/{service_name}/data`** — service-specific baseline migrated from `services/{name}/.env.example` (port, gRPC port, DB name, etc.).
3. **`.env` files** — workspace `.env` then `services/{name}/.env`, loaded by `dotenvy` for local cargo-run mode.
4. **Environment variables** (`APP_*`) — compose, CI, or anything the host process sets. **Authoritative.**

**Why env wins over Consul.** Hermes runs in two modes that need different hostnames:
- `make up` (containers) — compose sets `APP_DATABASE__HOST=hermes-postgres`.
- `make run-auth` (host) — developer's `.env` sets `APP_DATABASE__HOST=127.0.0.1`.

Consul holds the *checked-in baseline* (used identically in both modes); env vars are the per-mode override. Operators changing values in Consul still need to restart the affected service — `Config::load` runs only at startup, there is no live-watch.

**Migration script** (`hermes-be/scripts/config-migration/migrate_to_consul.py`) reads every `.env.example` (workspace + per-service) and PUTs them to `config/{name}/data` as JSON. Stdlib only — no `pip install` needed. Idempotent:

```bash
make config-migrate              # uses CONSUL_URL=http://127.0.0.1:8500 by default
docker exec hermes-consul curl -s 'http://localhost:8500/v1/kv/config/?keys'
```

**Where.**
- Container: `hermes-be/infra/docker-compose.yml` (the `consul` service, `agent -dev` mode).
- Reader: `services/common/common-config/src/lib.rs::fetch_consul_kv` — uses `ureq` (sync, no tokio runtime dependency) since `Config::load` runs from inside `#[tokio::main]` startup. `reqwest::blocking` is documented-discouraged in async contexts.
- UI: http://localhost:8500 — Consul's web UI for browsing/editing keys live.

**Dev-mode caveats.** `consul agent -dev` has **no auth, no ACLs, no TLS** — anyone on `hermes-network` can read or overwrite the KV. Plaintext secrets (JWT keys, DB passwords) sit in Consul KV. Fine for dev; production needs Consul ACLs + TLS, or Vault for the secret tier.

**Failure mode.** `fetch_consul_kv` logs to stderr and returns `None` when Consul is unreachable, returns 404, or sends an empty body. The env layer alone produces a complete config, so a missing Consul never *prevents* startup — it just degrades to env-only.

---

## Security

### JWT (jsonwebtoken)

**What.** RFC 7519 JSON Web Tokens — signed claims about a user.

**Why.** Stateless authentication: services don't need to call back to `auth-service` for every request — they validate the token's signature and trust its claims. Combined with **Traefik ForwardAuth**, only `auth-service` actually decodes JWTs; downstream services receive plain `X-User-Id` / `X-User-Role` headers.

**Choices.** HS256 (symmetric, shared secret) for now — secret lives in `APP_SECRETS__JWT__ACCESS_SECRET`. Two tokens: short-lived access (~15 min), long-lived refresh (~30 d) whose hash is stored in Redis so we can revoke.

**Where.** `services/common/src/infrastructure/security/jwt_manager.rs`.

### Argon2 + SHA-256

**What.** Argon2id (winner of the 2015 Password Hashing Competition) for **password** hashing. SHA-256 for **token** hashing.

**Why two?** They protect against different threats:
- **Argon2id** is *deliberately slow* and memory-hard — designed to thwart GPU/ASIC attacks against leaked password hashes. Right tool for things humans pick.
- **SHA-256** is *deliberately fast* — right tool for things we generated with `rand` (refresh tokens, verification tokens). Those have ~256 bits of entropy already, so a fast hash is sufficient and avoids paying Argon2's CPU cost on every refresh.

**Where.** `services/auth-service/src/infrastructure/security/password/argon2_service.rs` and `…/token/sha256_service.rs`.

---

## Observability

The observability stack is the focus of [`TODO.md`'s Observability epic](TODO.md). All six steps are shipped: centralised logs, structured fields, request-id propagation, metrics + dashboards, and distributed tracing.

### tracing + tracing-subscriber

**What.** `tracing` is Rust's structured-logging + spans framework. `tracing-subscriber` formats events; we use the `json` feature in production.

**Why over `log`.** `log` only produces flat strings. `tracing` has **spans** — a span is a unit of work (a request, a DB call) with a start, end, and structured fields. Child spans inherit context. This gives us structured JSON logs *and* a foundation for distributed tracing — the same spans that produce log lines are exported to Tempo via `tracing-opentelemetry`.

**Where.** `services/common/src/observability/`:
- `http_trace.rs` — `HermesMakeSpan` opens a span per request with `method`, `uri`, `request_id`, and `trace_id`. `HermesOnResponse` records `status` + `latency_ms` and emits the metrics counter/histogram.
- `request_context.rs` — `task_local!` `REQUEST_ID` propagated through axum and tonic, plus a tonic client interceptor that injects `x-request-id` *and* W3C `traceparent`.
- `tracing.rs` — initialises both the fmt layer (Loki) and (optionally) the OpenTelemetry layer (Tempo).

Switch between pretty (dev) and JSON (prod) via `APP_LOGGING__FORMAT=json`.

### Loki

**What.** Grafana Labs' log aggregator. Stores log lines indexed by **labels** only — the message body is compressed and grep'd at query time.

**Why over Elasticsearch.** ELK is expensive to run (heap, shards, replicas). Loki's design — "index labels, not lines" — is dramatically cheaper for our log volume, and the LogQL query language reads like Prometheus, which we already use.

**Where.** `hermes-be/infra/loki/loki-config.yml`. Reachable on `:3100`.

**Example LogQL query** (used in the Grafana dashboard):
```logql
{service=~".+-service", level="ERROR"}
```

### Promtail

**What.** Log shipper for Loki. Tails containers via the Docker socket and forwards to Loki.

**Why this over Fluentd / Vector.** Same vendor as Loki + Grafana, zero-config setup, and the Docker SD config we use auto-discovers any new `hermes-*` container. New service → labels appear in Loki for free.

**Where.** `hermes-be/infra/promtail/promtail-config.yml`. Extracted labels: `service` (from container name), `container`, `stream`, `level`, `target`. The `level` and `target` labels are pulled from each JSON log line via the `pipeline_stages.json` step.

### Prometheus

**What.** Time-series database that **pulls** metrics by HTTP-scraping `/metrics` endpoints on a schedule (every 15 s for us).

**Why pull over push.** Pull means Prometheus knows what's *expected* to be up — a missing scrape target is an alert in itself. Push systems can't distinguish "service is healthy and quiet" from "service is dead". For long-running services in a known topology, pull wins.

**Where.**
- Config: `hermes-be/infra/prometheus/prometheus.yml` — scrapes all 7 service containers on their HTTP port.
- Recorder install: `services/common/src/observability/metrics.rs::Metrics::init()` (called once per service in `bootstrap/`).
- Emit sites: `HermesOnResponse` records `http_request_duration_seconds` (histogram with custom buckets) + `http_requests_total` (counter labelled by status).
- Scrape endpoint: `metrics_routes()` is mounted at `/metrics` **outside** the trace_layer so scrapes don't generate fake request spans.

### OpenTelemetry + Tempo

**What.** OpenTelemetry is the vendor-neutral standard for distributed traces. Tempo is Grafana Labs' trace store — analogous to Loki but for spans instead of log lines.

**Why this combination.** A trace is a tree of spans showing how one user-facing request fanned out across services. Logs alone tell you *what* happened in each service, but not *which span* a log line belongs to or *which hop is slow*. OTel + Tempo gives us flame-graph-like views: click a slow span and jump straight to the log lines emitted while it was active.

**Why over Jaeger.** Jaeger is the older alternative; Tempo costs less to run (object-storage backend, no per-trace indexing) and integrates with Grafana out of the box — same auth, same UI, same dashboards.

**How traces propagate.** W3C `traceparent` header carries the trace ID + parent span ID across the wire. Each service:
1. **Inbound HTTP** (`HermesMakeSpan`): extracts `traceparent` from request headers, links the new span to that parent context, records `trace_id` as a tracing field so JSON log lines carry it.
2. **Inbound gRPC** (`RequestIdScopeService`'s tonic impl): same idea, reading from gRPC metadata, opens a `grpc_request` span and runs the handler future inside it.
3. **Outbound gRPC** (`RequestIdInterceptor`): injects the active span's `traceparent` into the outbound metadata so the *next* hop can extract it.
4. **Tempo export**: a parallel `tracing_opentelemetry` layer in the subscriber forwards every tracing span to Tempo via OTLP/gRPC (port 4317).

**Activation.** Setting `APP_LOGGING__OTLP_ENDPOINT=http://hermes-tempo:4317` in a service's compose env turns on the export pipeline. When unset (e.g. local `cargo run`), the global propagator is a noop, no spans are exported, and everything else works unchanged.

**Where.**
- Tempo config: `hermes-be/infra/tempo/tempo.yaml` — OTLP receivers on 4317 (gRPC) / 4318 (HTTP), span-metrics + service-graph generators enabled.
- Init: `services/common/src/observability/tracing.rs::install_otel_pipeline`.
- HTTP propagation: `services/common/src/observability/http_trace.rs::HermesMakeSpan` + `AxumHeaderExtractor`.
- gRPC propagation: `services/common/src/observability/request_context.rs` — `RequestIdInterceptor` (client-side inject), `RequestIdScopeService` tonic impl (server-side extract), `Http02HeaderExtractor` adapter for the `http 0.2` HeaderMap that tonic 0.11 uses.

**Version-pinning gotcha.** `opentelemetry-otlp 0.17` transports OTLP over its own internal `tonic 0.12`, while the application uses `tonic 0.11`. They coexist as separate crates in the dependency graph — different majors, different generated code, no runtime conflict.

### Grafana

**What.** Dashboard / alerting / explore UI for Loki + Prometheus + Tempo.

**Why.** Single pane of glass over metrics, logs, and traces with first-class correlation between datasources — click a slow span in Tempo, jump to the log lines for the same trace_id; click a `trace_id` field in a Loki log, jump to the trace flame graph.

**Where.**
- Provisioning roots: `hermes-be/infra/grafana/provisioning/`.
- Datasources (`datasources/{prometheus,loki,tempo}.yml`) have **pinned uids** (`prometheus`, `loki`, `tempo`) so dashboards and cross-datasource links resolve deterministically across rebuilds.
- Loki datasource has a `derivedFields` rule that matches `"trace_id":"<hex>"` in JSON log lines and turns it into a clickable link to the Tempo trace.
- Tempo datasource has `tracesToLogsV2` configured, so the inverse jump (span → logs for the same `trace_id`) works too.
- Dashboards are auto-loaded from `dashboards/` (provider config in `dashboards.yml`).
- Current dashboard `hermes-overview.json` has four panels: HTTP p50/p95 latency, 5xx error rate, log volume by service, recent ERROR logs (with a `$service` template variable).

---

## Frontend

### React + Vite + TypeScript

**What.** React 19 components, served by Vite for the dev server and the production bundle.

**Why Vite over Next.js / CRA.** We don't need SSR — the app sits behind auth and is fully client-rendered. Vite's HMR (hot module replacement) is the fastest option in this class, and its build is a thin wrapper over Rollup, so we get tree-shaking and ESM out of the box. Vite dev server runs as `hermes-frontend-dev` in `hermes-fe/docker-compose.yml` with source mounted for live reload.

**TypeScript** is non-negotiable in any project this size — without it, the auth/route/state interactions would be a refactor death-trap.

### TanStack Router + TanStack Query

**What.** TanStack Router is a fully type-safe React router with route-level loaders. TanStack Query is a server-state cache with built-in revalidation, retries, and optimistic updates.

**Why over react-router + Redux.** TanStack Router types your routes — `to: "/guilds/$guildId"` is checked at compile time, no stringly-typed bugs. TanStack Query replaces the entire "what server data do we have, when do we refetch, how do we handle stale data" problem that Redux/RTK-Query also solves but with vastly more boilerplate.

**Pattern.** Components don't fetch — they call `useQuery({ queryKey, queryFn })`. Mutations call `useMutation` and invalidate query keys on success. The cache handles deduping concurrent requests, background refetch, and offline retries.

### Zustand + Zod + react-hook-form

- **Zustand** — minimal client-state store (auth user, UI state). Used for the small slice of state that is *not* server data; everything else lives in TanStack Query.
- **Zod** — runtime schema validation. Same schema can validate forms (via `@hookform/resolvers/zod`) *and* parse API responses.
- **react-hook-form** — uncontrolled forms, near-zero re-renders. Pairs with Zod for validation.

This trio replaces what would otherwise be Redux + Yup + Formik with ~10× less boilerplate.

### Tailwind CSS + Radix + shadcn/ui

- **Tailwind v4** — utility-first CSS. No CSS file sprawl, predictable bundle size.
- **Radix UI primitives** — accessible, unstyled components (Dialog, Popover, Dropdown, …). Handles focus-trapping, ARIA, keyboard nav so we don't reimplement a11y bugs.
- **shadcn/ui** — *not* a dependency; copy-pasted, Tailwind-styled components built on top of Radix. Lives in `hermes-fe/src/components/ui/`. We own the code, can edit it freely.

---

## Dev tooling & test infra

### Docker + docker-compose

**What.** Containerization plus the multi-container orchestration we use locally.

**Why.** Reproducible dev environments — every contributor gets the same Postgres / Redis / NATS / Grafana versions. The compose layout is split across files (one per service + one for infra) so individual services can be restarted without touching the rest.

The shared `hermes-network` is created once (`make network`) and every compose file declares it as `external: true`. That's how Traefik on one compose file talks to backends defined in others.

### Mailpit

**What.** Local SMTP server with a web UI for inspecting captured mails.

**Why.** Auth flows send verification + password-reset emails. We don't want test emails hitting real inboxes. Mailpit captures everything sent to `hermes-mailpit:1025` and shows it at `http://localhost:8025` — instant feedback during dev.

### Schemathesis

**What.** Property-based API tester driven by an OpenAPI spec.

**Why.** Each service exposes Swagger via `utoipa`. Schemathesis reads that spec and *generates* requests — including malformed/edge-case ones — to find handlers that crash, leak 500s, or violate their own schema. Catches bugs that example-based tests don't.

**Where.** `make test-api` (root Makefile) runs the Schemathesis container under the `testing` profile in `infra/docker-compose.yml`.

### Testcontainers

**What.** Spins up real Postgres / Redis containers from Rust test code.

**Why.** Integration tests must hit a real database, not mocks — see the memory note from prior work: mock divergence has bitten us before, when mocked tests passed but a Postgres-specific migration broke. Testcontainers gives every test a fresh Postgres in <1s with no manual setup.

**Where.** `services/<name>/tests/common/setup.rs` in services that have integration tests (auth, user, guild, channel, chat, messaging).

---

## Stack diagram

```
                              Browser
                                 │
                                 ▼
                ┌────────────────────────────────┐
                │  Traefik :80   (edge proxy)     │ ← infra/traefik/
                │   ForwardAuth → auth-service    │
                └────────────────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        ▼                        ▼                        ▼
 ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
 │ auth :8081  │          │ user :8082  │          │ guild :8086 │   …
 │  + gRPC 50051│ ◄──gRPC─│  + 50052    │          │  + 50056    │
 └──────┬──────┘          └──────┬──────┘          └──────┬──────┘
        │                        │                        │
        ▼                        ▼                        ▼
   ┌─────────┐               ┌──────┐                ┌──────────┐
   │Postgres │ (one DB per   │Redis │ (sessions,     │  NATS    │ (events:
   │ :5432   │  service)     │:6379 │  presence,     │  :4222   │  user.registered,
   └─────────┘               └──────┘  rate limits)  └──────────┘  guild.created, …)

Configuration sidecar (read at boot)
   ┌────────────────────────────────────────────────────────────────────────┐
   │  Consul :8500   (KV: config/application + config/{service}/data)       │
   │       ▲                                                                 │
   │       │ each service reads at startup; env vars override               │
   │  ─── migrate_to_consul.py PUTs from .env.example files                 │
   └────────────────────────────────────────────────────────────────────────┘

Observability sidecar (same Docker network, scrapes/tails/receives from the above)
   ┌────────────────────────────────────────────────────────────────────────┐
   │  Promtail        ──ships logs──▶ Loki :3100                             │
   │  Prometheus :9090 ──scrape /metrics──▶ each service                     │
   │  Tempo :3200/:4317 ◀──OTLP/gRPC spans── each service                    │
   │  Grafana :3000   ──queries──▶ Loki + Prometheus + Tempo                 │
   │                  ──derived field "trace_id" in logs links to Tempo──▶   │
   │                  ──tracesToLogs in Tempo links to Loki───────────────▶  │
   └────────────────────────────────────────────────────────────────────────┘
```

---

## When something is missing here

If you add a new technology to the workspace (`Cargo.toml` or `package.json`) or to compose, add a section to this file with the same *what / why / where* shape. The point of this document is that a new contributor can read it and answer "*why is `<X>` in this repo and not `<Y>`?*" without asking.
