# CloudNativePG — operator only (this phase)

`kustomization.yaml` installs ONLY the CNPG operator/controller, pinned to **1.29.1**
(the hard CVE-2026-44477 floor). It is referenced by the `cnpg-operator` ArgoCD
Application (`../../argocd/apps/cnpg-operator.yaml`).

## Deliberately NOT here yet
- **No `Cluster` CR** (the actual Postgres database).
- **No database role / secret / backup config.**

The Postgres topology (single-instance-on-Longhorn vs. CNPG-managed HA) is a decision
to be **reconciled with the v4 migration blueprint** before deploying — build guide
Phase 9. PostgreSQL major is **18** (CNPG default operand; the Nobara throwaway in
`../../nobara/throwaway-postgres.sh` matches). The Cluster CR, its DSN SealedSecret,
and the read-only `cartarch-mcp` role land in a later commit, after that decision and
behind the migration stop-point.

## Why pin via release-1.29 branch
`release-1.29/releases/cnpg-1.29.1.yaml` is the immutable tagged operator manifest for
that patch. Bumping the patch = bump this URL (stay ≥ 1.29.1, never below).
