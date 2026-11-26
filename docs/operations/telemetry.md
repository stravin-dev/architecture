# Telemetry & Observability (OpenTelemetry + LGTM)

Stravin Core instruments every Go daemon with **OpenTelemetry (OTel)** and exports unified metrics, structured logs, and distributed traces via OTLP/gRPC to the **Grafana LGTM stack** (**Loki**, **Grafana**, **Tempo**, and **Prometheus**). This provides unbroken end-to-end traceability from client Git ingress through regional proxies, warm NVMe caches, S3 pack storage, `wazero` Wasm hooks, DynamoDB Ref-CAS transactions, DynamoDB Streams async consumers, and background compaction/failover workers.

## Telemetry Pipeline Architecture

All five Go daemons (`stravin-edge`, `stravin-node`, `stravin-pack`, `stravin-ctrl`, and `stravin-hook`) emit traces, metrics, and correlated structured logs (`log/slog` bridged to OTel Logs) over OTLP/gRPC to an **OpenTelemetry Collector**, which fans out each signal to its dedicated backend:

```mermaid
flowchart LR
    subgraph Daemons["Stravin Core Go Daemons (OTel SDK)"]
        Edge["stravin-edge"]
        Node["stravin-node"]
        Pack["stravin-pack"]
        Ctrl["stravin-ctrl"]
        Hook["stravin-hook"]
    end

    Collector["OTel Collector\n(OTLP/gRPC :4317)\nBatch + Tail Sampling + Resource Enrich"]

    subgraph LGTM["Grafana LGTM Backends"]
        Prom[("Prometheus\n(Metrics + Exemplars)")]
        Loki[("Loki\n(Structured Logs)")]
        Tempo[("Tempo\n(Distributed Traces)")]
    end

    VExp["valkey-exporter (:9121)\noliver006/redis_exporter:v1.67.0-alpine"]

    Grafana["Grafana (3 Provisioned Dashboards)\nstravin-core | stravin-loadgen | stravin-valkey"]

    Edge -->|"OTLP/gRPC"| Collector
    Node -->|"OTLP/gRPC"| Collector
    Pack -->|"OTLP/gRPC"| Collector
    Ctrl -->|"OTLP/gRPC"| Collector
    Hook -->|"OTLP/gRPC"| Collector

    Collector -->|"Remote Write / OTLP"| Prom
    VExp -->|"Scrape :9121"| Prom
    Collector -->|"OTLP Logs"| Loki
    Collector -->|"OTLP Traces"| Tempo

    Prom --> Grafana
    Loki --> Grafana
    Tempo --> Grafana
```

### Cross-Signal Correlation in Grafana

- **Traces to Logs (`trace_id` / `span_id`):** Every `slog` record emitted within a traced `context.Context` automatically injects `trace_id` and `span_id` fields. Clicking any Tempo span in Grafana jumps directly to the matching Loki log lines for that request.
- **Metrics to Traces (Exemplars):** Histogram metrics (such as `stravin.push.duration_ms`, `stravin.fetch.duration_ms`, and `stravin.ddb.transact_duration_ms`) attach OpenTelemetry **exemplars** carrying the sampled `trace_id`. Operators spotting a p99 latency spike in Prometheus click the exemplar dot to open the exact slow trace in Tempo.

## End-to-End Distributed Trace Flows

W3C Trace Context (`traceparent` / `tracestate`) propagates across every network hop, subprocess boundary, and asynchronous queue boundary.

### Push (`git push`) & Async Hook Trace Flow

```mermaid
sequenceDiagram
    autonumber
    participant Client as Git Client
    participant EdgeR as stravin-edge (Non-Home Region)
    participant EdgeH as stravin-edge (Home Region)
    participant Node as stravin-node
    participant S3 as S3 (Home Region)
    participant Wasm as wazero Wasm Hook
    participant DDB as DynamoDB (Ref-CAS + History)
    participant Hook as stravin-hook (Streams Consumer)

    Client->>EdgeR: git push (SSH / Smart HTTP)
    Note over EdgeR: Root span: edge.ingress (git.operation=push)
    EdgeR->>EdgeH: gRPC / mTLS Write Proxy (W3C traceparent in metadata)
    EdgeH->>Node: Rendezvous-routed push stream (traceparent propagated)

    Note over Node: Span: node.pack.index_validate
    par Concurrent Upload & Sync Hook
        Node->>S3: PutObject (.pack + .idx) [span: s3.put_pack]
        S3-->>Node: 200 OK
    and
        Node->>Wasm: Run Tier 1 Wasm hook [span: hook.wasm.exec]
        Wasm-->>Node: ALLOW verdict
    end

    Node->>DDB: TransactWriteItems (Ref-CAS + Ref History w/ traceparent + Manifest)
    DDB-->>Node: Committed
    Node-->>EdgeH: ACK refs
    EdgeH-->>EdgeR: Stream ACK
    EdgeR-->>Client: Push succeeded

    DDB--)Hook: DynamoDB Streams (Ref History NEW_IMAGE)
    Note over Hook: Extract traceparent -> Span Link / Child Span: hook.async.dispatch
```

