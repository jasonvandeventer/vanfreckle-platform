# Talos parallel-cluster bootstrap — `clusters/talos/`

Machine-config + GitOps source for the **new Talos + vanilla-Kubernetes cluster**,
built blue/green alongside the live k3s stack. Authored against
`vanfreckle-platform/talos-parallel-cluster-build-guide-2026-06-05.md` (v3.2) **plus**
its two storage addenda (SATA SSD ADDENDUM 2026-06-13 + UPDATE 2026-06-13b).

> **Status: authored + offline-validated, NOTHING applied.** Branch
> `feature/talos-cluster-bootstrap`. Review before any apply. `cluster.env` is the
> single source of truth; everything else is rendered/derived from it.

## Locked versions (2026-06-13, Option A)
| Component | Pin | Why |
|---|---|---|
| Talos | **v1.13.3** | latest stable 1.13.x |
| Kubernetes | **v1.35.4** | 🛑 PINNED via `--kubernetes-version` — Talos bundles k8s **1.36**, which is ABOVE Longhorn 1.11.2's tested ceiling (1.35). Single most important value. |
| Longhorn | **1.11.2** | tested k8s 1.32–1.35; NOT 1.12.0 |
| CNPG | **1.29.1** | hard floor — CVE-2026-44477 |
| PostgreSQL | **18** | CNPG default operand |
| ArgoCD | **v3.3.6** | matches the old cluster (identical blue/green) |

Install image: `factory.talos.dev/installer/e187c9b…8c96c:v1.13.3` (bakes iscsi-tools +
util-linux-tools + qemu-guest-agent).

## Topology
3 control-plane + 1 worker. **API VIP 10.42.1.64** on the control-plane interfaces only.

| Node | IP | Role | Longhorn disk |
|---|---|---|---|
| cp1 | 10.42.1.60 | control-plane | **none** (lean: bootstrap + VIP holder; one clean quorum node) |
| cp2 | 10.42.1.61 | control-plane | ~80 GB **NVMe-cache-pool vdisk** (virtio) |
| cp3 | 10.42.1.62 | control-plane | **SATA passthrough** 850 EVO (by-id) |
| worker1 | 10.42.1.63 | worker | **SATA passthrough** MX500 (by-id) |

Longhorn **replica-3** across worker1 + cp3 + cp2, disks tagged `ssd`, a `diskSelector:
ssd` StorageClass pinning replicas to exactly those three. Mount `/var/mnt/longhorn`.
`allowSchedulingOnControlPlanes: true` (cp2 + cp3 carry replicas).

## Layout
```
cluster.env                     ← single source of truth (versions, IPs, sizes, by-id TODOs)
image-factory/schematic.yaml    ← Image Factory POST body (the 3 extensions)
talos/
  gen-configs.sh                ← renders + offline-validates per-node configs (--kubernetes-version v1.35.4)
  patches/
    common.yaml                 ← base (install.disk=/dev/vda, hostDNS) — all nodes, at gen time
    cp-schedule.yaml            ← Patch 0: allowSchedulingOnControlPlanes (CP nodes)
    longhorn-volume.yaml        ← Patch A: UserVolumeConfig→/var/mnt/longhorn + ssd disk-tag (worker1/cp3/cp2)
    longhorn-kubelet.yaml       ← Patch B: kubelet extraMount + sysctls (worker1/cp3/cp2)
    vip-patch.template.yaml     ← Patch C: per-node static IP + VIP + NTP (rendered per node)
    disk-cache.README.md        ← Patch D: VM-layer cache='none' (documented; lives in vms/*.xml)
vms/
  define-vms.sh                 ← defines the 4 Unraid VMs (run on VanFreckleServ)
  talos-cp1-lean / cp2-nvme / cp3-sata / worker1-sata .template.xml
nobara/throwaway-postgres.sh    ← local PG18 + read-only role for v4 migration dev
argocd/
  bootstrap/                    ← hand-applied once (argocd v3.3.6 + root app-of-apps)
  apps/                         ← 5 child Applications (manual-sync, NO auto-apply)
manifests/
  namespaces/ longhorn/ cnpg/   ← raw resources the path-based Applications point at
```

## Offline validation (what was run; NOTHING applied to any cluster)
- `talos/gen-configs.sh` → all 4 node configs pass **`talosctl validate --mode metal`**.
- VM XML → **`xmllint` + `virt-xml-validate`** on all 4 rendered domains.
- `kustomize build` clean on bootstrap/ apps/ manifests/**; **CNPG render = 10 CRDs + 1
  controller + RBAC, zero database instances**, image 1.29.1; **`helm template` Longhorn
  1.11.2** renders with our defaultSettings.

## Bring-up order (Saturday — guide is authoritative)
1. Seat RAM, verify 64 GiB, verify last R2 flash backup.
2. Burn-in gate on both SATA SSDs (SMART + badblocks on internal ports) → set
   `WORKER1_SATA_BYID` / `CP3_SATA_BYID` in `cluster.env`.
3. `vms/define-vms.sh` on VanFreckleServ (refuses cp3/worker1 until by-id set).
4. `talos/gen-configs.sh` on Nobara → **back up `talos/rendered/secrets.yaml` +
   talosconfig to Vaultwarden immediately** (git-ignored, irreplaceable).
5. `talosctl apply-config` per node (cp1 first) → `talosctl bootstrap` cp1 ONCE → kubeconfig.
6. Reboot + VIP-failover acceptance test.
7. `kubectl apply -k argocd/bootstrap/` → **restore the reused sealed-secrets key into the
   `sealed-secrets` namespace FIRST** (see `argocd/apps/SEALED-SECRETS-KEY-REUSE.md`) →
   manually sync apps (Longhorn shows **3** storage nodes, NOT 4).
8. **HARD STOP** before Cartarch/Postgres data — Phase 9 reconciles topology with the v4 blueprint.

## Secrets — never in git
`talos/rendered/` (incl. `secrets.yaml`, rendered node configs, talosconfig), any
`kubeconfig`, and `sealed-secrets-key-backup.yaml` are git-ignored. The sealed-secrets
master key is **reused from the old cluster** (Vaultwarden) — do NOT generate a new one.
The new Postgres DSN is net-new content to seal LATER (Phase 9), not now.

## Foot-guns encoded here (don't re-learn them)
- 🛑 `--kubernetes-version v1.35.4` in gen-configs.sh — never inherit Talos's bundled 1.36.
- 🛑 `allowSchedulingOnControlPlanes: true` or storage collapses (cp2/cp3 carry replicas).
- 🛑 UserVolume/kubelet patches on worker1/cp3/cp2 ONLY — cp1 stays storage-free.
- 🛑 `install.disk=/dev/vda` so Talos never installs onto the SATA data disk (worker1/cp3).
- 🛑 CP system disks `cache='none'` (etcd fsync honesty); watch cp2 etcd fsync (it shares its NVMe with a replica).
- 🛑 SATA by-id is a real TODO — the USB bridge reports the wrong id; get it from an internal port.
- 🛑 New ArgoCD on its OWN overlay (clusters/talos/**), never the old k8s/** path.
