# Storage Layer: S3 & DynamoDB

Stravin Core splits persistent state into two specialized AWS managed planes: **Amazon S3** for immutable, content-addressed Git objects and **Amazon DynamoDB Global Tables** for linearized reference updates and pack manifests.

## S3 Immutable Pack Plane

All Git object data is stored in regional S3 buckets as immutable, content-addressed artifacts. Immutability eliminates write-write conflicts during both concurrent pushes and asynchronous cross-region replication.

### Key Prefix Layout

```text
s3://git-objects-{region}/
  {pack_sha256[0:2]}/{tenant_id}/{repo_id}/
    packs/
      {pack_sha256}.pack          # Raw Git packfile from push or compaction
      {pack_sha256}.idx           # Pre-built pack index (avoids re-indexing on read replicas)
    aux/
      {manifest_epoch}.midx       # Multi-pack-index for fast object lookup
      {manifest_epoch}.graph      # Commit-graph for fast merge-base & reachability walks
  hooks/
    {wasm_sha256}.wasm            # Content-addressed server-side Wasm hook binaries
```

**Why `{pack_sha256[0:2]}` leads the key:** Amazon S3 enforces a baseline limit of 3,500 `PUT` requests/sec per partitioned prefix. Placing `{repo_id}` at the root caps a single hot repository at 1,750 pushes/sec (2 objects per push). Leading with two hex characters of the pack hash spreads writes across 256 prefixes, raising the single-repository S3 ceiling to 448,000 pushes/sec (see [Performance & Throughput Scaling](performance.md)). Including `{tenant_id}` in the prefix from day one enables clean tenant-scoped lifecycle policies, auditing, and isolation without future data migration (see [Sandboxed Execution & Multi-Tenancy](isolation-multitenancy.md)).

### Durability Before Visibility

Mirroring GitHub's Project Rubicon, `stravin-node` always streams the validated `.pack` and `.idx` objects to local S3 and awaits HTTP `200 OK`—leveraging S3's strong read-after-write consistency within the region—**before** committing any reference update to DynamoDB. A reference in the home region therefore never points to an unpersisted object.

### Asynchronous Cross-Region Replication

Regional buckets enable **S3 Cross-Region Replication (CRR)** with **S3 Replication Time Control (RTC)**:

- Replicates most objects in seconds and carries an SLA to replicate 99.99% of new objects within 15 minutes.
- Runs completely asynchronously so home-region `PutObject` latency is unaffected.
- Automatically replicates content-addressed `.wasm` hook binaries alongside packfiles.

## DynamoDB Global Tables Control Plane

Cursor Continuity demonstrated that a single S3 manifest (`gitwal.pb`) updated with conditional `PutObject` simplifies operations but caps single-repository throughput at ~120 pushes/sec on standard S3 (~300/sec on S3 Express One Zone). Project Rubicon overcame this by scoping coordination to individual references via Ref-CAS.

Stravin Core implements Ref-CAS and pack manifest tracking on **DynamoDB Global Tables in MREC (Multi-Region Eventual Consistency)** mode—avoiding a custom Raft/Paxos log service while maintaining single-digit-millisecond local writes.

### Why MREC Instead of MRSC

| Capability | DynamoDB MREC (Chosen) | DynamoDB MRSC (Rejected) |
| :--- | :--- | :--- |
| **Home-Region Write Latency** | Local single-digit milliseconds (zero cross-region RTT) | Synchronous 3-region quorum commit (+40–150 ms cross-region RTT) |
| **`TransactWriteItems`** | Supported (atomic multi-item Ref-CAS + History + Manifest) | Unsupported |
| **Time-to-Live (TTL)** | Supported (automatic 7-day Ref History expiry) | Unsupported |
| **Conflict Model** | Async replication (<1s); safe when paired with home-region write pinning and fencing epochs | Global linearizability at the cost of write latency and transaction features |

Choosing MRSC would directly violate Stravin's requirement of zero home-region write latency penalty for replication durability and would remove `TransactWriteItems` needed for atomic ref-and-manifest commits.

## Adaptive Key-Sharded DynamoDB Schema

Each physical DynamoDB partition enforces a hard limit of **1,000 WCU/sec**. Placing all references or a single repository version counter under one partition key creates a hot-partition bottleneck for agent-scale monorepos. Stravin Core avoids this through **adaptive key sharding** (`ref_shards` $S \in [1, 64]$, `manifest_shards` $M \in [1, 32]$) prefixed by `tenant_id`:

| Entity | Partition Key (`PK`) | Sort Key (`SK`) | Key Attributes |
| :--- | :--- | :--- | :--- |
| **Repo Routing & Fencing** | `T#{tenant_id}#REPO#{repo_id}` | `META` | `home_region`, `failover_epoch`, `ref_shards` (`1..64`), `manifest_shards` (`1..32`), `write_state` |
| **Reference State (Ref-CAS)** | `T#{tenant_id}#REPO#{repo_id}#RS#{hash(ref) % S}` | `REF#{ref_name}` | `oid`, `prev_oid`, `pack_id`, `updated_at`, `epoch`, `origin_region` |
| **Ref History (Rollback Log)** | `T#{tenant_id}#REPO#{repo_id}#RH#{hash(ref) % S}` | `REF#{ref_name}#{ulid}` | `oid`, `pack_id`, `ttl` (7d) — used for failover rollback and DynamoDB Streams outbox |
| **Pack Manifest** | `T#{tenant_id}#REPO#{repo_id}#MS#{hash(pack) % M}` | `PACK#{ulid}#{pack_id}` | `size_bytes`, `origin_region`, `status` (`ACTIVE` / `COMPACTED`), `created_at` |
| **Compaction Leases** | `T#{tenant_id}#REPO#{repo_id}#LEASE` | `SHARD#{m}` | `owner_id`, `lease_expires_at` |
| **Hook Configuration** | `T#{tenant_id}#REPO#{repo_id}` | `HOOKS` | Ordered list of `{hook_id, wasm_sha256, ref_glob, timeout_ms, memory_limit_mb, fail_mode}` (optional org inheritance at `T#{tenant_id}#ORG#{org_id}`) |

### Avoiding a Hot Key on `META`

`stravin-node` never includes the `META` item in per-push `TransactWriteItems` calls; doing so would reintroduce a single-partition 500 tx/sec ceiling per repository. Instead, nodes validate `failover_epoch` via a lightweight background regional write lease check (see [Multi-Region HA & Consistency](ha-consistency.md)).

## Related Documents

- [System Topology & Request Flows](topology.md) — How `stravin-node` and `stravin-pack` read and write these tables.
- [Multi-Region HA & Consistency](ha-consistency.md) — Handling S3 CRR vs. DynamoDB MREC replication lag.
- [Performance & Throughput Scaling](performance.md) — WCU math, shard ceilings, and read fan-out optimization.
- [Server-Side Hooks](hooks.md) — Using `Ref History` and DynamoDB Streams as a transactional outbox.
