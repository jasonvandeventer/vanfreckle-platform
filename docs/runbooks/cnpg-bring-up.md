# Runbook — CloudNativePG bring-up (v4 prerequisite)

The durable replacement for SQLite-on-Longhorn. Standing this up — operator +
backup plugin + cluster + R2 backups + an **exercised restore test** — is the
one remaining v4 prerequisite (the protective sequence from the v4-timing ADR;
the rest of the readiness gate is cleared). Everything after this is the v4
build itself (app DB-layer port, the `RUN_WORKERS` daemon split, the cutover).

GitOps-managed, so the steady state is "commit + let ArgoCD sync." The manual
steps below are the bootstrap-only actions GitOps can't do for you (vendoring a
pinned manifest, sealing a credential, the one-time restore drill).

## Backup architecture — why the plugin (read first)

CNPG **removed** the in-tree `.spec.backup.barmanObjectStore` at operator 1.26+
(confirmed: it's absent from the 0.28.2 chart's `Cluster` CRD). The supported
path is now the external **Barman Cloud Plugin**, which requires **cert-manager**
(for operator↔sidecar TLS). We deliberately chose the current operator + plugin
over pinning an old operator on a deprecated API — no rebuild in six months.
That decision adds two platform components (cert-manager, the plugin) but uses
zero deprecated surface.

## What this adds

| File | Purpose | Sync-wave |
|---|---|---|
| `k8s/argocd/apps/cert-manager.yaml` | cert-manager (Helm) — plugin TLS dep | `-2` |
| `k8s/argocd/apps/cloudnative-pg.yaml` | CNPG **operator** (Helm, chart 0.28.2 / op 1.29.1) | `-1` |
| `k8s/argocd/apps/barman-cloud-plugin.yaml` | Barman Cloud **plugin** (vendored manifest) | `0` |
| `k8s/argocd/apps/cartarch-postgres.yaml` | the **cluster** App | `1` |
| `k8s/apps/barman-cloud-plugin/manifest.yaml` | **you vendor this** (curl, step 1) | — |
| `k8s/apps/cartarch-postgres/base/objectstore.yaml` | `ObjectStore` — R2 dest + creds + 30d retention | — |
| `k8s/apps/cartarch-postgres/base/cluster.yaml` | `Cluster` (2 inst, Longhorn, `.spec.plugins` → ObjectStore) | — |
| `k8s/apps/cartarch-postgres/base/scheduled-backup.yaml` | daily backup, `method: plugin` | — |
| `cnpg-backup-r2` SealedSecret | **you seal this** (kubeseal, step 2) | — |

Sync-wave order on a cold bring-up: cert-manager → operator → plugin → cluster.

## Decisions baked in (override before committing if you disagree)

1. **Namespace `cartarch`** (the v4 rename target), not `mana-archive`. The DB is
   new infra with no legacy name; co-locating with the post-rename app means the
   app reads the CNPG-generated `cartarch-pg-app` secret in-namespace (no
   cross-namespace copy). Live app stays in `mana-archive` until cutover.
2. **2 instances** (primary + 1 hot standby). Bump to 3 for quorum sync replication.
3. **PostgreSQL 17** (`17.10-…-standard-bookworm`), **10Gi** data + **5Gi** WAL.
4. **Backups reuse the R2 bucket** `cartarch-backups` under a `/cnpg` prefix.

## Pins applied (all verified 2026-06-01)

- ✅ CNPG operator chart `0.28.2` (operator 1.29.1).
- ✅ Postgres image `17.10-202606010953-standard-bookworm`.
- ✅ R2 endpoint in `objectstore.yaml` (the account S3 endpoint).
- ✅ Plugin release `v0.12.0` (step 1).
- ✅ cert-manager chart `v1.20.2`.

## Step 1 — vendor the plugin manifest (manual, pinned)

```sh
curl -fsSL -o k8s/apps/barman-cloud-plugin/manifest.yaml \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.12.0/manifest.yaml
git add k8s/apps/barman-cloud-plugin/manifest.yaml
```

