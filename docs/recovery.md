# Cluster Recovery Playbook — Talos + CloudNativePG

**Last Updated:** 2026-07-20 (rewritten for the Talos/CNPG cluster; supersedes the 2026-05-16 k3s stub)
**Scope:** recovering the **existing** cluster after an unplanned outage (power loss, host reboot,
node down, network partition). For a **from-scratch** rebuild see `docs/bootstrap.md`; for
**database** restore see `docs/cnpg-dr-restore.md`; for **Longhorn volume** repair see
`docs/restore-runbook.md`.

> Talos has no shell. All node-level operations go through `talosctl` (config at
> `clusters/talos/talos/rendered/talosconfig`, or `~/lab/vanfreckle-platform/talos.env` exports it).
> Cluster-level operations go through `kubectl` (KUBECONFIG=`kubeconfig-cartarch-prod`).

---

## Current cluster (what "healthy" looks like)

- **4 nodes**, all Ready, Kubernetes v1.35.4: `cp1` (.60), `cp2` (.61), `cp3` (.62) control-plane; `worker1` (.63) worker. API VIP **10.42.1.64**.
- **etcd** quorum = the 3 control-plane nodes (tolerates losing **one**).
- **21 ArgoCD Applications**, all `Synced + Healthy` (`root` is the app-of-apps).
- **CNPG `cartarch-prod`** in `cnpg-system`: 3 instances, one primary (`-rw`), two replicas (`-ro`).
- **Longhorn**: 3 storage nodes (worker1/cp3/cp2 — **cp1 is storage-free by design**), volumes `attached`/`healthy`.
- **App**: `cartarch` in `cnpg-system`, NodePort `30080`; cloudflared (Docker on Unraid) → `10.42.1.63:30080` → `cartarch.com`.

---

## Step 0 — Triage (what's actually broken?)

```bash
export KUBECONFIG=/home/jason/lab/vanfreckle-platform/kubeconfig-cartarch-prod
kubectl get nodes -o wide
kubectl get cluster -n cnpg-system                       # CNPG health + primary
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n argocd get applications
kubectl get pods -A | grep -vE 'Running|Completed'       # only the header should remain
```

If the API server itself is unreachable, the problem is below Kubernetes — go to the Talos section.

## Step 1 — After a host reboot / power loss (the common case)

1. **Let Unraid finish its parity check** before judging cluster health — parity I/O competes with Longhorn.
2. **Control plane first.** Talos VMs auto-start; if you're starting them manually, bring up cp1 → cp2 → cp3, then worker1. Quorum needs 2 of 3 CPs.
3. **Give Longhorn 5–10 minutes** for replica rebuilds. Replicas show `Degraded` during rebuild — expected; wait for `Healthy` before acting.
4. `Volume` CR `robustness` can lag actual replica state — check the CR YAML directly if the table view looks wrong.
5. Confirm the API VIP is up: `talosctl -n 10.42.1.60 get addresses | grep 10.42.1.64` (or just that `kubectl` responds).

