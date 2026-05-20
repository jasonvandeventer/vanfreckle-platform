# ADR: Enforce non-default status for local-path StorageClass

**Date:** 05/19/2026
**Status:** Accepted

## Context

K3s bundles the `local-path-provisioner` and its corresponding `local-path` StorageClass, which is annotated as the default class on install. Longhorn was installed later and also configured as the default class. Kubernetes does not define behavior when two StorageClasses are both marked default; PVCs without an explicit `storageClassName` may bind to either, with the outcome dependent on alphabetical ordering or API server version.

The platform rule (per `CLAUDE.md`) is that Longhorn is the default StorageClass. Two defaults violates this rule and creates risk that future PVCs land on `local-path` — which is node-local, unreplicated, and unbacked up — instead of Longhorn.

During the 2026-05-16 audit, the conflict was discovered and resolved manually via `kubectl patch` to remove the default annotation from `local-path`. This ADR makes the fix durable.

## Decision

Override the `is-default-class` annotation on the bundled `local-path` StorageClass to `false`, expressed in Git and reconciled by ArgoCD. The `local-path` StorageClass remains available for any workload that explicitly references it; it is simply no longer the default.

## Rationale

- Longhorn provides replicated, backed-up storage suitable for production workloads
- `local-path` provides node-local, unreplicated storage — appropriate only for explicitly-chosen ephemeral use cases
- Default behavior should favor the safer option; opt-in to local-path requires explicit `storageClassName`
- Expressing the override in Git ensures the fix survives k3s upgrades and reinstalls

## Alternatives considered

- **Disable k3s's bundled local-path entirely** via `--disable local-storage` in the k3s server config. Cleaner, but requires out-of-band k3s configuration changes. Deferred for a future "what do we want from k3s" review.
- **Leave the fix as manual drift.** Rejected — violates the "ArgoCD is authoritative" rule and would silently revert on any k3s reinstall.

## Consequences

- New PVCs without explicit `storageClassName` will bind to Longhorn (the sole remaining default)
- Existing PVCs are unaffected (default class only applies at PVC creation time)
- The `local-path` StorageClass remains usable for workloads that explicitly opt in
- A new ArgoCD Application is required to manage the override; this introduces a small additional bootstrap-tier resource (the Application manifest itself)
- The 2026-05-16 manual patch becomes redundant; ArgoCD self-heal will maintain the correct annotation regardless of future drift