Check the [releases page](https://github.com/cloudnative-pg/plugin-barman-cloud/releases)
for the current version first. The `barman-cloud-plugin` App applies this.

## Step 2 — seal the R2 credential for the plugin (manual, one-time)

The plugin's `ObjectStore` reads a Secret **in the cluster's namespace**
(`cartarch`) with keys `ACCESS_KEY_ID` / `SECRET_ACCESS_KEY`. SealedSecrets are
sealed per (namespace, name), so the existing `r2-backup-credential`
(`longhorn-system`, Longhorn's key names) can't be reused. Use the **same R2 API
token** (Object R/W on `cartarch-backups`).

```sh
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

Add a header (match `r2-backup-credential.sealedsecret.yaml` style) + a row in
`k8s/secrets/README.md`. The `platform-secrets` App reconciles it. The `cartarch`
namespace must exist first (the cluster App creates it; on a cold start either
let that App create the ns, or `kubectl create ns cartarch` ahead of the secret).

## Step 3 — commit; ArgoCD applies in wave order

`platform-root` (non-recursive over `k8s/argocd/apps/`) creates the four Apps;
sync-waves order them: cert-manager (`-2`) → operator (`-1`) → plugin (`0`) →
cluster (`1`). The cluster App carries a retry backoff for the cold-start window.
Do **not** `kubectl apply` any of this by hand.

## Step 4 — validate

```sh
cmctl check api                                       # cert-manager ready
kubectl -n cnpg-system get deploy                     # cnpg-controller-manager + barman-cloud
kubectl -n cnpg-system rollout status deploy barman-cloud
kubectl get crd objectstores.barmancloud.cnpg.io     # plugin CRD present
kubectl -n cartarch get cluster cartarch-pg           # healthy, 2/2
kubectl cnpg status cartarch-pg -n cartarch           # replication + "Continuous Archiving: OK"
kubectl -n cartarch get secret cartarch-pg-app        # the app DSN secret CNPG generated
```

Trigger a first base backup and confirm it lands in R2:

```sh
kubectl cnpg backup cartarch-pg -n cartarch
kubectl -n cartarch get backup        # phase: completed; verify the object in the R2 bucket /cnpg prefix
```

## Step 5 — exercised restore test (THE gate)

ADR Phase-2 requirement + cutover rehearsal: prove an R2 backup restores before
trusting it. Restore into a **throwaway** cluster in a scratch namespace via the
plugin's recovery path (`bootstrap.recovery` + `externalClusters[].plugin`):

```yaml
# scratch Cluster (apply in ns cnpg-restore-test, after sealing cnpg-backup-r2 there too)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cartarch-pg-restore
  namespace: cnpg-restore-test
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.10-202606010953-standard-bookworm
  storage: { storageClass: longhorn, size: 10Gi }
  bootstrap:
    recovery:
      source: cartarch-origin
  externalClusters:
    - name: cartarch-origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cartarch-pg-store     # a copy of the ObjectStore CR in this ns
          serverName: cartarch-pg                 # the source cluster's server name
```

```sh
kubectl cnpg status cartarch-pg-restore -n cnpg-restore-test
psql "$(kubectl -n cnpg-restore-test get secret cartarch-pg-restore-app -o jsonpath='{.data.uri}' | base64 -d)" -c '\dt'
kubectl delete ns cnpg-restore-test
```

Record the result (object path, restored row counts, integrity) the way the
Longhorn R2 restore was logged in `backup-strategy.md`. **Until this passes, the
gate is not cleared.**

## Hand-off to the v4 app build (Workstream A — NOT part of this runbook)

Once the cluster is healthy and the restore test passes:
- The app sets `DATABASE_URL` from the CNPG-generated `cartarch-pg-app` secret's
  `uri` key (`secretKeyRef`), **not** a hand-sealed secret — CNPG owns the password.
- `db.py` rewrites the scheme `postgresql://` → `postgresql+psycopg://` for SQLAlchemy.
- The rest is the v4 scope doc: `psycopg` dep, baseline schema (`create_all` +
  seed `schema_migrations`), `group_concat`→`string_agg`, the `RUN_WORKERS`
  daemon split, CI Postgres service, then the cutover ETL.

## Notes / gotchas

- **R2 + Barman:** S3-compatible but not S3. If WAL archiving errors on
  checksums/region, the fixes are usually a forced path-style / a dummy
  `AWS_REGION=auto`. The `ObjectStore.spec.configuration` has `endpointCA`,
  `tags`, and `wal/data.additionalCommandArgs` knobs if needed. Shake this out
  during the Step 5 restore test, not at cutover.
- **cert-manager is a hard dependency** of the plugin — if `cmctl check api`
  isn't ready, the plugin's `Certificate`s (and thus the sidecars) won't come up.
  This is why cert-manager is sync-wave `-2`.
- **ArgoCD vs operator-managed children:** CNPG + the plugin create Pods/PVCs/
  Secrets/Services not in Git. ArgoCD won't prune them (it only prunes what it
  created from Git). If it reports persistent OutOfSync on operator-mutated
  fields, add targeted `ignoreDifferences` to the `cartarch-postgres` App.
- **Plugin version bumps** are a one-line re-vendor (step 1) + commit; keep it
  within the operator's supported range.