### Fetch (`git fetch` / `git clone`) & Background Worker Traces

- **Read Path (`git fetch` / `git clone`):** `stravin-edge` starts the root `edge.ingress` span (`git.operation=fetch`), propagates `traceparent` to local `stravin-node`, which records child spans for incremental DynamoDB manifest/ref queries (`ddb.query_refs`, `ddb.query_manifest`), local NVMe cache lookup (`node.cache.lookup`), concurrent local S3 pack fetches (`s3.get_pack`), optional cross-region `404 NoSuchKey` origin fallback (`s3.origin_fallback`), and sandboxed `git-upload-pack` execution (`node.git.upload_pack`).
- **Async Outbox Continuation:** Because `stravin-node` persists the W3C `traceparent` string as a lightweight attribute on the `Ref History` item inside `TransactWriteItems`, `stravin-hook` (`v1.12.x`) links its asynchronous `hook.async.dispatch` and outbound webhook HTTP spans directly back to the originating `git push` trace without adding any write-path latency.
    - **`vNext` Platform Trace Propagation ([ADR-0001](../adr/0001-platform-transport-events-webhooks.md), [ADR-0003](../adr/0003-platform-auth-and-sso-seam.md)):** In `vNext`, `stravin-relay` (renamed from `stravin-hook`) injects the persisted W3C `traceparent` into **NATS JetStream** message headers (`STRAVIN_CORE`). Downstream services (`Review`, `Run`, `Index`, `Gate`, `stravin-webhooks`, `stravin-auth`, `stravin-notify`) link spans via `SpanLinkFromTraceparent`, and **Run** / **Gate** propagate `traceparent` across **Temporal** workflow and activity headers so a single Tempo trace links `git push` → `stravin-relay` → JetStream → Temporal / `stravin-webhooks` / `stravin-notify`.
- **Background Daemons (`stravin-pack` & `stravin-ctrl`):**
    - `stravin-pack` opens a root trace per compaction job (`pack.compact.shard`) with child spans for lease acquisition (`ddb.lease_acquire`), S3 pack download, merge/indexing, two-phase manifest publish/supersede (`ddb.manifest_publish`, `ddb.manifest_supersede`), and delayed GC sweeps (`pack.gc.sweep`).
    - `stravin-ctrl` opens a root trace per failover or integrity scrub cycle (`ctrl.failover.transition`, `ctrl.scrub.region`) tagged with `failover_epoch`, recording `HeadObject` verification counts and any ref rewind transactions.

## Standardized Attributes & Cardinality Guardrails

Consistent naming across traces, logs, and metrics lets dashboards and ad-hoc Tempo/Loki queries slice cleanly by tenant, region, shard, or hook.

### Resource & Span Attributes

| Attribute | Scope | Description |
| :--- | :--- | :--- |
| `service.name` | Resource (all signals) | Daemon binary name: `stravin-edge`, `stravin-node`, `stravin-pack`, `stravin-ctrl`, `stravin-hook` (`stravin-relay` in `vNext`; plus `stravin-webhooks`, `stravin-auth`, `stravin-notify`, and upper products in `vNext`) |
| `region` | Resource (all signals) | Local AWS region executing the span (e.g., `us-east-1`) |
| `home_region` | Span / Log | Authoritative write region for the target repository |
| `tenant_id` | Span / Log (bounded metric only for tier/pool) | Owning tenant identifier |
| `repo_id` | Span / Log **only** | Target repository identifier |
| `ref_shard` | Span / Log / Metric | Shard bucket index `0..63` for DynamoDB Ref-CAS (`RS#{s}`) |
| `manifest_shard` | Span / Log / Metric | Shard bucket index `0..31` for DynamoDB Pack Manifest (`MS#{m}`) |
| `failover_epoch` | Span / Log | Monotonic fencing epoch active during the operation |
| `hook_id` | Span / Log | Identifier of the executed Tier 1 Wasm or Tier 2 async hook |
| `git.protocol` | Span / Log / Metric | Wire protocol: `ssh` or `http` |
| `git.operation` | Span / Log / Metric | Git operation: `push`, `fetch`, `clone`, `ls-refs` |

