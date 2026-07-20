# CNPG PostgreSQL DR — Restore Runbook

**Last updated:** 2026-07-20 (first authored after the 2026-07-20 measured restore drill)
**Applies to:** CloudNativePG `cartarch-prod` (PostgreSQL 18) on the Talos cluster
**Scope:** recovery of the **application database** from its Cloudflare R2 backup chain.

> This is the **data-layer** DR path. It complements — does not replace —
> `docs/restore-runbook.md` (Longhorn *volume* recovery: ext4 fsck / snapshot revert)
> and `docs/recovery.md` (cluster-level bring-up). The CNPG database is the durable
> production data; those two docs predate the Talos/CNPG cutover and do not cover it.

---

## Backup topology (what we're restoring from)

- **Engine:** CNPG with the **barman-cloud plugin** (`isWALArchiver: true`), `serverName: cartarch-prod`.
- **Destination:** Cloudflare R2, `s3://cartarch-cnpg-backups/cartarch-prod/` (ObjectStore `cnpg-r2-store` in `cnpg-system`).
- **Cadence:** daily base backup at 03:00 UTC (`ScheduledBackup cartarch-prod-daily`, `method: plugin`) **plus continuous WAL archiving**. Retention 90d.
- **Note:** plugin-method backups do **not** appear as CNPG `Backup` CRs. `kubectl get backup -n cnpg-system` returning nothing is EXPECTED — verify in R2, not from the API.

## Step 0 — Verify a restorable backup actually exists (don't trust status)

```bash
rclone lsf r2:cartarch-cnpg-backups/cartarch-prod/base/     # expect dated base backups (…T030000/)
rclone lsf r2:cartarch-cnpg-backups/cartarch-prod/wals/     # expect continuous WAL segments
```

If `base/` has a recent entry and `wals/` is advancing, the chain is restorable. **RPO** is
bounded by the newest archived WAL, not the base-backup age.

---

## A. Non-destructive restore DRILL (safe; prod untouched)

Use this to rehearse + measure. It restores into a **throwaway** single-instance cluster in the
`cartarch-dev` namespace, reusing the existing read-only R2 cred + ObjectStore. **Prod is never touched.**

### THE load-bearing safety rule

The throwaway MUST have **no top-level `plugins:` block** (no `isWALArchiver`). A plugins block with
`serverName: cartarch-prod` would write the throwaway's WAL into prod's R2 path and **corrupt the prod
backup chain** (this is the "Expected empty archive" failure class). `externalClusters` is
recovery-read-only and is safe. Same pattern the `cartarch-dev` cluster uses; CI-guarded by
`ci/check-dev-no-archiving.sh`.

### Procedure

```bash
export KUBECONFIG=/home/jason/lab/vanfreckle-platform/kubeconfig-cartarch-prod
# 1. Apply the throwaway (manifest below). Record the time — this starts the RTO clock.
kubectl apply -f drtest-cluster.yaml

# 2. Poll to healthy (this IS the RTO):
kubectl get cluster cartarch-drtest -n cartarch-dev \
  -o jsonpath='{.status.phase} {.status.readyInstances}/1{"\n"}' -w

# 3. Verify data parity vs prod (read-only on both):
Q="SELECT (SELECT version_num FROM alembic_version) alembic,
          (SELECT count(*) FROM cards) cards,
          (SELECT count(*) FROM inventory_rows) inv,
          (SELECT count(*) FROM users) users,
          (SELECT count(*) FROM transaction_logs) txn,
          (SELECT max(created_at) FROM transaction_logs) latest;"
kubectl exec cartarch-drtest-1 -n cartarch-dev  -c postgres -- psql -U postgres -d cartarch -x -c "$Q"
kubectl exec cartarch-prod-2  -n cnpg-system     -c postgres -- psql -U postgres -d cartarch -x -c "$Q"
# alembic_version + row counts + latest-txn must match.

# 4. TEARDOWN:
kubectl delete cluster cartarch-drtest -n cartarch-dev
kubectl delete pvc -n cartarch-dev -l cnpg.io/cluster=cartarch-drtest
```

The throwaway manifest is the `cartarch-dev` cluster (`clusters/talos/manifests/cnpg-cartarch-dev/cluster.yaml`)
with `metadata.name: cartarch-drtest`, `instances: 1`, the `bootstrap.recovery` + `externalClusters`
blocks kept, and **no `plugins:` block and no `managed.roles`** (verification runs as the local
`postgres` superuser via `kubectl exec`, so no dev app-role secret is needed).

### Measured result — 2026-07-20

| Metric | Result |
|---|---|
| **RTO (data-layer)** | **99 s** — `kubectl apply` → `Cluster in healthy state`, single instance restored from R2 |
| **RPO** | **≈ 0 at drill time** — restore byte-current with prod (identical row counts + identical latest-txn timestamp). Under active writes, bounded by the WAL archive interval (~minutes). |
| **Integrity** | Full parity: `alembic_version = b2c3d4e5f6a7` (head), cards 14,750 / scryfall_cards 116,145 / inventory_rows 10,879 / users 10 / transaction_logs 73,739 — all identical to prod. |
| **Blast radius** | None. Throwaway in `cartarch-dev` ns, read-only R2, deleted after. Prod stayed 3/3, dev stayed 1/1. |

---

## B. REAL disaster restore (data loss on prod)

Only when prod data is actually lost/corrupt. Two shapes:

- **Restore-to-latest:** delete/recreate `cartarch-prod` with a `bootstrap.recovery` from
  `cnpg-r2-store` (serverName `cartarch-prod`). Replays all WAL to the newest archived segment.
- **Point-in-time (PITR):** same, plus `bootstrap.recovery.recoveryTarget.targetTime: "<UTC>"` to
  stop before a bad event (e.g. an accidental mass-delete or bad migration).

Do NOT do this casually — recreating the prod cluster is the real thing. Freeze the app first
(scale the deployment to 0) so nothing writes during recovery, and take a fresh manual base backup
if the primary is still readable.

---

## Still NOT drilled (honest gaps)

- **Total host loss** (rebuild the Talos cluster from scratch, THEN restore). The 99 s above is
  data-layer only; full-stack DR RTO = cluster-rebuild time + ~99 s + app redeploy + tunnel repoint,
  and has not been measured end to end.
- **Clean-reboot self-assembly** on the green/Talos cluster — the k3s-era boot-order / Longhorn race,
  unproven post-Talos.
- Recommend a **quarterly** cadence for Drill A, and scheduling the total-host-loss game-day.
