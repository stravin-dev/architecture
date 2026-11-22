# Server-Side Hooks

Stravin Core supports language-agnostic, sandboxed server-side hooks without sacrificing multi-thousand-push/sec throughput by combining **WebAssembly (`wazero`)** with a **strict synchronous/asynchronous tier split**.

In traditional Git servers (Gitaly, Gitolite, bare Git), a slow `pre-receive` hook holds filesystem ref locks or stalls concurrent pushes on the storage host. Because Stravin Core acquires **no locks before the final DynamoDB `TransactWriteItems`**, a synchronous hook running on `branch-a` never blocks a concurrent push to `branch-b`, and nearly all hook execution latency is hidden inside the S3 upload window.

## Three-Tier Hook Architecture

Hooks are divided strictly by whether they must reject a push before persistence and whether they require external I/O:

| Tier | Git Equivalent | Execution Model | Capabilities Allowed | Latency Impact on `git push` | Use Cases |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tier 1: Hermetic Gate** | `pre-receive` / `update` | **Synchronous** Wasm on `stravin-node` (concurrent with S3 `PutObject`) | Pure CPU + read-only Git object host calls; **zero network, zero disk** | **~0 ms net** (overlapped with S3 upload; capped at 50–100 ms) | Secret scanning, commit lint, max file size, path/branch rules, GPG/SSH signature checks |
| **Tier 2: Reactive Hook** | `post-receive` | **Asynchronous** worker pool (`stravin-hook`) via DynamoDB Streams | Outbound HTTP, external APIs, heavy compute, cross-repo queries | **0 ms** (decoupled via transactional outbox) | Webhooks, CI triggers, issue/chat sync, search indexing, audit pipelines |
| **Tier 3: Heavy Blocking** | Merge checks | **Async + Gated Merge** in **Stravin Gate** | Arbitrary CI builds, LLM review, external approvals | **0 ms** on feature branch pushes; enforced at merge time | Unit tests, builds, external policy APIs blocking `main` |

## Concurrent S3 Upload & Wasm Overlap Flow

Rather than running `pre-receive` hooks serially before or after S3 persistence, `stravin-node` overlaps Wasm execution with the S3 pack upload:

```mermaid
flowchart TD
    Push["git push stream"] --> Index["1. Index & validate pack locally on stravin-node NVMe/RAM"]
    Index --> Stale{"2. Optimistic stale-ref check\n(local warm ref cache)"}
    Stale -- "Stale old_oid" --> FastReject["Fast-reject in microseconds\n(skip S3 & Wasm)"]
    Stale -- "Current" --> Fork["Run concurrently"]

    Fork --> S3Up["3a. Goroutine A:\nUpload .pack + .idx to S3\n(~15–30 ms RTT)"]
    Fork --> WasmRun["3b. Goroutine B:\nRun Sync Wasm Hook(s) in RAM\n(~1–10 ms pure compute)"]

    S3Up --> Join{"Wait for both"}
    WasmRun --> Join

    Join -- "Hook rejected" --> Cancel["Cancel S3 context,\nstream stderr over Git side-band,\nNEVER touch DynamoDB"]
    Join -- "Hook allowed & S3 200 OK" --> DDB["4. DynamoDB TransactWriteItems\n(Ref-CAS + Ref History + Manifest)"]

    DDB --> Ack["ACK client"]
    DDB -.->|"DynamoDB Streams\n(Transactional Outbox)"| AsyncPool["5. stravin-hook Async Pool\n(post-receive webhooks / Wasm)"]
```

Three properties preserve write throughput at scale:

1. **Zero net latency for fast hooks:** S3 `PutObject` typically takes 15–30 ms, whereas a compiled Wasm hook checking commit messages, file sizes, or regex secret patterns finishes in 1–10 ms—completing before S3 returns HTTP `200 OK`.
2. **Safe cancellation on reject:** If a hook rejects, `stravin-node` cancels the S3 upload context and skips DynamoDB entirely. Even if the S3 upload already completed, no manifest or ref points to the pack, leaving the repository clean while S3 lifecycle rules or `stravin-pack` GC reap the unreferenced object.
3. **Zero wasted work on stale pushes:** Checking `old_oid` against the warm in-memory ref cache rejects stale non-fast-forward pushes in microseconds before starting S3 uploads or Wasm execution.

## Wasm Runtime, Storage & Host ABI

### Runtime & Binary Storage