> ⚠ **Known gap (tracked, platform #35):** whether the cluster reassembles **unattended** after a
> host reboot is **not yet proven on Talos** — the k3s-era VM boot-order / Longhorn-readiness race
> may still exist. Until the clean-reboot drill runs, treat post-reboot bring-up as attended.

## Step 2 — A single node is down

- etcd tolerates **one** CP loss; the cluster keeps serving. Recover the node, don't panic.
- Inspect: `talosctl -n <node-ip> health` / `talosctl -n <node-ip> dmesg`.
- Reboot a node: `talosctl -n <node-ip> reboot`. Reset (reinstall) a node: `talosctl -n <node-ip> reset` then re-`apply-config` (see `docs/bootstrap.md` Step 2).
- If **cp1** (the lean VIP holder) is lost, the VIP floats to another CP automatically (~55 s). cp1 carries no Longhorn replicas, so storage is unaffected.
- If **cp2/cp3/worker1** is lost, a Longhorn replica is lost — the volume goes `Degraded` and rebuilds onto the survivor set when the node returns. Don't delete replicas manually.

## Step 3 — Database problems (CNPG)

- **Primary down / failover:** CNPG promotes a replica automatically (`primaryUpdateStrategy: unsupervised`). Confirm with `kubectl get cluster cartarch-prod -n cnpg-system` (watch the `PRIMARY` column change).
- **Data loss / corruption / bad migration:** this is a **restore**, not a reboot → `docs/cnpg-dr-restore.md` §B (restore-to-latest or point-in-time). Freeze the app first (`kubectl scale deploy cartarch -n cnpg-system --replicas=0`).
- **Verify a restorable backup exists** any time: `rclone lsf r2:cartarch-cnpg-backups/cartarch-prod/base/` and `.../wals/` (plugin backups do **not** show as `Backup` CRs — verify in R2).

## Step 4 — Longhorn volume won't mount / is corrupt

→ `docs/restore-runbook.md` (Mode 1: ext4 `e2fsck`; Mode 2: snapshot revert). That runbook's ArgoCD
`selfHeal`-disable dance still applies — but note the app/namespace is now **`cartarch` in
`cnpg-system`**, not `mana-archive`, and durable app data is in **Postgres**, not the volume
(the app's `/data` is an emptyDir holding only regenerable cache).

## Step 5 — ArgoCD / GitOps stuck

- `argocd-repo-server` init container in `CrashLoopBackOff` with `ln: Already exists` after an unclean shutdown → **delete the pod**; the Deployment recreates it with a clean EmptyDir (upstream bug, not config).
- Apps `OutOfSync` on CNPG operator-managed fields → expected; the prod/dev CNPG Apps carry `RespectIgnoreDifferences=true`. Don't force-sync over it.
- Before re-enabling `selfHeal` during any incident, confirm Git's pinned image matches what's running (`clusters/talos/manifests/cartarch/.argocd-source-cartarch.yaml`) — a stale Git tag will roll the app backwards.

---

## Bootstrap secrets (not in Git — recreate by hand)

Most secrets are SealedSecrets and unseal automatically **once the sealed-secrets master key is
restored**. The master key is **reused from the old cluster** and lives off-host (Vaultwarden) —
restoring it is the linchpin of any rebuild (`docs/bootstrap.md` Step 3.2). Genuinely manual items:

### `grafana-admin-credentials` (only if observability is redeployed)

- **Namespace:** `observability`
- **Symptom if missing:** Grafana pod `CreateContainerConfigError`; rest of the stack unaffected.
- **Recreate:**
  ```bash
  kubectl create secret generic grafana-admin-credentials -n observability \
    --from-literal=admin-user=admin \
    --from-literal=admin-password='<password>'
  ```
  Keys (`admin-user`/`admin-password`) must match `userKey`/`passwordKey` in the values file.

### Cloudflare Tunnel token

On the Unraid `cloudflared` Docker container (not in-cluster). Without it, nothing routes to `cartarch.com`.

---

## Verification checklist

Recovery is complete when all of these pass:

```bash
export KUBECONFIG=/home/jason/lab/vanfreckle-platform/kubeconfig-cartarch-prod
kubectl get nodes                                        # 4 Ready (cp1-3, worker1), v1.35.4
kubectl -n cnpg-system get cluster cartarch-prod         # "Cluster in healthy state", 3/3
kubectl -n longhorn-system get volumes.longhorn.io       # attached/healthy or detached (not faulted)
kubectl -n argocd get applications                       # all Synced + Healthy (21)
kubectl get pvc -A                                       # all Bound
kubectl get pods -A | grep -vE 'Running|Completed'       # only header
curl -s -o /dev/null -w '%{http_code}\n' https://cartarch.com/   # 200 (GET, not HEAD)
```

Then load the app in a browser, log in, and exercise a **write** (create + delete something) — pod
Running ≠ app working, and the write path is what proves the database is truly back.

---

## Still not drilled (honest)

- **Clean-reboot self-assembly** on Talos (Step 1 gap) — platform #35 precursor.
- **Total host loss → full rebuild + restore, end to end, measured** — platform #35.
- The **data-layer** restore *is* drilled and measured (RTO 99 s, RPO ~0, 2026-07-20) — see `docs/cnpg-dr-restore.md`.
