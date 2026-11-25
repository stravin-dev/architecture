# Stravin Core <-> Stravin Review

This specification defines the contract between **Stravin Core** (bare Git storage engine) and **Stravin Review** (pull requests, stacked diffs, inline review, and repository browser).

## 1. Boundary & Ownership

| Concern | Source of Truth | Private Implementation Details (Never Crosses Boundary) |
| :--- | :--- | :--- |
| **Git objects, packs, refs, `default_branch`, `object_format`** | **Stravin Core** | S3 pack layout, DynamoDB `RS#s`/`RH#s`/`MS#m` sharding, `stravin-node` NVMe cache, `stravin-pack` compaction |
| **PR lifecycle, review comments, approvals, stacked-diff topology, draft state** | **Stravin Review** | Review SQL/document database, inline comment anchoring heuristics, UI notification preferences |
| **PR synthetic/head refs (`refs/stravin/pr/{pr_id}/head`, `refs/stravin/pr/{pr_id}/merge`)** | **Stravin Core** (storage) / **Stravin Review** (lifecycle) | Core stores refs via Ref-CAS; Review decides when to create, update, or clean them up |
| **Synchronous push guardrails (Tier 1 Wasm hooks)** | **Stravin Core** (execution) | `wazero` module cache, bulkhead semaphore; Review surfaces hook rejection messages to web-editor commits |

## 2. Interaction Flow

```mermaid
sequenceDiagram
    actor Dev as Developer / Agent
    participant Edge as Stravin Core (stravin-edge)
    participant Node as Stravin Core (stravin-node)
    participant Hook as Stravin Core (stravin-hook)
    participant NATS as NATS JetStream (STRAVIN_CORE)
    participant Review as Stravin Review

    Dev->>Edge: git push origin feature-branch (Smart HTTP/SSH)
    Edge->>Node: gRPC stravin.core.v1.GitWire/Stream (Cilium eBPF, 0 proxy hop)
    Node->>Node: Index pack + S3 PutObject || Wasm pre-receive
    Node->>Node: DynamoDB TransactWriteItems (RS + RH + MS)
    Node-->>Dev: Push ACK (new commit_oid)

    Note over Node,Hook: DynamoDB Streams transactional outbox (RH#s INSERT)
    Hook->>NATS: Publish stravin.core.<tenant>.<repo>.ref.updated (Nats-Msg-Id, traceparent) [vNext]
    NATS-->>Review: Durable consumer delivery (review-core-refs)
    Review->>Review: Match branch to open PRs / stacked diffs
    Review->>Node: gRPC GitData.CompareDiff(base_oid, head_oid) [vNext]
    Node-->>Review: Changed paths, hunks, merge_base_oid
    Review->>Review: Re-anchor inline comments & update PR revision

    opt Web UI Edit / PR Branch Update / Direct Merge (non-gated)
        Review->>Edge: git-receive-pack or gRPC GitData.CreateCommitAndUpdateRef [vNext]
        Edge-->>Review: Committed new_oid or REF_CONFLICT
    end
```

## 3. Auth, Tenancy & Trust Boundary