- **Pure-Go `wazero` runtime:** Embeds directly into `stravin-node` with zero `cgo`, caches compiled modules in RAM, instantiates sandboxes in ~50–200 µs, and enforces strict capability-based isolation (no filesystem or network access by default).
- **Content-addressed S3 storage:** Hook `.wasm` binaries are **never** loaded from files committed inside the Git repository (which would let any committer disable guardrails). Instead, binaries are stored at `s3://git-objects-{region}/hooks/{wasm_sha256}.wasm` and replicated across regions automatically via S3 CRR.
- **DynamoDB pipeline configuration:** Active hooks are stored under `PK: T#{tenant_id}#REPO#{repo_id}, SK: HOOKS` (with optional org-level inheritance under `ORG#{org_id}`) as an ordered list of `{hook_id, wasm_sha256, ref_glob, timeout_ms, memory_limit_mb, fail_mode}`.
- **Pre-compiled LRU cache:** `stravin-node` caches `wazero.CompiledModule` instances keyed by `wasm_sha256`, compiling each module version once per node.

### Read-Only `HookHostABI`

Inside WebAssembly, hooks cannot fork `git rev-list`, `git diff-tree`, or `git cat-file`, and copying an entire packfile into Wasm linear memory wastes RAM. `stravin-node` exposes a minimal, bounded host-function ABI directly over the newly indexed packfile and warm repo cache:

```go
// Host functions exposed by stravin-node to the Wasm guest.
type HookHostABI interface {
	// Metadata about the incoming push (actor, repo, ref transitions).
	GetPushContext() PushContext // []RefUpdate{Ref, OldOID, NewOID}, ActorID

	// Fast header-only commit inspection via commit-graph + newly indexed pack.
	ListNewCommits(oldOID, newOID [20]byte, limit uint32) ([]CommitMeta, error)

	// Changed file paths, modes, and blob sizes without loading file contents.
	DiffTree(oldTreeOID, newTreeOID [20]byte, limit uint32) ([]TreeChange, error)

	// Bounded chunked blob reader so secret scanners never blow Wasm memory caps.
	ReadBlobChunk(blobOID [20]byte, offset uint64, maxBytes uint32) ([]byte, error)

	// Emit structured allow/reject decisions (supports per-ref or whole-push reject).
	SetVerdict(verdict HookVerdict) // ALLOW | REJECT + user-facing stderr message
}
```

Unifying Git's `pre-receive` and `update` semantics into a single Wasm invocation that returns either a global decision or per-ref verdicts avoids invoking the runtime `N` times on multi-branch pushes.

## Async Hooks: Transactional Outbox via DynamoDB Streams

Because every accepted push already writes a `Ref History` item inside the atomic DynamoDB `TransactWriteItems` call, enabling **DynamoDB Streams** provides a built-in **transactional outbox** with zero extra write-path overhead:

- An accepted push is guaranteed to emit its `post-receive` event, and a rejected push can never fire a webhook.
- A dedicated consumer pool (`stravin-hook` or Lambda/SQS fan-out) reads the stream, invokes configured outbound signed webhooks or network-enabled async Wasm modules, and manages retries, exponential backoff, and dead-letter queues completely off the `stravin-node` fleet.
- Checks requiring external network I/O *and* merge blocking (CI tests, external security scanners, human approvals) belong in **Stravin Gate**, keeping Stravin Core fast and deterministic.

## Resource Guardrails & Isolation Policy

To ensure buggy or adversarial hooks cannot degrade `stravin-node`:

- **Hard resource caps:** Enforce per-invocation linear memory limits (e.g., 16–64 MB), strict wall-clock timeouts via `wazero.NewRuntimeConfig().WithCloseOnContextDone(true)` (50 ms default, 250 ms max), and host-call budgets (e.g., max 1,000 commits walked or 10 MB of blob bytes read per push).
- **Dedicated bulkhead pool:** Run Wasm hooks behind a bounded worker semaphore on `stravin-node` (e.g., capped at 25% of host vCPUs) so a burst of hook-heavy pushes on one repository cannot starve `git-upload-pack` reads or pack uploads for other repositories on the same host.
- **In-process vs. sidecar boundary:** In-process `wazero` fits self-hosted enterprise deployments and trusted org-admin hooks. For public multi-tenant SaaS executing arbitrary user-uploaded Wasm, preserve the exact same `HookHostABI` contract while moving execution out-of-process into a local Unix-socket sidecar (`stravin-hook-exec` isolated with cgroup v2 and seccomp) so heap spikes or speculative-execution flaws cannot touch `stravin-node` memory.
- **Fail-open vs. fail-closed policy:** Security hooks (secret scanning, signature verification) must configure `fail_mode: closed` to reject pushes on timeout or OOM; advisory lint hooks may configure `fail_mode: open` to emit a warning over Git's side-band stream without blocking the push.

## Related Documents

- [System Topology & Request Flows](topology.md) — Full write path and `stravin-node` architecture.
- [Storage Layer: S3 & DynamoDB](storage.md) — `HOOKS` metadata item and S3 binary layout.
- [Sandboxed Execution & Multi-Tenancy](isolation-multitenancy.md) — Isolation boundaries for multi-tenant deployments.
