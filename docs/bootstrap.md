# Platform Bootstrap — Talos + CloudNativePG (from scratch)

**Last Updated:** 2026-07-20 (rewritten for the Talos/CNPG cluster; supersedes the k3s/Rocky draft)
**Status:** Reflects the cluster as built (blue/green cutover 2026-06-22).

This is the **from-scratch** rebuild procedure. For recovering an *existing* cluster after a
partial outage, see `docs/recovery.md`. For restoring the database specifically, see
`docs/cnpg-dr-restore.md`. The three overlap on bootstrap-tier secrets.

> **Authoritative source of truth:** `clusters/talos/README.md` + `clusters/talos/cluster.env`.
> `cluster.env` holds the live versions, node IPs, disk by-ids, and sizes; **everything else is
> rendered from it.** This doc is the narrative walkthrough — when a specific value is needed,
> read it from `cluster.env`/the manifests, not from here (values drift; that file does not).

---

## What you are rebuilding

- **Talos Linux** (immutable, API-managed; no SSH, no package manager — you configure it declaratively with `talosctl`).
- **Upstream Kubernetes**, pinned (see version table below).
- **CloudNativePG** PostgreSQL 18 as the app database, backed up to Cloudflare R2.
- **Longhorn** distributed block storage on passed-through SSDs.
- **ArgoCD** app-of-apps reconciling everything from this repo.
- The **Cartarch** app, served through a Cloudflare Tunnel.

### Locked versions (from `clusters/talos/README.md`; confirm against `cluster.env`)

| Component | Pin | Why |
|---|---|---|
| Talos | v1.13.3 | latest stable 1.13.x |
| Kubernetes | **v1.35.4** | 🛑 pinned via `--kubernetes-version`; Talos bundles 1.36, **above** Longhorn 1.11.2's tested ceiling |
| Longhorn | 1.11.2 | tested to k8s 1.35 |
| CNPG | ≥1.29.1 | hard floor — CVE-2026-44477 |
| PostgreSQL | 18 | CNPG default operand |
| ArgoCD | v3.3.6 | |

Install image (bakes iscsi-tools + util-linux-tools + qemu-guest-agent):
`factory.talos.dev/installer/<schematic>:v1.13.3` — schematic in `clusters/talos/image-factory/schematic.yaml`.

### Topology

3 control-plane + 1 worker, VMs on the Unraid host (`VanFreckleServ`). **API VIP `10.42.1.64`** on the control-plane interfaces only.

| Node | IP | Role | Longhorn disk |
|---|---|---|---|
| cp1 | 10.42.1.60 | control-plane | none (lean quorum + VIP holder) |
| cp2 | 10.42.1.61 | control-plane | 50 GB NVMe-cache vdisk |
| cp3 | 10.42.1.62 | control-plane | SATA passthrough (850 EVO, by-id) |
| worker1 | 10.42.1.63 | worker | SATA passthrough (MX500, by-id) |

Longhorn is **replica-3** across worker1 + cp3 + cp2 (disks tagged `ssd`, a `diskSelector: ssd`
StorageClass), mounted at `/var/mnt/longhorn`. `allowSchedulingOnControlPlanes: true` (cp2/cp3
carry replicas). **cp1 stays storage-free.**

---

## Prerequisites

- Unraid host with capacity for 4 VMs (read `vms/*.template.xml` for exact per-node vCPU/RAM — trimmed after the 2026-06-19 host-OOM incident; cp nodes lean, worker1 largest).
- `talosctl`, `kubectl`, `helm`, `kustomize`, `argocd` on the operator workstation (Nobara).
- **Recoverable off-host secrets** (Vaultwarden + off-host copies): the **sealed-secrets master key**, `talosconfig` + `talos/rendered/secrets.yaml`, R2 credentials, Cloudflare Tunnel token. A from-scratch rebuild is only possible if these survived the loss — verify before you need them.
- Cloudflare account (DNS + Zero Trust Tunnel) for `vanfreckle.com`.

## Step 1 — Burn-in + define the VMs

1. Seat/verify host RAM; verify the last R2 flash backup exists.
2. **Burn-in gate** on both SATA SSDs (SMART + `badblocks` on internal ports), then set `WORKER1_SATA_BYID` / `CP3_SATA_BYID` in `cluster.env`. *(The USB bridge reports the wrong id — get it from an internal port.)*
3. `clusters/talos/vms/define-vms.sh` on VanFreckleServ (refuses cp3/worker1 until the by-ids are set).

## Step 2 — Render + apply Talos machine configs

1. `clusters/talos/talos/gen-configs.sh` on Nobara → renders per-node configs and offline-validates them (`talosctl validate --mode metal`). It passes `--kubernetes-version v1.35.4` — **never inherit Talos's bundled 1.36.**
2. 🔐 **Immediately back up `talos/rendered/secrets.yaml` + `talosconfig` to Vaultwarden** — git-ignored and irreplaceable; losing them means you cannot administer the cluster.
3. `talosctl apply-config` per node (**cp1 first**).
4. `talosctl bootstrap` against **cp1 ONCE** (never more than one node, never twice) → fetch kubeconfig.
5. Reboot + **VIP-failover acceptance test** (hard-stop a CP, confirm the VIP floats — historically ~55 s, bounded by etcd election).