### Prometheus Cardinality Guardrails (`GuardedMeter`)

!!! warning "Unbounded Labels Never Go on Prometheus Metrics"
    Never attach `repo_id`, `ref_name`, `pack_id`, `oid`, `actor_id`, `tenant_id`, `hook_id`, or `failover_epoch` as Prometheus metric labels. High-cardinality time series cause memory explosions in Prometheus and slow Grafana queries.

In `stravin-dev/core` (`internal/telemetry/cardinality.go`), `Provider.Meter(...)` wraps every OpenTelemetry meter in **`GuardedMeter`** (a GoF Decorator) that automatically enforces bounded cardinality at runtime:

- **Forbidden labels:** `repo_id`, `ref_name`, `pack_id`, `oid`, `actor_id`, `tenant_id`, `hook_id`, `failover_epoch`.
- **Enforcement policies:** `PolicyStrip` (default, removes forbidden attributes before recording) or `PolicyReject` (drops the datapoint entirely), with optional `WithOnViolation` callbacks for tests and alerts.
- **Keep on Prometheus metrics:** Bounded enums and small integers (`service.name`, `region`, `git.protocol`, `git.operation`, `status_code`, `error_class`, `fail_mode`, `tier`, `result`, `shard_bucket`).
- **Keep on Tempo traces & Loki logs:** Unbounded identifiers (`tenant_id`, `repo_id`, `ref_name`, `pack_id`, `hook_id`, `failover_epoch`).
- **Bridge the gap with exemplars:** Use Prometheus exemplars on latency and error histograms to jump from a bounded metric bucket straight to the exact high-cardinality trace in Tempo.

## Provisioned Grafana Dashboards & Golden Signals

`stravin-dev/core` provisions **three cross-linked Grafana dashboards** under `deploy/local/grafana/provisioning/dashboards/`:

1. **`stravin-core` (`stravin-core.json`):** Core Golden Signals across `stravin-edge`, `stravin-node`, `stravin-pack`, `stravin-ctrl`, and `stravin-hook`, including pack-cache efficiency, upload-pack queuing, and async webhook deliveries.
2. **`stravin-loadgen` (`stravin-loadgen.json`):** Multi-persona developer vs. AI agent load test metrics, scenario distribution, retries, and integrity oracle counters (see [Load Testing & Chaos Engineering](load-testing.md)).
3. **`stravin-valkey` (`stravin-valkey.json`):** Dedicated Valkey cache health dashboard powered by `valkey-exporter` (`oliver006/redis_exporter:v1.67.0-alpine`, scraped by Prometheus at `valkey-exporter:9121`) tracking Valkey availability, memory utilization, LFU evictions, keyspace hit ratio, and command latency.