- **Cilium eBPF Transport & Network Policy:** Internal gRPC and HTTP calls between Review and Core traverse **Cilium (eBPF)** transparent WireGuard/SPIFFE mTLS with `CiliumNetworkPolicy` allowlists (zero sidecar proxy hop on Core's 256 MiB Git streams; `stravin-edge` retains Go HRW `(tenant_id, repo_id)` pinning via headless Kubernetes Service).
- **Mandatory App-Level Tenancy Check:** Cilium verifies workload identity, NOT `tenant_id`. Every Core RPC/HTTP handler and every Review JetStream consumer MUST verify `tenant_id` in constant time in application code (matching `edge.AuthorizeTenant` in Core `v1.12.x`).
- **Git Wire Operations (Implemented in Core v1.12.x):** Review authenticates to `stravin-edge` over Smart HTTP (`Authorization: Bearer <token>`) or SSH. Core `v1.12.x` enforces `edge.AuthorizeTenant` so a Review credential minted for `tenant_id=acme` can never read or write another tenant's repo.
- **Scoped Service Tokens (Proposed Core Extension vNext):** Review exchanges end-user session identity for short-lived (5-minute) Core tokens containing `tenant_id`, `repo_id`, `actor_id` (original human/agent ID for audit and Wasm `PushContext.actor_id`), and `scopes` (`git:read`, `git:write:pr-refs`, `git:write`).
- **Git Data Read API (Proposed Core Extension vNext):** Service-to-service gRPC over Cilium eBPF mTLS (or app-level TLS 1.3 mTLS locally via `RequireAndVerifyClientCert`, matching `internal/rpc/auth.go`), carrying signed service JWTs plus mandatory metadata `x-stravin-tenant-id`, `x-stravin-repo-id`, `x-stravin-actor-id`, and `traceparent`.
- **Event Transport Auth:** In Core `v1.12.x`, direct HTTP webhooks are verified via `X-Stravin-Signature-256` (`async.VerifySignature`). In `vNext`, Review consumes from NATS JetStream over Cilium mTLS + scoped NATS credentials (`stravin.core.*.*.ref.updated`) and verifies envelope `tenant_id` against the subject token.

## 4. Synchronous Interfaces

### 4.1 Git Wire Protocol — *Implemented in Core v1.12.x*

Review uses Smart HTTP/SSH on `stravin-edge` for web-editor commits, branch creation/deletion, and fallback cloning:

- `GET /{tenant_id}/{repo_id}.git/info/refs?service=git-upload-pack|git-receive-pack`
- `POST /{tenant_id}/{repo_id}.git/git-upload-pack` (`Git-Protocol: version=2`)
- `POST /{tenant_id}/{repo_id}.git/git-receive-pack` (decompressed body cap `256 MiB`)
- Internal `stravin-edge` -> `stravin-node` transport: `/stravin.core.v1.GitWire/Stream` with codec `stravin-gitwire` and headers `x-stravin-tenant-id`, `x-stravin-repo-id`, `x-stravin-operation`, `x-stravin-git-protocol`, `traceparent`.

### 4.2 Read-Only Git Data & Diff API — *Proposed Core Extension (vNext)*

To render PR diffs, file browsers, blame, and stacked-diff base comparisons without cloning full repositories into Review pods, Core exposes a stateless gRPC service backed by `stravin-node`'s warm NVMe cache and S3 pack plane:

```protobuf
syntax = "proto3";
package stravin.core.v1;

service GitData {
  rpc GetRepoMeta(GetRepoMetaRequest) returns (RepoMetaResponse);
  rpc ListRefs(ListRefsRequest) returns (ListRefsResponse);
  rpc GetCommit(GetCommitRequest) returns (CommitResponse);
  rpc ListTree(ListTreeRequest) returns (ListTreeResponse);
  rpc StreamBlob(StreamBlobRequest) returns (stream BlobChunk);
  rpc MergeBase(MergeBaseRequest) returns (MergeBaseResponse);
  rpc CompareDiff(CompareDiffRequest) returns (stream DiffEntry);
  rpc CreateCommitAndUpdateRef(CreateCommitRequest) returns (UpdateRefResponse);
}

message CompareDiffRequest {
  string tenant_id = 1;
  string repo_id = 2;
  string base_oid = 3;         // 40-hex (sha1) or 64-hex (sha256)
  string head_oid = 4;
  bool three_dot = 5;          // true => diff(merge_base(base, head), head)
  uint32 context_lines = 6;    // default 3
  uint32 max_files = 7;        // pagination cap (default 500)
  string page_token = 8;
}

message DiffEntry {
  string path = 1;
  string old_path = 2;         // populated on rename
  string change_kind = 3;      // "add" | "modify" | "delete" | "rename"
  string old_blob_oid = 4;
  string new_blob_oid = 5;
  bool binary = 6;
  uint32 additions = 7;
  uint32 deletions = 8;
  bytes unified_patch = 9;     // truncated if > max_patch_bytes
  bool patch_truncated = 10;
}
```

### 4.3 Tier 1 Wasm Hook Rejection Surface — *Implemented in Core v1.12.x*

When Review submits a commit (e.g., applying a suggested change or resolving a conflict in the UI), Core executes configured Tier 1 `wazero` Wasm hooks (`HookHostABI`). A `REJECT` verdict returns the hook's `message` and per-ref `ref_verdicts` over Git side-band stderr (or structured `FAILED_PRECONDITION` details on `CreateCommitAndUpdateRef`) so Review can render the exact guardrail violation inline.

## 5. Asynchronous Events & Streams

### 5.1 Core -> Review: Ref Update Event (`STRAVIN_CORE` JetStream)

- **Implemented in Core v1.12.x (`internal/hooks/async/dispatcher.go`):** `stravin-hook` currently consumes DynamoDB Streams `INSERT` on `RH#s` and POSTs flat HTTP `WebhookPayload` (`tenant_id`, `repo_id`, `ref`, `oid`, `pack_id`, `timestamp`) with headers `X-Stravin-Event: push`, `X-Stravin-Signature-256: sha256=<hex>`, and `traceparent`.
- **Proposed Core Extension (vNext — NATS JetStream):** `stravin-hook` publishes the Standard Async Event Envelope to stream `STRAVIN_CORE` on subject `stravin.core.<tenant_id>.<repo_id>.ref.updated` with NATS headers `Nats-Msg-Id: <idempotency_key>`, `Stravin-Event-Type: core.ref.updated`, `Stravin-Schema-Version: 1.0`, and `traceparent`:

```json
{
  "event_id": "evt_01JDF8Z7Q2K9M4N6P8R0T2V4W6",
  "event_type": "core.ref.updated",
  "schema_version": "1.0",
  "occurred_at": "2026-11-24T22:15:03.412Z",
  "tenant_id": "acme",
  "repo_id": "monorepo",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "idempotency_key": "acme:monorepo:refs/heads/feat/stack-1:01JDF8Z7Q2K9M4N6P8R0T2V4W6",
  "data": {
    "ref": "refs/heads/feat/stack-1",
    "oid": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "prev_oid": "9999999999999999999999999999999999999999",
    "pack_id": "9c1185a5c5e9fc54612808977ee8f548b2258d31a1b2c3d4e5f60718293a4b5c",
    "ulid": "01JDF8Z7Q2K9M4N6P8R0T2V4W6",
    "epoch": 3,
    "actor_id": "usr_alice",
    "object_format": "sha1",
    "is_force_push": false
  }
}
```

- **Consumer & Ordering:** Review binds durable pull consumer `review-core-refs` on `STRAVIN_CORE` filtered to `stravin.core.*.*.ref.updated`. DynamoDB Streams guarantees per-shard ordering for a single `ref_name` (`RH#{fnv64a(ref) % S}`). JetStream deduplicates on `Nats-Msg-Id`, and Review deduplicates on `(tenant_id, repo_id, ref, ulid)`, ignoring out-of-order stale events whose `ulid` is older than the last applied revision for that ref.

## 6. Shared Data Contracts & Identifiers

- **Repository Identity:** `(tenant_id, repo_id)` + immutable `object_format` (`sha1` | `sha256`) and mutable `default_branch` (from Core `META`).
- **PR Reference Namespace:** Review-managed refs live strictly under `refs/stravin/pr/{pr_id}/head` and `refs/stravin/pr/{pr_id}/merge` so they never collide with user branches (`refs/heads/*`) or Gate refs (`refs/stravin/gate/*`).
- **OID Encoding:** Always lowercase hex matching `object_format` (40 chars for `sha1`, 64 chars for `sha256`). Zero OID (`ddb.ZeroOIDForFormat`) represents ref creation (`old_oid`) or deletion (`new_oid`).

## 7. Failure Modes, Timeouts & Idempotency

| Failure Scenario | Behavior & Degradation | Timeout / Retry Policy |
| :--- | :--- | :--- |
| **`stravin-node` / `GitData` slow or unavailable** | Review serves cached PR metadata, comments, and approvals from its own DB; diff pane shows "Git diff temporarily unavailable" with manual retry. | `GetCommit`/`ListTree`: 2 s; `CompareDiff`: 10 s; 2 retries with jitter on `UNAVAILABLE`. |
| **Review consumer down or lagging** | Messages buffer durably in `STRAVIN_CORE` for the `review-core-refs` consumer; after `MaxDeliver` exhaustion, JetStream emits a DLQ advisory to `STRAVIN_DLQ`. | Review resumes from its JetStream consumer offset and runs a `ListRefs` reconciliation sweep on PR view when `head_oid` looks stale. |
| **Concurrent push during UI edit (`REF_CONFLICT`)** | Core Ref-CAS rejects the write atomically; Review reloads latest `head_oid` and prompts the user to rebase or re-apply. | Non-retryable (`409` / `FAILED_PRECONDITION`). |
| **Core regional failover (`failover_epoch` advance / ref rewind)** | Core may rewind un-replicated refs during `stravin-ctrl` scrub. Review detects `oid` mismatch via `core.ref.updated` or `ListRefs` and marks affected PR revisions as `rewound` rather than crashing. | Idempotent state convergence against Core's authoritative `RefState`. |

## 8. Meet-in-the-Middle Bridge Checklist

### Side A: Stravin Core Build Checklist

- [ ] Preserve `stravin-hook` per-ref `RH#s` ordering and `traceparent` propagation (Implemented in Core v1.12.x).
- [ ] Add NATS JetStream publisher to `stravin-hook` targeting `stravin.core.<tenant_id>.<repo_id>.ref.updated` with `Nats-Msg-Id` = `idempotency_key` and additive fields (`prev_oid`, `ulid`, `epoch`, `actor_id`, `object_format`) (vNext).
- [ ] Implement read-only `stravin.core.v1.GitData` gRPC service on `stravin-node` with constant-time app-level `tenant_id` authorization (vNext).
- [ ] Support short-lived scoped tokens with `actor_id` forwarding to Wasm `PushContext` (vNext).

### Side B: Stravin Review Build Checklist

- [ ] Bind durable JetStream consumer `review-core-refs` on `STRAVIN_CORE` (`stravin.core.*.*.ref.updated`), verifying envelope `tenant_id` matches subject `tenant_id`.
- [ ] Store `(tenant_id, repo_id, object_format)` on every PR; never hardcode 40-char SHA-1 assumptions.
- [ ] Implement idempotent PR revision sync keyed by `(ref_name, ulid)` plus on-demand `ListRefs` reconciliation on PR view.
- [ ] Restrict all Review-managed refs to `refs/stravin/pr/{pr_id}/*`.

### Shared Contract-Test Fixtures

- `fixtures/core-review/webhook-push-v1.json` — Legacy Core v1.12.x flat HTTP push webhook + expected `X-Stravin-Signature-256` vector.
- `fixtures/core-review/nats-ref-updated-vnext.json` — NATS JetStream `stravin.core.<tenant>.<repo>.ref.updated` message, headers (`Nats-Msg-Id`, `traceparent`), and branch create / fast-forward / force-push / delete cases (`sha1` and `sha256`).
- `fixtures/core-review/compare-diff-cases.json` — Rename, binary file, truncated large diff, and 3-dot merge-base test vectors.
