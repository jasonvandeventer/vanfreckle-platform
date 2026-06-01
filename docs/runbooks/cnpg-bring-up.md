# Runbook — CloudNativePG bring-up (v4 prerequisite)

The durable replacement for SQLite-on-Longhorn. Standing this up — operator +
cluster + R2 backups + an **exercised restore test** — is the one remaining v4
prerequisite (the protective sequence from the v4-timing ADR; the rest of the
readiness gate is cleared). Everything after this is the v4 build itself
(app DB-layer port, the `RUN_WORKERS` daemon split, the cutover).

GitOps-managed, so the steady state is "commit + let ArgoCD sync." The manual
steps below are the bootstrap-only actions GitOps can't do for you (sealing a
credential, the one-time restore drill).

## What this adds

| File | Purpose |
|---|---|
| `k8s/argocd/apps/cloudnative-pg.yaml` | ArgoCD App — CNPG **operator** (Helm), sync-wave `0`, ns `cnpg-system` |
| `k8s/argocd/apps/cartarch-postgres.yaml` | ArgoCD App — the **cluster**, sync-wave `1`, ns `cartarch` |
| `k8s/apps/cartarch-postgres/base/cluster.yaml` | the `Cluster` CR (2 instances, Longhorn storage, R2 backup) |
| `k8s/apps/cartarch-postgres/base/scheduled-backup.yaml` | daily base backup → R2 |
| `k8s/apps/cartarch-postgres/base/namespace.yaml` | the `cartarch` namespace |
| `cnpg-backup-r2` SealedSecret | **created by you** via kubeseal (step 1) — R2 creds for Barman |

## Decisions baked in (override before committing if you disagree)

1. **Namespace `cartarch`** (the v4 rename target), not `mana-archive`. The DB
   is new infra with no legacy name; co-locating it with the post-rename app
   means the app reads the CNPG-generated `cartarch-pg-app` secret in-namespace
   (no cross-namespace secret copy). The live app stays in `mana-archive` until
   cutover, untouched.
2. **2 instances** (primary + 1 hot standby). Bump to 3 for quorum-based
   synchronous replication if you want stronger HA across node2–4.
3. **PostgreSQL 17**, **10Gi** data + **5Gi** WAL per instance (data is tiny;
   headroom for the rebuilt `scryfall_cards` cache).
4. **Backups reuse the existing R2 bucket** `cartarch-backups` under a `/cnpg`
   prefix (Longhorn backups sit at the bucket root — no collision).

## Prerequisites to VERIFY before committing

- **Operator chart version** — pin `cloudnative-pg.yaml:targetRevision` to
  current stable: `helm repo add cnpg https://cloudnative-pg.github.io/charts &&
  helm search repo cnpg/cloudnative-pg --versions | head`.
- **Postgres image tag** in `cluster.yaml` (`imageName`) against the current
  CNPG-published image.
- **R2 endpoint** — set `cluster.yaml:endpointURL` to the same S3 endpoint the
  Longhorn BackupTarget already uses (the `AWS_ENDPOINTS` value sealed in
  `k8s/secrets/r2-backup-credential.sealedsecret.yaml`).

## Step 1 — seal the R2 credential for CNPG (manual, one-time)