| Dashboard Panel / Signal Group | Implemented Metrics | Purpose & Alert Thresholds |
| :--- | :--- | :--- |
| **Ingress RPS, Errors & Concurrency (`stravin-edge`)** | `stravin_edge_requests_total`, `stravin_edge_request_duration_seconds`, `stravin_edge_active_clones`, `stravin_edge_meta_cache_lookups_total`, `stravin_edge_info_refs_retries_total` | Tracks overall Git traffic, non-home write-proxy overhead, META cache hit rate, active clone slots, and Smart HTTP `info/refs` transient retries. |
| **Tiered Pack Response Cache (`stravin-edge`)** | `stravin_edge_pack_cache_lookups_total`, `stravin_edge_pack_cache_writes_total`, `stravin_edge_pack_cache_op_duration_seconds`, `stravin_edge_pack_cache_bytes_total`, `stravin_edge_valkey_pool_dials_total` | Measures hit/miss rates and latency across `singleflight`, `valkey`, and `s3` tiers, cached bytes served, and Valkey connection pool reuse. |
| **`stravin-node` Requests, NVMe Cache & Queueing** | `stravin_node_requests_total`, `stravin_node_request_duration_seconds`, `stravin_node_cache_hits_total` / `misses_total`, `stravin_node_cache_bytes_used`, `stravin_node_s3_pack_fetches_total`, `stravin_node_aux_index_refresh_failures_total`, `stravin_node_upload_pack_queue_wait_seconds`, `stravin_node_upload_pack_queue_timeouts_total` | Tracks warm NVMe cache efficiency, S3 fetches, `.midx`/commit-graph refresh health, and `upload-pack` concurrency semaphore queueing/timeouts. |
| **CAS Conflict & Retry Rate** | `stravin_ddb_transact_total{result="ok\|conflict\|throttled"}`, `stravin_ddb_cas_retries_total` | Detects hot-ref contention, DynamoDB partition throttling, or adaptive sharding thresholds (`S`/`M`) that need expansion. |
| **S3 Put/Get & Origin-Fallback Rate** | `stravin_s3_ops_total{op="put\|get\|head",result}`, `stravin_s3_origin_fallback_total` | Monitors regional S3 health and spikes in cross-region `404 NoSuchKey` origin fallback caused by S3 CRR lag. |
| **Wasm Sync Hooks & Async Deliveries (`stravin-hook`)** | `stravin_hook_wasm_duration_seconds`, `stravin_hook_wasm_verdicts_total`, `stravin_hook_deliveries_total{result="ok\|retry\|dlq\|error"}`, `stravin_hook_delivery_duration_seconds`, `stravin_hook_stream_records_total` | Verifies Tier 1 hooks stay hidden inside the S3 upload window and tracks Tier 2 DynamoDB Streams processing, webhook latency, retries, and DLQ drops. |
| **Compaction Lag (`stravin-pack`)** | `stravin_pack_uncompacted_packs`, `stravin_pack_compaction_lag_seconds`, `stravin_pack_gc_reaped_total` | Ensures Tier-0 push packs are consolidated before read fan-out degrades `git-upload-pack` latency. |
| **Telemetry Dropped** | `otelcol_exporter_enqueue_failed_spans`, `stravin_otel_dropped_items_total` | Surfaces genuine bounded queue overflows in the Go OTel SDK batch processor or Collector ingress buffers so blind spots never go unnoticed. |

## Local vs. Production Telemetry

| Concern | Local Development (`--profile telemetry`, Implemented) | Production Deployment (**TBD / Planned**) |
| :--- | :--- | :--- |
| **Collector Topology** | Single OTel Collector container in Docker Compose receiving OTLP/gRPC on `:4317` from all daemons. | Node-local OTel Collector DaemonSet (fast loopback OTLP) forwarding to a horizontally scaled Collector Gateway tier. |
| **Sampling Strategy** | **100% head sampling** so every local `git push` and `git fetch` appears immediately in Tempo. | **Tail-based sampling** at the Collector Gateway: retain 100% of error traces, CAS conflicts, origin fallbacks, slow p99 requests, and failover scrubs; sample routine fast `200 OK` requests (e.g., 1–5%). |
| **Log Export** | JSON `slog` to stdout + OTLP Logs to Loki for local Grafana drill-down. | Structured JSON `slog` collected via DaemonSet or OTLP Logs with PII/secret redaction processors before Loki ingestion. |
| **Unit Tests** | **Live OTel export muted by default.** Automated Go unit tests use a no-op or in-memory OTel exporter (`sdktrace.NewTracerProvider()` without OTLP network export) so fast parallel test bursts never overflow bounded Collector ingress buffers or pollute local Grafana dashboards—keeping the **Telemetry Dropped** panel meaningful for real runtime overflows. | N/A (production binaries always enable OTLP export when `OTEL_EXPORTER_OTLP_ENDPOINT` is configured). |

## Related Documents

- [Local Development with Docker Compose & Floci](local-dev.md) — Running the optional `--profile telemetry` LGTM stack alongside Floci.
- [Service Scaling](scaling.md) — Using these OpenTelemetry and Prometheus signals to scale each Stravin Go daemon up/out and down/in.
- [System Topology & Request Flows](../core/topology.md) — Multi-region request paths traced by `stravin-edge`, `stravin-node`, `stravin-pack`, and `stravin-ctrl`.
- [Server-Side Hooks](../core/hooks.md) — Concurrent S3 + `wazero` execution model and DynamoDB Streams outbox traced into `stravin-hook` (`v1.12.x`) / `stravin-relay` (`vNext`).
- [Storage Layer: S3 & DynamoDB](../core/storage.md) — Shard keys (`ref_shard`, `manifest_shard`) and `Ref History` schema carrying trace context.
- [ADR-0001: Platform Transport, Events & Webhooks](../adr/0001-platform-transport-events-webhooks.md) & [ADR-0003: Platform Auth & SSO Seam](../adr/0003-platform-auth-and-sso-seam.md) — `vNext` W3C `traceparent` propagation across NATS JetStream, Temporal, `stravin-webhooks`, `stravin-auth`, and `stravin-notify`.
