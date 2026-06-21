# cartarch v4 cutover — staged in-cluster migration Jobs

One-time manifests for the SQLite→Postgres cutover load (Phase C dry-run + Phase D
live window). **STAGED, manually applied, NOT GitOps-synced** — they live OUTSIDE the
mana-archive ArgoCD app's path (`overlays/homelab`), and there is **deliberately no
`kustomization.yaml`** here so `kubectl apply -k` can't fire all four stages at once.
You apply ONE Job at a time and read its result before the next. The whole point is the
human GO/NO-GO gate at Stage 4 (runbook step 11) — nothing auto-continues.

All run in **`cnpg-system`** (same namespace as the `cartarch-prod` CNPG cluster, so the
`cartarch-prod-app` / `cartarch-prod-superuser` secrets and `cartarch-prod-rw` service
resolve by short name). `restartPolicy: Never`, `backoffLimit: 0` (a failed cutover step
must be inspected, never silently retried).

## ⚠️ Prerequisites (must exist before applying)

1. **Cutover tooling image `ghcr.io/jasonvandeventer/mana-archive:v4.0.0-migrate`** —
   built + pushed from the cartarch repo's `Dockerfile.migrate`. The plain `v4.0.0` app
   image does **not** contain `alembic` (dev-only dep) or `alembic.ini`/`alembic/`, so it
   cannot run Stage 1; the `-migrate` overlay adds alembic + the migration env + the
   Stage-4 gate script (`scripts/validate_cutover.py`). The `-migrate` suffix is a semver
   pre-release, so ArgoCD's image-updater ignores it — it can never auto-deploy.
2. **The `cartarch-prod` CNPG cluster up**, with `enableSuperuserAccess: true` (it is, in
   the drafted cluster CR) → the `cartarch-prod-superuser` secret exists. Stage 2 needs it.
3. **The checkpointed prod SQLite snapshot** verified out-of-pod (integrity_check=ok +
   sha256), ready to `kubectl cp` in.

## Secret per stage (important)

| Stage | Secret | Why |
|------|--------|-----|
| 1 Schema | `cartarch-prod-app` | DB owner can DDL |
| 2 Load | **`cartarch-prod-superuser`** | `session_replication_role=replica` needs superuser |
| 3 Sweep | `cartarch-prod-app` | DML on its own tables |
| 4 Gate | `cartarch-prod-app` | read-only + a rolled-back probe insert |

Every stage **recomposes** the SQLAlchemy URL from the secret's `username`/`password`
parts as `postgresql+psycopg://…@cartarch-prod-rw.cnpg-system:5432/cartarch` — NOT CNPG's
raw `uri` key, which is a plain `postgresql://` (psycopg2 driver, not in the image) and,
for the superuser secret, points at the wrong database. Password is URL-encoded and read
from env (never on the command line).

## Apply sequence

```sh
NS=cnpg-system

# --- snapshot delivery (manual, B2.1) ---
kubectl -n $NS apply -f 00-snapshot-pvc.yaml
kubectl -n $NS apply -f 05-snapshot-helper-pod.yaml
kubectl -n $NS wait --for=condition=Ready pod/cartarch-snapshot-helper --timeout=120s
kubectl -n $NS cp ./mana_archive.db cartarch-snapshot-helper:/snapshot/mana_archive.db
kubectl -n $NS exec cartarch-snapshot-helper -- sh -c \
  'sha256sum /snapshot/mana_archive.db; python -c "import sqlite3;print(sqlite3.connect(\"/snapshot/mana_archive.db\").execute(\"PRAGMA integrity_check\").fetchone())"'
# CONFIRM sha256 matches the out-of-pod hash AND integrity_check == ('ok',), THEN free the RWO volume:
kubectl -n $NS delete pod cartarch-snapshot-helper

# --- STAGE 1: schema ---
kubectl -n $NS apply -f 10-job-1-schema.yaml
kubectl -n $NS wait --for=condition=complete job/cartarch-cutover-1-schema --timeout=300s \
  || kubectl -n $NS wait --for=condition=failed job/cartarch-cutover-1-schema --timeout=1s
kubectl -n $NS logs job/cartarch-cutover-1-schema      # read it before proceeding

# --- STAGE 2: load (+ built-in pre-sweep validation) ---
kubectl -n $NS apply -f 20-job-2-load.yaml
kubectl -n $NS wait --for=condition=complete job/cartarch-cutover-2-load --timeout=600s \
  || kubectl -n $NS wait --for=condition=failed job/cartarch-cutover-2-load --timeout=1s
kubectl -n $NS logs job/cartarch-cutover-2-load        # row-count parity should be EXACT here (pre-sweep)

# --- STAGE 3: sweep (+ zero-orphan re-scan) ---
kubectl -n $NS apply -f 30-job-3-sweep.yaml
kubectl -n $NS wait --for=condition=complete job/cartarch-cutover-3-sweep --timeout=300s \
  || kubectl -n $NS wait --for=condition=failed job/cartarch-cutover-3-sweep --timeout=1s
kubectl -n $NS logs job/cartarch-cutover-3-sweep       # NOTE the per-FK "deleted" counts

# --- STAGE 4: THE GATE (runbook step 11) ---
kubectl -n $NS apply -f 40-job-4-validate-gate.yaml
kubectl -n $NS wait --for=condition=complete job/cartarch-cutover-4-validate-gate --timeout=300s \
  || kubectl -n $NS wait --for=condition=failed job/cartarch-cutover-4-validate-gate --timeout=1s
kubectl -n $NS logs job/cartarch-cutover-4-validate-gate
```

## THE GO/NO-GO GATE (after Stage 4)

Stage 4 is the deliberate halt. Read its log and decide:

- **Job Succeeded (exit 0)** → the five automated checks passed. **Still YOUR call:**
  reconcile the printed `total swept deficit` against Stage 3's `deleted` total (they must
  match), eyeball the per-table parity, then **GO** → proceed to the app cutover (deploy
  v4.0.0 on green + re-route the Cloudflare tunnel + scale blue to 0).
- **Job Failed (exit 1)** → a hard check failed (orphans remain / phantom rows / boolean
  didn't round-trip / sequence collision / cache mismatch). **ABORT → Phase R** (unfreeze:
  point back at the untouched SQLite, scale blue up — zero writes lost during the freeze).

Nothing downstream runs until you decide GO. This directory contains only the load+
validate stages; the irreversible "app now writes to PG" step is the separate app cutover.

## Cleanup (after a GO and successful cutover, or after a dry-run)

```sh
kubectl -n cnpg-system delete -f 40-job-4-validate-gate.yaml -f 30-job-3-sweep.yaml \
  -f 20-job-2-load.yaml -f 10-job-1-schema.yaml -f 05-snapshot-helper-pod.yaml
# keep 00-snapshot-pvc.yaml until the snapshot is confirmed no longer needed, then delete it.
```
