# Stravin Architecture & Design

**Stravin** is a stateless, multi-region hosted Git platform built in Go on AWS S3 and DynamoDB. It separates durable object storage from reference linearization so repositories scale to thousands of concurrent pushes per second without penalizing home-region write latency for cross-region high availability.

## Platform Overview

Stravin is structured as a bare Git storage engine (**Stravin Core**) carrying modular upper platform layers:

| Layer | Name | Scope |
| :--- | :--- | :--- |
| **Bare Git Engine** | **Stravin Core** | Multi-region Git wire protocol (SSH / Smart HTTP), immutable S3 packfile storage, DynamoDB Ref-CAS, Wasm hooks, and sharded compaction |
| **Code Review & UI** | **Stravin Review** | Pull requests, stacked diffs, inline review, and repository browser |
| **CI / Runners** | **Stravin Run** | Ephemeral build/test runners, pipelines, and isolated execution sandboxes |
| **Code Search** | **Stravin Index** | Trigram full-text search, symbol navigation, and cross-repository dependency graphs |
| **Merge & Policy** | **Stravin Gate** | Serialized merge queues, branch protection, policy checks, and agent guardrails |

## Three-Tier Naming Convention

Stravin separates brand identity from operational clarity across three tiers:

1. **Umbrella Platform (`Stravin`):** A coined two-syllable root (*strata* for layered S3 packfiles and compaction tiers + *rivet/tenon* for atomic immutable binding). Avoiding Git-specific terms at the umbrella level lets CI, code review, search, and merge queues sit cleanly underneath.
2. **Product Layers (`Stravin <Noun>`):** Each functional layer pairs the platform name with a single plain noun: `Stravin Core`, `Stravin Review`, `Stravin Run`, `Stravin Index`, and `Stravin Gate`.
3. **Go Daemons (`stravin-<role>`):** Every service binary, container image, and `cmd/` package maps directly to its operational role:
   - `stravin-edge` — SSH / Smart HTTP ingress, authentication, and home-region routing proxy
   - `stravin-node` — Stateless virtual Git replica with warm NVMe bare-repo caches and Wasm sync hook execution
   - `stravin-pack` — Out-of-band sharded packfile compaction, index generation, and delayed garbage collection
   - `stravin-ctrl` — Multi-region failover orchestration, fencing epochs, and post-failover integrity scrubbing
   - `stravin-hook` — Asynchronous post-receive hook and webhook worker pool consuming DynamoDB Streams

## Organization Repositories & Licensing

Splitting repositories by role keeps open-source engine code, documentation, marketing copy, and brand assets on clean legal and deployment boundaries.

| Repository | Purpose | Go Module / Hosting | License |
| :--- | :--- | :--- | :--- |
| `stravin-dev/core` | Stateless, multi-region Git storage engine in Go backed by S3 and DynamoDB | `stravin.dev/core` (via `?go-get=1` vanity import tag) | **Apache 2.0** |
| `stravin-dev/architecture` | Platform architecture and technical design documentation (this site) | GitHub Pages subdomain of `stravin.dev` | **Apache 2.0** |
| `stravin-dev/website` | Official apex marketing site (`stravin.dev`), Astro on Cloudflare Workers (also serves `?go-get=1` vanity middleware) | `stravin.dev` | **All Rights Reserved** (or Split License: Apache 2.0 code + All Rights Reserved copy/assets) |
| `stravin-dev/assets` | Brand identity, SVG marks, color palette, typography, and visual assets | Static brand asset repository | **All Rights Reserved** |
| `stravin-dev/.github` | Organization profile README, community health files, and reusable workflow templates | GitHub org defaults | **Apache 2.0** |

!!! note "Brand & Visual Assets"
    All Stravin logos, SVG lockups, typography specifications, color palettes, and CSS design tokens are maintained separately in `stravin-dev/assets`.

### Licensing Rationale

- **Apache 2.0 for `stravin-dev/core`:** Chosen over MIT for three infrastructure-grade protections: an explicit contributor patent grant with a defensive retaliation clause, explicit trademark reservation in Section 6 (preventing forks from appropriating the **Stravin** brand), and frictionless enterprise adoption aligned with CNCF norms. Apache 2.0 remains fully permissive for proprietary or commercial upper layers.
- **GPLv2 Subprocess Boundary:** Upstream `git/git` is licensed under GPLv2-only, which is incompatible with Apache 2.0 for direct linking (such as static `cgo` linking without an exception). `stravin-dev/core` avoids derivative-work coupling by invoking `git` binaries (`git-upload-pack`, `git-receive-pack`, `git index-pack`) strictly as separate OS subprocesses communicating over pipes/stdin/stdout, alongside pure-Go packfile and protocol implementations.
- **All Rights Reserved / Split License for `stravin-dev/website`:** Keeping `stravin-dev/website` public provides free GitHub Actions minutes without granting open-source reuse of marketing copy or design. Default copyright (**All Rights Reserved**) is the simplest boundary; a split license (Apache 2.0 for Astro/Workers source code, All Rights Reserved for copy and visual assets) is used only if sharing Workers middleware openly is desired.

## Stravin Core Design Documents

- [System Topology & Request Flows](core/topology.md) — Architectural comparison with GitHub Project Rubicon and Cursor Continuity, multi-region topology, Go service responsibilities, and write/read/compaction flows.
- [Storage Layer: S3 & DynamoDB](core/storage.md) — Immutable sharded S3 pack plane, durability-before-visibility, S3 CRR + RTC, DynamoDB Global Tables (MREC vs. MRSC), and adaptive key-sharded schema.
- [Multi-Region HA & Consistency](core/ha-consistency.md) — Resolving the metadata-before-blob race condition, transparent origin fallback, disaster failover scrub and ref rewind, split-brain fencing, and CAP/PACELC analysis.
- [Performance & Throughput Scaling](core/performance.md) — Single-repository throughput ceilings across workload regimes, DynamoDB and S3 bottleneck math, tiered LSM compaction, and shard read fan-out mitigation.
- [Server-Side Hooks](core/hooks.md) — Three-tier hook architecture combining synchronous `wazero` WebAssembly gates overlapped with S3 uploads, DynamoDB Streams transactional outbox for async hooks, `HookHostABI`, and resource guardrails.
- [Sandboxed Execution & Multi-Tenancy](core/isolation-multitenancy.md) — Linux namespace/cgroup v2 sandboxing vs. tenant-pinned microVMs, Git config lockdown, multi-tenant performance impact, avoiding orders-of-magnitude traps, and Day-1 architectural seams.

## Operations & Tooling

- [Local Development](operations/local-dev.md) — Docker Compose local development stack using Floci for AWS emulation (S3, DynamoDB, Streams, KMS), bootstrap workflow, and the upstream Floci PR policy for missing AWS features.
- [Telemetry & Observability](operations/telemetry.md) — Full OpenTelemetry and Grafana LGTM (Loki, Grafana, Tempo, Prometheus) architecture, end-to-end distributed trace flows, attribute/cardinality guardrails, and Golden Signals dashboards.
