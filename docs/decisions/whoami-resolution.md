# ADR: whoami Application drift resolution

**Date:** 2026-04 (resolved in earlier session, captured 2026-05-16)
**Status:** Accepted

## Context

During an earlier audit session, a `whoami` ArgoCD Application was discovered that had drifted from its Git definition. The Application was a leftover from early cluster experimentation and was no longer needed for any production workload.

## Decision

Remove the `whoami` Application via clean GitOps deletion (remove the Application manifest from `k8s/argocd/apps/` and let ArgoCD reconcile the deletion), rather than `kubectl delete` directly.

## Rationale

The drift could have been resolved either by re-syncing the Application to its Git-defined state or by removing it entirely. Removal was chosen because:

- The Application had no current operational purpose
- Keeping it would have meant continuing to maintain its manifest indefinitely
- Removing via GitOps reinforces the "ArgoCD is authoritative" rule from `CLAUDE.md` — even cleanup happens through Git

Using `kubectl delete` directly was rejected because it would have left an Application manifest in Git pointing at nothing, creating the inverse drift problem (Git-resident definition with no cluster resources to match).

## Consequences

- One fewer Application to track in ArgoCD
- Pattern established for future drift resolution: prefer GitOps-native removal over `kubectl delete`
- This ADR was drafted in the original session but not committed until the 2026-05-16 audit; lesson captured in `docs/inventory.md` Open Questions
