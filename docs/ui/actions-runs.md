# Actions & Workflows (`Stravin Run`)

The Actions workspace gives developers an immediate GitHub Actions mental model—workflow filter rail, recent runs list, job graph, and streaming logs—while cleanly exposing **Temporal DAG execution**, **`tree_oid` verdict reuse**, and **`Hosted` vs `External OIDC` runner pools**.

## Actions & Workflows List

![Stravin Actions and Workflows List mockup](assets/actions-runs-list.png)

### Key Elements

- **Left Workflow Rail & Runner Pool Health:** Lists repository workflows with run counts alongside a compact **Runner Pools** card showing live `Hosted` capacity and `External OIDC` online runners without opening a separate admin page.
- **Clear Run Rows:** Every run displays status (`Running`, `Passed`, `Failed`, `Reused`), commit or PR title, workflow name, branch/SHA, runner pool badge (`Hosted` in Strata Teal vs `External OIDC` in Blueprint Blue), elapsed duration, and a one-click **`Re-run`** button.
- **`tree_oid` Reuse Transparency:** Runs satisfied completely by cached verdicts show a Glacier Mint `Reused` pill and near-zero duration so engineers immediately understand why CI completed in seconds.

## Workflow Run Detail

![Stravin Workflow Run Detail mockup](assets/actions-run-detail.png)

### Key Elements

- **Run Header & Direct Controls:** Displays run status (`Running · 4/6 jobs`), `tree_oid` reuse summary, triggering actor/branch/SHA, elapsed time, and two clear actions: **`Cancel run`** and **`Re-run failed`**.
- **Visual Temporal Job DAG:** Sits directly above the log viewer so developers see job dependencies and critical-path progress at a glance:
    - Cached jobs (`lint-and-vet`, `build-binaries`) display a **`tree_oid reused`** pill and `0s` duration.
    - The active or selected job (`integration-floci`) is outlined in Rivet Terracotta and displays its runner pool (`External OIDC · arm64-04`).
    - Downstream verdict and Gate eligibility nodes remain visibly queued until upstream dependencies finish.
- **Collapsible Live Streaming Step Logs:** Clicking any DAG node updates the log panel below in place. Completed steps collapse to single summary lines with durations; the active step streams timestamped `JetBrains Mono` output with inline log search and a `Raw log` link.

## End-to-End Developer Flow

```mermaid
flowchart LR
    Trigger["1. Push / PR / Manual Trigger (Core -> Run)"]
    DAG["2. Temporal Workflow DAG (Reuse tree_oid Verdicts)"]
    Lease["3. Schedule Remaining Jobs (Hosted or External OIDC)"]
    Stream["4. Watch Live DAG & Step Logs (Cancel or Re-run)"]
    Verdict["5. Publish Verdict (NATS JetStream -> Review & Gate)"]

    Trigger --> DAG --> Lease --> Stream --> Verdict
```

## Product Interface Grounding

- **Core ⟷ Run:** Ephemeral runners fetch via Core's Valkey + S3 pack cache and `bundle-uri` with short-lived scoped Git tokens ([Core ⟷ Run](../interfaces/core-run.md)).
- **Review ⟷ Run:** Streams check status, inline annotations, and idempotent cancel/re-run actions back to PR views ([Review ⟷ Run](../interfaces/review-run.md)).
- **Run ⟷ Gate & External Runners:** Binds verdicts to `(tree_oid, commit_oid, policy_version, app_id)` and supports Phase 1 pull-based OIDC runner leases ([Run ⟷ Gate](../interfaces/run-gate.md), [ADR-0002](../adr/0002-external-runner-seam-and-oidc-auth.md)).