CNPG's Barman integration reads its own Secret in the cluster's namespace.
SealedSecrets are sealed per (namespace, name), so the existing
`r2-backup-credential` (namespace `longhorn-system`, Longhorn's key names)
cannot be reused — create a new one in `cartarch` with the keys CNPG references
(`ACCESS_KEY_ID` / `SECRET_ACCESS_KEY`). Use the **same R2 API token** as the
Longhorn target (Object R/W on `cartarch-backups`).

```sh
# Plaintext never touches Git — piped straight into kubeseal.
kubectl create secret generic cnpg-backup-r2 \
  --namespace cartarch \
  --from-literal=ACCESS_KEY_ID='<R2_ACCESS_KEY_ID>' \
  --from-literal=SECRET_ACCESS_KEY='<R2_SECRET_ACCESS_KEY>' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace sealed-secrets \
> k8s/secrets/cnpg-backup-r2.sealedsecret.yaml
```

Then add a header to the file (matching `r2-backup-credential.sealedsecret.yaml`
style) and a row to `k8s/secrets/README.md`. The `platform-secrets` ArgoCD App
(non-recursive `*.sealedsecret.yaml` over `k8s/secrets/`) reconciles it — no
new wiring. The `cartarch` namespace must exist first; it's created by the
`cartarch-postgres` App, so on a cold start either let that App create the ns,
or `kubectl create ns cartarch` ahead of the secret sync.

## Step 2 — commit; ArgoCD applies in order

`platform-root` is a non-recursive Directory source over `k8s/argocd/apps/`, so
committing the two new Application manifests creates them. Sync-waves order the
apply: operator + CRDs (wave `0`) → cluster (wave `1`). The cluster App carries
a retry backoff for the brief cold-start window before the CRDs register.

Do **not** `kubectl apply` any of this by hand.

## Step 3 — validate the cluster

```sh
kubectl -n cartarch get cluster cartarch-pg          # expect: Cluster in healthy state, 2/2
kubectl -n cartarch get pods -l cnpg.io/cluster=cartarch-pg
kubectl cnpg status cartarch-pg -n cartarch          # the kubectl-cnpg plugin: replication, WAL archiving
kubectl -n cartarch get secret cartarch-pg-app       # the app DSN secret CNPG generated
```

Confirm WAL archiving is working (`Continuous Archiving: OK` in `cnpg status`)
and that a base backup lands in R2 (`kubectl -n cartarch get backup` after the
first ScheduledBackup, or trigger one: `kubectl cnpg backup cartarch-pg -n cartarch`).

## Step 4 — exercised restore test (THE gate)

This is the ADR Phase-2 requirement and the cutover rehearsal: prove a backup in
R2 actually restores before trusting it. Restore into a **throwaway** cluster in
a scratch namespace, from the R2 object store (PITR / `recoveryTarget` left at
latest):

```sh
kubectl create ns cnpg-restore-test
# copy the sealed cred into the scratch ns (reseal for that ns, or kubectl-copy the live Secret)
# then apply a Cluster with bootstrap.recovery.source pointing at an externalCluster
# whose barmanObjectStore = s3://cartarch-backups/cnpg (read-only).
kubectl cnpg status cartarch-pg-restore -n cnpg-restore-test
psql "$(kubectl -n cnpg-restore-test get secret cartarch-pg-restore-app -o jsonpath='{.data.uri}' | base64 -d)" -c '\dt'
# verify table presence + a row count, then tear down:
kubectl delete ns cnpg-restore-test
```

Record the result (object store path, restored row counts, integrity) the same
way the Longhorn R2 restore was logged in `backup-strategy.md`. **Until this
passes, the gate is not cleared.**

## Hand-off to the v4 app build (Workstream A — NOT part of this runbook)

Once the cluster is healthy and the restore test passes:
- The app sets `DATABASE_URL` from the CNPG-generated `cartarch-pg-app` secret's
  `uri` key (`secretKeyRef`), **not** a hand-sealed secret — CNPG owns the
  password.
- `db.py` rewrites the scheme `postgresql://` → `postgresql+psycopg://` for
  SQLAlchemy (one line).
- The rest is the v4 scope doc: `psycopg` dependency, baseline schema
  (`create_all` + seed `schema_migrations`), `group_concat`→`string_agg`, the
  `RUN_WORKERS` daemon split, CI Postgres service, then the cutover ETL.

## Notes / gotchas

- **R2 + Barman:** S3-compatible but not S3. If WAL archiving errors on
  checksums/region, the usual fixes are forcing path-style access and/or setting
  a dummy `AWS_REGION`/region in the barman config. Shake this out during the
  Step 4 restore test, not at cutover.
- **ArgoCD vs operator-managed children:** CNPG creates Pods/PVCs/Secrets/
  Services not present in Git. ArgoCD won't prune them (it only prunes what it
  created from Git), but if it reports persistent OutOfSync on operator-mutated
  fields, add targeted `ignoreDifferences` to the `cartarch-postgres` App.
- **Backup API:** this uses the in-tree `barmanObjectStore` (simplest, fewest
  moving parts). Newer CNPG is migrating to the external Barman Cloud Plugin; if
  the pinned operator version deprecates in-tree, switch to the plugin — the
  R2 credential and bucket layout carry over unchanged.
