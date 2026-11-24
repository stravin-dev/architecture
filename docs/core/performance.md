# Performance & Throughput Scaling

Single-repository commit throughput depends on two primary variables: whether pushes target **one shared branch** (such as `main`) or **many independent branches** (agent-scale workloads), and how many commits `K` are batched per push (`commits/sec = K × pushes/sec`).

## Verified Local Implementation & Optimizations (`v1.12.x`)

Before projecting cloud-scale ceilings, the following performance optimizations are **implemented and verified locally** in `stravin-dev/core` (`v1.12.x`) against Docker Compose + Floci + Valkey:

- **Tiered Full-Clone Pack Response Cache (`stravin-edge`):** Caches Smart HTTP full-clone `upload-pack` responses after auth/authz in **Valkey** (`<= 8 MiB`, `5m` TTL, `allkeys-lfu`) with **Floci/S3 spillover** (`<= 64 MiB`) and in-process `singleflight` coalescing (`internal/edge/pack_cache.go`).
- **Pure-Go Protocol v2 `ls-refs` Fast Path (`stravin-node`):** Serves bounded stateless-RPC `ls-refs` (`<= 1 MiB`) directly from cached DynamoDB ref state (`internal/node/ls_refs.go`), avoiding `git-upload-pack` subprocess forks on ref discovery.
- **Versioned `META` Ref & Manifest Cache (`stravin-node`):** Uses `RefVersion` and `ManifestVersion` counters on `META` to skip redundant DynamoDB shard queries when a repository has not changed.
- **`upload-pack` Concurrency Semaphore & Queue (`stravin-node`):** Bounds concurrent `git-upload-pack` subprocesses via `STRAVIN_NODE_MAX_UPLOAD_PACKS` (local default `10`) and `STRAVIN_NODE_UPLOAD_PACK_QUEUE_TIMEOUT` (default `15s`) to prevent CPU/memory thrashing under clone bursts.
- **`git` Pack-Objects Tuning (`internal/gitexec/sandbox.go`):** Applies allowlisted `pack.*` flags on `upload-pack` (`pack.threads=1`, `pack.windowMemory=256m`, `pack.compression=1`, `pack.allowPackReuse=multi`) via `STRAVIN_GIT_PACK_*` env vars to minimize per-process memory and CPU contention.
- **Tier-0 Multi-Batch Compaction (`stravin-pack`):** Drains small packs in multi-batch cycles with `MaxTier0PackBytes = 16 MiB` (`STRAVIN_PACK_MAX_TIER0_PACK_BYTES`) and `MaxBatchSize = 100` (`internal/compaction/engine.go`), keeping active pack counts low during sustained push bursts.

**Verified Local Benchmark:** On a local 10-core macOS Docker host running 10 concurrent AI agent workers (`0` devs) over a sustained **5-minute** `stravin-loadgen` run, Stravin Core sustained **~108 req/s average** at `stravin-edge` with **0 errors** in both `stravin-loadgen` (unexpected + `git fsck`) and `stravin-core` (up from a ~20 req/s initial local baseline).

## Planned / Theoretical Production AWS Ceilings

!!! note "Theoretical Targets — Not Yet Benchmarked in Production AWS"
    The 5,000–32,000 pushes/sec figures, AWS DynamoDB/S3 quota math, and DynamoDB Streams manifest aggregator below are **planned architectural targets** derived from AWS service limits. They have **not yet been benchmarked on live AWS infrastructure**.

With a sharded S3 prefix and shard-distributed Go writers, Stravin Core's target architecture is designed to reach **~6,666 multi-branch pushes/sec** on default DynamoDB quotas and **16,000–32,000 pushes/sec** theoretically with raised quotas—targeting **5,000–10,000 pushes/sec** (tens of thousands of commits/sec) in production AWS on a single repository before compaction and cross-region replication bandwidth become the dominant engineering limits. This targets the same tier as GitHub's Project Rubicon internal benchmarks (7,200 pushes/sec across 5,000 concurrent agents) and well beyond single-manifest S3 designs (~120–300 pushes/sec).

