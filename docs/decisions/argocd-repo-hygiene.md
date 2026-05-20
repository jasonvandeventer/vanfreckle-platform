# ADR: ArgoCD repository and Application hygiene fixes

**Date:** 2026-05-19
**Status:** Accepted

## Context

During a session intended to reconcile the `local-path` StorageClass fix into Git, two pre-existing problems surfaced that were breaking ArgoCD. Both were resolved in the same session. This ADR documents both, as they share a root cause: cruft in repository and Application state that ArgoCD does not tolerate.

### Problem 1: Out-of-bounds symlinks

The repository root contained six Markdown files that were symbolic links pointing to `/home/jason/lab/ai-context/mana-archive-platform/` — outside the repository boundary:

- `CLAUDE.md`
- `current-status.md`
- `backup-strategy.md`
- `cluster-layout.md`
- `observability.md`
- `roadmap.md`

ArgoCD's repo-server rejects any repository containing symlinks that resolve outside the repo, as a security control against arbitrary filesystem reads. On encountering one, it aborts manifest generation for the entire repository. This caused all Applications sourcing from the repo (`platform-root`, `mana-archive`, and by extension any child apps) to fail with:

> `ComparisonError: Failed to load target state: failed to generate manifest ... repository contains out-of-bounds symlinks. file: backup-strategy.md`

Two symlinks had existed since 2026-05-15; four more were added 2026-05-19, which is what tipped repo-server into hard failure.

### Problem 2: Stale finalizer on the `longhorn` Application

The `longhorn` ArgoCD Application carried a `deletionTimestamp` of `2026-04-20` (cluster build day) and two stale finalizers (`pre-delete-finalizer.argocd.argoproj.io` and its `/cleanup` variant). The Application had been running `Healthy / Synced` for a month, but the UI showed a persistent `Deleting` badge. The stale state also poisoned the app-of-apps health rollup, leaving the parent `platform-root` Application stuck in `Progressing`.

The most likely origin is a delete-and-recreate of the `longhorn` Application during initial cluster setup, which left a finalizer reference orphaned on the object.

## Decision

### Problem 1

Remove the six AI-context Markdown files from the repository entirely and add them to `.gitignore`. These files are platform-memory / AI-context documents, not Kubernetes deployment artifacts. Their canonical location is `~/lab/ai-context/mana-archive-platform/`. A GitOps deployment repository should contain deployment artifacts only.

### Problem 2

Remove the stale finalizers from the `longhorn` Application via `kubectl patch`, allowing the stuck object to finish deleting. Because `platform-root` is an app-of-apps sourcing `k8s/argocd/apps/`, it immediately recreated the `longhorn` Application from `k8s/argocd/apps/longhorn.yaml` — fresh, with no `deletionTimestamp` and no stale finalizer. The recreated Application re-adopted the still-running Longhorn resources.

## Rationale

- **Symlinks:** Replacing the symlinks with real file copies was considered but rejected — it would duplicate content and let the repo copies drift from the `ai-context` originals. Removing them entirely is cleaner; the deploy repo should not carry context docs at all.
- **Finalizer:** Letting the deletion complete was safe only because verification confirmed the `deletionTimestamp` predated the outage by a month, the finalizers were the benign `pre-delete` variants (not `resources-finalizer`, which would cascade-delete managed resources), the Longhorn safety flag `deleting-confirmation-flag` was `false`, and Longhorn volumes were healthy. The recreation by `platform-root` was near-instant, so the `longhorn` Application object existed again within seconds and no Longhorn resource was ever deleted.

## Consequences

- ArgoCD repo-server can render the repository again; all Applications returned to `Synced`.
- The `platform` Application (managing the `local-path` fix) became visible and synced once repo-server was unblocked — it had been silently prevented from appearing by Problem 1.
- Clearing the stale finalizer also resolved `platform-root`'s `Progressing` health state. This was previously attributed solely to a known ArgoCD 3.3.6 health-rollup bug; the stale `longhorn` finalizer was in fact a contributing cause. The 3.3.6 → 3.3.10 upgrade is consequently downgraded from "fixes a live symptom" to routine version hygiene.
- The `longhorn` Application's `Deleting` badge is gone.

## Lessons

1. **The deployment repository contains deployment artifacts only.** AI-context and platform-memory documents live in `~/lab/ai-context/`, never symlinked into the deploy repo. Symlinks that resolve outside the repo break ArgoCD repo-server for the entire repository.
2. **Live `kubectl` fixes must be captured.** The finalizer cleanup was a direct cluster mutation. This ADR is its record. Recurring pattern in this project: work gets done, capture gets skipped — every live change needs a written home.

## Follow-ups

- Consider the ArgoCD 3.3.6 → 3.3.10 upgrade as routine hygiene (no longer urgent).
- The git history contains two commits with identical messages (`eb4b529`, `69370a1`) from the `local-path` fix work — cosmetic history clutter, left as-is.