## Step 3 — Bootstrap GitOps

1. `kubectl apply -k clusters/talos/argocd/bootstrap/` (ArgoCD v3.3.6 + the `root` app-of-apps). **ArgoCD is not managed by ArgoCD** — this step is manual on every rebuild.
2. 🔐 **Restore the reused sealed-secrets master key into the `sealed-secrets` namespace FIRST** (see `clusters/talos/argocd/apps/SEALED-SECRETS-KEY-REUSE.md`) — do NOT generate a new key, or every existing SealedSecret in Git becomes undecryptable.
3. Manually sync the child Applications. The full set (21, all should end `Synced + Healthy`): `root`, `namespaces`, `longhorn`(+`-config`), `cnpg-crds`, `cnpg-operator`, `cnpg-barman-plugin`, `cnpg-backup-config`, `cert-manager`(+`-crds`), `sealed-secrets`, `image-updater(s)`, `tailscale`(+`-operator`), `mcp`, `discord-intake`, then `cnpg-cartarch-prod`/`-dev` and `cartarch`/`-dev`.
   - Longhorn must show **3** storage nodes, not 4 (cp1 is storage-free).

## Step 4 — Database (CNPG) + restore data

1. The CNPG operator + Barman plugin + ObjectStore (`cnpg-r2-store` → `s3://cartarch-cnpg-backups/`) come up via their Applications.
2. Bring up `cartarch-prod` (namespace **`cnpg-system`**, 3 instances, PG18, `longhorn-ssd`, WAL archiving + daily ScheduledBackup). On a rebuild you **restore from R2** rather than initdb — follow `docs/cnpg-dr-restore.md` §B (restore-to-latest or PITR).
3. The app connects to `cartarch-prod-rw.cnpg-system.svc.cluster.local:5432` via `DATABASE_URL` (psycopg v3).

## Step 5 — App + ingress

1. The `cartarch` app runs in **`cnpg-system`** (single replica, strategy Recreate, `/data` emptyDir — durable state is in Postgres). Image tag is pinned in `clusters/talos/manifests/cartarch/.argocd-source-cartarch.yaml` (Image Updater writes it back on new `v*.*.*` releases).
2. Entry is a **NodePort `30080`** (`svc/cartarch` in `cnpg-system`), not an ingress controller.
3. **Cloudflared runs as a Docker container on Unraid** (not in-cluster) and targets `http://10.42.1.63:30080` (worker1 NodePort). Restore the tunnel token and confirm `cartarch.com` routes.

## Step 6 — Bootstrap-tier secrets (not in Git)

Most secrets are SealedSecrets (recoverable from Git **once the master key is restored** in Step 3.2). Genuinely out-of-Git items to recreate by hand:

- **sealed-secrets master key** — the linchpin (Step 3.2).
- **Cloudflare Tunnel token** — on the Unraid cloudflared container.
- **`grafana-admin-credentials`** (namespace `observability`, if the observability stack is redeployed) — see `docs/recovery.md` for the exact `kubectl create secret` command.
- The **R2 credentials** and app secrets ship as SealedSecrets and unseal automatically after the master key is in place.

## Step 7 — Verify

Run the checklist in `docs/recovery.md` (§ Verification). Success = 4 nodes Ready, all ArgoCD Applications `Synced + Healthy`, CNPG `cartarch-prod` 3/3 healthy, Longhorn volumes healthy, and `cartarch.com` serving read **and** write.

---

## Foot-guns (encoded in `clusters/talos/README.md` — do not re-learn them)

- 🛑 `--kubernetes-version v1.35.4` — never inherit Talos's bundled 1.36 (breaks Longhorn).
- 🛑 `allowSchedulingOnControlPlanes: true` — or storage collapses (cp2/cp3 carry replicas).
- 🛑 UserVolume/kubelet patches on worker1/cp3/cp2 **only** — cp1 stays storage-free.
- 🛑 `install.disk=/dev/vda` — so Talos never installs onto the SATA data disk.
- 🛑 CP system disks `cache='none'` (etcd fsync honesty); watch cp2 etcd fsync (shares its NVMe with a replica).
- 🛑 New ArgoCD lives on the `clusters/talos/**` overlay — never the old `k8s/**` path.
- 🛑 Size VMs against **host-backable** memory, not in-VM scheduling headroom (the 2026-06-19 host-OOM lesson — see `cartarch/incident-host-oom-cluster-bringup-2026-06-19.md`).

## Known gaps

- The **from-scratch rebuild has not been drilled end to end** (tracked: platform issue #35, DR game-day). Treat this doc as best-known until that drill validates it.
- Steps here reference `cluster.env` / `clusters/talos/README.md` for exact values deliberately — keep those current; this doc narrates, they specify.
