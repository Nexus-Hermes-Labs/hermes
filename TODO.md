# Hermes — TODO

Cross-repo backlog for the Hermes platform.
Service-specific work lives in [`hermes-be/docs/ROADMAP.md`](hermes-be/docs/ROADMAP.md).

**Legend:** `[ ]` pending · `[~]` in progress · `[x]` done
**Priority:** P0 (must) · P1 (should) · P2 (nice-to-have)

---

## Active Epics

### Epic: Observability — make multi-service debugging tractable

**Problem.** Hermes has many services (auth, user, channel, chat, guild, messaging, realtime, presence, voice, media, notification, search, ai). When a bug or error happens, hopping between `docker logs` of each container is unsustainable. Goal of this epic is to bring observability up to a professional standard so any failure can be located, correlated, and triaged from a single pane.

**Status:** in progress — Loki/Promtail/Grafana deployed; request-id propagation lands cross-service correlation. Dashboards + tracing remain.

| #   | Item                                              | Status | Priority | Notes                                                                 |
| --- | ------------------------------------------------- | ------ | -------- | --------------------------------------------------------------------- |
| 1   | Centralized log aggregation (Loki/Promtail)       | `[x]`  | P0       | Done 2026-04-26 — `hermes-be@2254d46`. Grafana datasources provisioned. |
| 2   | Enforce `LOG_FORMAT=json` in every service compose | `[x]` | P0       | Done 2026-04-26 — `APP_LOGGING__FORMAT: json` added to `environment:` block of all 7 service compose files (auth, user, guild, channel, chat, messaging, realtime). Compose env overrides `env_file: ../../.env`, so containers emit JSON while local `cargo run` still uses Pretty. |
| 3   | Standardized structured log fields                 | `[x]` | P0       | Done 2026-04-26. New `common::observability::http_trace` module: `HermesMakeSpan` opens an `http_request` span on every request with `method`, `uri`, `request_id` (UUIDv4 — step 4 will make it inbound-aware), and `user_id`/`status` placeholders. `HermesOnResponse` records the status and emits a single completion event with latency. `RequestUser` extractor records `user_id` on the active span. All 7 service routers wired via the shared `request_trace_layer()` + `HermesTraceLayer` alias. `service` is already a Loki label (Promtail extracts from container name); `trace_id` deferred to step 6 (OTel) where it has real meaning. |
| 4   | Request-ID propagation across HTTP + gRPC          | `[x]` | P0       | Done 2026-04-28. New `common::observability::request_context` provides a `tokio::task_local!` `REQUEST_ID`, a `RequestIdScopeLayer` (with separate `Service` impls for axum/`http 1.x` and tonic/`http 0.2` since the two crates link different `http` versions), `PropagateRequestIdResponseLayer` for HTTP response echoing, and a `RequestIdInterceptor` for tonic clients. All 7 HTTP routers and all 6 gRPC servers wired; all 5 gRPC clients use `with_interceptor(channel, RequestIdInterceptor)`. `HermesMakeSpan` now reads the id from the `HermesRequestId` extension. Honors inbound `x-request-id`, falls back to UUIDv4. |
| 5   | Grafana dashboard provisioning                     | `[ ]` | P1       | Auto-provision dashboards under `hermes-be/infra/grafana/provisioning/dashboards/`: per-service error rate (logs `level=ERROR`), log volume by service, recent errors panel, p50/p95 HTTP latency from Prometheus. No hand-built dashboards in Explore. |
| 6   | Distributed tracing (OpenTelemetry + Tempo)        | `[ ]` | P1       | `tracing-opentelemetry` + `opentelemetry-otlp` exporter; add Tempo to `infra/docker-compose.yml`; W3C `traceparent` propagation across HTTP + gRPC; Grafana log→trace correlation via `trace_id` derived field. Larger scope — schedule after items 2–5. |

**Acceptance for the epic:** From a Grafana dashboard, given a single user-facing error, the on-call dev can:
1. Identify which service(s) emitted the error,
2. Follow the request across all hops with one correlation ID,
3. See a usable error rate / latency view per service without hand-writing LogQL.

---

## Backlog

_(nothing tracked yet — add items as they come up)_

---

## Done

_(items move here when their epic completes; per-item completion is shown inline above)_