## Workload Regimes & Theoretical Ceilings

| Workload Regime | Theoretical Push Ceiling (1 commit/push) | Effective Commits/sec (`K`-commit batching) | Binding Bottleneck |
| :--- | :--- | :--- | :--- |
| **Single-Ref Direct (`main`, unserialized clients)** | **5–20 / sec** | 50–200 / sec (`K = 10`) | Git non-fast-forward CAS retry storms + client rebase RTT |
| **Single-Ref Serialized (server-side merge queue)** | **100–200 / sec** | **5,000–20,000+ / sec** (`K = 50–100`) | Single-item DynamoDB `TransactWriteItems` 2PC latency (~5–10 ms) & `TransactionConflictException` |
| **Multi-Ref (Unsharded S3 Prefix)** | **~1,750 / sec** | 17,500+ / sec (`K = 10`) | Single S3 prefix `PUT` ceiling (3,500 PUT/s ÷ 2 objects/push) |
| **Multi-Ref (Sharded S3 Prefix, Default AWS Quotas)** | **~6,666 / sec** | 66,600+ / sec (`K = 10`) | Default DynamoDB table quota (40,000 WCU/s ÷ 6 WCU/push) |
| **Multi-Ref (Sharded S3 + Raised Quotas + Tiered Compaction)** | **16,000–32,000 / sec** | **160,000+ / sec** (`K = 10`) | Manifest shard count (`M × 500`), compaction CPU, and reader scatter-gather fan-out |

## Layer-by-Layer Bottleneck Math

### 1. DynamoDB Ref-CAS & Manifest Ceiling

Every physical DynamoDB partition enforces a hard limit of **1,000 WCU/sec**. Because `TransactWriteItems` executes a two-phase commit internally, each item under 1 KB consumes **2 WCU**.

A standard single-ref push writes three small items across three partition keys:

1. **Ref State** (`T#{tenant}#REPO#{id}#RS#{hash(ref) % S}`) — 2 WCU
2. **Ref History** (`T#{tenant}#REPO#{id}#RH#{hash(ref) % S}`) — 2 WCU
3. **Pack Manifest** (`T#{tenant}#REPO#{id}#MS#{hash(pack) % M}`) — 2 WCU

Total cost: **6 WCU per push**, yielding three distinct ceilings:

- **Per-Ref Contention Ceiling (Single Branch):** Although one partition supports 500 transactional writes/sec (`1,000 ÷ 2`), concurrent transactions targeting the *same item* abort with `TransactionConflictException`. Serializing `main` updates through a single coordinator (such as Stravin Gate) caps single-ref pushes at roughly `1 / tx_latency`, or **100–200 pushes/sec** at 5–10 ms per transaction.
- **Default Table Quota Ceiling:** A default DynamoDB table quota of **40,000 WCU/sec** caps a single repository at:

```text
40,000 WCU/sec ÷ 6 WCU/push ≈ 6,666 pushes/sec
```

  AWS Service Quotas can raise table limits to hundreds of thousands or millions of WCUs; on-demand tables should configure `WarmThroughput` to absorb sudden agent spikes without throttling.
- **Shard-Count Ceiling:** With `S = 64` ref shards and `M = 32` manifest shards (each sustaining 500 tx/sec), the tighter dimension (`M = 32`) caps single-repo throughput at:

```text
32 manifest shards × 500 tx/sec = 16,000 pushes/sec
```

  Raising `M` to 64 increases the theoretical DynamoDB ceiling to **32,000 pushes/sec**.

### 2. S3 Pack Plane & Prefix Sharding

Amazon S3 supports at least **3,500 `PUT`/`COPY`/`POST`/`DELETE` requests/sec per partitioned prefix**.

If a repository writes all objects under a single prefix (such as `{repo_id}/packs/{pack_sha256}.pack`), every push uploads two objects (`.pack` + `.idx`) and stalls at:

```text
3,500 PUT/sec ÷ 2 objects/push = 1,750 pushes/sec
```

hitting HTTP `503 SlowDown` while S3 auto-splits the partition.

