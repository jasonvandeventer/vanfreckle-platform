# CloudNativePG — operator only (this phase)

`kustomization.yaml` installs ONLY the CNPG operator/controller, pinned to **1.29.1**
(the hard CVE-2026-44477 floor). It is referenced by the `cnpg-operator` ArgoCD
Application (`../../argocd/apps/cnpg-operator.yaml`).

## Scope: operator only — the database lives in sibling dirs

This dir is **operator/controller only by design**. The actual Postgres resources landed
separately once the topology decision was made (Phase 9, 2026-06):

- **`Cluster` CR + backup wiring** → `../cnpg-cartarch-prod/` (the prod Cartarch cluster:
  3-instance **CNPG-managed HA**, PG18, `longhorn-ssd`, WAL archiving + daily
  `ScheduledBackup` via the Barman-Cloud plugin → R2). This is the **v4 cutover target**.
- **CRDs** → `../cnpg-crds/` (split out, synced ServerSideApply — never `Replace=true`).
- **Barman-Cloud plugin + R2 ObjectStore** → `../cnpg-barman-plugin/` + `../cnpg-backup-config/`.

The topology question (single-instance-on-Longhorn vs. CNPG-managed HA) was **resolved in
favour of CNPG-managed HA**, reconciled with the v4 migration blueprint. PostgreSQL major
is **18** (CNPG default operand; the Nobara throwaway in `../../nobara/throwaway-postgres.sh`
matches). CNPG + Barman-Cloud → R2 backup/restore is **proven end-to-end**.

## Why pin via release-1.29 branch
`release-1.29/releases/cnpg-1.29.1.yaml` is the immutable tagged operator manifest for
that patch. Bumping the patch = bump this URL (stay ≥ 1.29.1, never below).
