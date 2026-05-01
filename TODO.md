# Hermes — TODO

Cross-repo backlog for the Hermes platform.
Service-specific work lives in [`hermes-be/docs/ROADMAP.md`](hermes-be/docs/ROADMAP.md).

**Legend:** `[ ]` pending · `[~]` in progress · `[x]` done
**Priority:** P0 (must) · P1 (should) · P2 (nice-to-have)

---

## Active Epics

### Epic: Observability — make multi-service debugging tractable

**Problem.** Hermes has many services (auth, user, channel, chat, guild, messaging, realtime, presence, voice, media, notification, search, ai). When a bug or error happens, hopping between `docker logs` of each container is unsustainable. Goal of this epic is to bring observability up to a professional standard so any failure can be located, correlated, and triaged from a single pane.

**Status:** epic complete — full observability stack (logs, metrics, dashboards, distributed tracing) shipped. Logs in Loki, metrics in Prometheus, traces in Tempo, all unified through Grafana with cross-datasource correlation.

| #   | Item                                              | Status | Priority | Notes                                                                 |
| --- | ------------------------------------------------- | ------ | -------- | --------------------------------------------------------------------- |
| 1   | Centralized log aggregation (Loki/Promtail)       | `[x]`  | P0       | Done 2026-04-26 — `hermes-be@2254d46`. Grafana datasources provisioned. |
| 2   | Enforce `LOG_FORMAT=json` in every service compose | `[x]` | P0       | Done 2026-04-26 — `APP_LOGGING__FORMAT: json` added to `environment:` block of all 7 service compose files (auth, user, guild, channel, chat, messaging, realtime). Compose env overrides `env_file: ../../.env`, so containers emit JSON while local `cargo run` still uses Pretty. |
| 3   | Standardized structured log fields                 | `[x]` | P0       | Done 2026-04-26. New `common::observability::http_trace` module: `HermesMakeSpan` opens an `http_request` span on every request with `method`, `uri`, `request_id` (UUIDv4 — step 4 will make it inbound-aware), and `user_id`/`status` placeholders. `HermesOnResponse` records the status and emits a single completion event with latency. `RequestUser` extractor records `user_id` on the active span. All 7 service routers wired via the shared `request_trace_layer()` + `HermesTraceLayer` alias. `service` is already a Loki label (Promtail extracts from container name); `trace_id` deferred to step 6 (OTel) where it has real meaning. |
| 4   | Request-ID propagation across HTTP + gRPC          | `[x]` | P0       | Done 2026-04-28. New `common::observability::request_context` provides a `tokio::task_local!` `REQUEST_ID`, a `RequestIdScopeLayer` (with separate `Service` impls for axum/`http 1.x` and tonic/`http 0.2` since the two crates link different `http` versions), `PropagateRequestIdResponseLayer` for HTTP response echoing, and a `RequestIdInterceptor` for tonic clients. All 7 HTTP routers and all 6 gRPC servers wired; all 5 gRPC clients use `with_interceptor(channel, RequestIdInterceptor)`. `HermesMakeSpan` now reads the id from the `HermesRequestId` extension. Honors inbound `x-request-id`, falls back to UUIDv4. |
| 5   | Grafana dashboard provisioning                     | `[x]` | P1       | Done 2026-05-01. Wired `metrics_routes()` into all 7 service routers at `/metrics` (mounted *outside* the trace_layer so scrapes don't pollute `http_requests_total` or generate request-id spans). `HermesOnResponse` already emitted `http_request_duration_seconds` + `http_requests_total`, so no code change there. Repaired `prometheus.yml` to use `hermes-{name}` container hostnames + real HTTP ports (8081/8082/8083/8084/8086/8092/8094). Pinned datasource uids (`prometheus`, `loki`) so dashboards reference them deterministically. Provisioned a single `hermes-overview.json` dashboard with four panels: HTTP p50/p95 latency by job (Prometheus), 5xx error rate by job (Prometheus), log volume by service (LogQL), and recent errors logs panel (LogQL `{service=~"$service", level="ERROR"}`). `service` template variable populated from Loki labels. Existing compose mount `./grafana/provisioning:/etc/grafana/provisioning` picks up the new `dashboards/` directory automatically. |
| 6   | Distributed tracing (OpenTelemetry + Tempo)        | `[x]` | P1       | Done 2026-05-01. Added `opentelemetry`/`opentelemetry_sdk`/`opentelemetry-otlp`/`tracing-opentelemetry` (0.24/0.25 line) to workspace deps. opentelemetry-otlp 0.17 carries its own internal tonic 0.12 for OTLP transport — independent of the app's tonic 0.11. Refactored `init_tracing` to install an OTLP gRPC exporter, the global W3C `TraceContextPropagator`, and a `tracing_opentelemetry` layer alongside the existing fmt JSON/Pretty layers. Activated via `APP_LOGGING__OTLP_ENDPOINT`; off when unset (local `cargo run` stays log-only). Added Tempo 2.6 to `infra/docker-compose.yml` with OTLP receivers on 4317/4318, span-metrics + service-graph generators enabled. `HermesMakeSpan` now extracts inbound `traceparent`, links the span to the parent OTel context, and records `trace_id` as a tracing field for log↔trace correlation. `RequestIdInterceptor` (gRPC client) was extended to also inject `traceparent` from the current OTel context. `RequestIdScopeService`'s tonic impl was extended to extract inbound `traceparent`, open a `grpc_request` span linked to the parent context, and instrument the inner future — closing the loop on cross-service trace continuity for both HTTP→HTTP and HTTP→gRPC. Added Tempo Grafana datasource (uid: `tempo`) with `tracesToLogsV2` config so spans deep-link to Loki for the same trace_id. Updated Loki datasource with a `derivedFields` rule that turns `trace_id` in JSON log lines into a clickable Tempo link. |

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