**Fix:** Lead the S3 object key with the first two hex characters of the pack SHA-256:

```text
s3://git-objects-{region}/{pack_sha256[0:2]}/{tenant_id}/{repo_id}/packs/{pack_sha256}.pack
```

Across 256 prefixes, S3's write ceiling climbs to:

```text
256 prefixes × 1,750 pushes/sec = 448,000 pushes/sec
```

permanently removing S3 `PUT` rates as a single-repository bottleneck.

### 3. Go Compute & Rendezvous Routing

Routing all writes for a hot repository to a single `stravin-node` via `hash(tenant_id, repo_id)` saturates compute well below storage limits:

- **Subprocess overhead:** Forking `git index-pack` on every push incurs OS process spawn, disk `fsync`, and local repo lock contention, saturating a 64-vCPU host around **300–800 pushes/sec**.
- **Horizontal write scaling:** Routing hot repositories by `hash(tenant_id, repo_id, ref_shard)` spreads writes across `N` stateless `stravin-node` workers with zero inter-node coordination—every writer still enforces linearizability through DynamoDB Ref-CAS. Replacing `git index-pack` subprocesses with an in-process streaming Go packfile validator/indexer eliminates fork/exec overhead and lets each node saturate network I/O instead of process scheduling.

## Practical Ceilings: Compaction, Read Fan-Out & Bandwidth

At 5,000+ pushes/sec on a single repository, pack proliferation, shard fan-out, and network bandwidth become the binding constraints long before S3 or DynamoDB quotas exhaust:

### 1. Pack Proliferation (LSM Compaction)

At 5,000 pushes/sec, a single repository generates **300,000 new packfiles per minute**. Standard `git-upload-pack` degrades severely when traversing thousands of uncompacted packs, and classic `git repack` cannot keep pace. `stravin-pack` solves this with **tiered, LSM-style compaction**:

- **Tier 0 (Streaming Merge, every 1–5s):** Sharded Go workers concatenate raw objects from tiny recent packs into medium 64–256 MB packs *without* expensive delta compression, cutting pack count by ~100x immediately.
- **Tier 1 (Deep Repack, hourly/daily):** Isolated background workers run full delta compression and regenerate `.midx` and `commit-graph` acceleration files.

### 2. Shard Read-Fan-Out Tax

Sharding DynamoDB across `S = 64` ref shards and `M = 32` manifest shards unlocks 16,000+ writes/sec, but a cold reader polling all shards must scatter-gather across up to **96 DynamoDB partitions** and wait for p99 tail latency. Today, `stravin-node` avoids unnecessary shard scans via its **versioned `META` cache** (`RefVersion` / `ManifestVersion`). For future production scale where `META` updates themselves become a hot-key bottleneck, consuming a **DynamoDB Streams fan-out** (or a lightweight Go in-memory manifest aggregator) is **TBD / Planned**.

### 3. Pack-Size Bandwidth Ceiling

Throughput ceilings above assume typical developer or agent pushes (10–100 KB per pack):

| Average Pack Size | Push Rate | Sustained Ingress / S3 Upload / CRR Bandwidth |
| :--- | :--- | :--- |
| **100 KB** | 5,000 pushes/sec | **500 MB/sec (4 Gbps)** per repository |
| **1 MB** | 5,000 pushes/sec | **5 GB/sec (40 Gbps)** per repository |

At multi-gigabyte-per-second rates, VPC S3 endpoint throughput and S3 CRR replication lag (which widens the failover RPO window) govern practical single-repository ceilings rather than DynamoDB WCUs.

## Related Documents

- [Storage Layer: S3 & DynamoDB](storage.md) — Sharded S3 prefixes and DynamoDB partition keys.
- [Service Scaling](../operations/scaling.md) — Horizontal and vertical scaling playbooks and telemetry triggers for each Stravin Go daemon.
- [Server-Side Hooks](hooks.md) — Keeping push throughput intact while executing synchronous hooks.
- [Sandboxed Execution & Multi-Tenancy](isolation-multitenancy.md) — Multi-tenancy performance delta by layer.
