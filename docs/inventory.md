# Mana Archive Platform Inventory 

**Generated:** 2026-05-16
**Last Updated:** 2026-05-19 (ArgoCD repo hygiene fixes — see docs/decisions/argocd-repo-hygiene.md)
**Cluster:** K3s on Rocky Linux VMs (Unraid host)
**Repo:** https://github.com/jasonvandeventer/mana-archive-platform
**Author:** jason

## Purpose

This document is the authoritative snapshot of the platform's current state — every namespace, workload, network path, storage resource, and ArgoCD Application running in the cluster as of the generation date. It is intentionally descriptive, not prescriptive: it captures what exists, not what should exist.

Two companion sections (Drift Summary and Cleanup Backlog) translate observations into Phase 2 work. ADRs and remediation manifests live in separate files.

This document was produced after a Saturday morning power outage that forced a full cluster recovery. The recovery surfaced operational state that was not previously documented; this inventory captures that state.

## Cluster Topology

| Property | Value |
|----------|-------|
| Distribution | K3s |
| Version | v1.34.6+k3s1 |
| Nodes | 4 (node1: control-plane+worker, node2/3/4: worker) |
| Node IPs | 10.42.1.50, 10.42.1.51, 10.42.1.52, 10.42.1.53 |
| Host platform | Unraid (Rocky Linux VMs) |
| Cluster age | 37 days (created ~2026-04-09) |

## Namespaces

| Namespace | Age | Origin | Purpose |
|-----------|-----|--------|---------|
| argocd | 35d | platform | GitOps controller |
| default | 37d | k3s default | Holds validation artifacts pending cleanup |
| kube-node-lease | 37d | k3s default | Node heartbeat leases |
| kube-public | 37d | k3s default | Publicly-readable cluster info |
| kube-system | 37d | k3s default | Core k3s components |
| longhorn-system | 26d | platform | Storage layer |
| mana-archive | 35d | workload | Mana Archive application |
| observability | 34d | platform (incomplete GitOps) | kube-prometheus-stack — installed manually, not under ArgoCD |

## Workloads by Namespace

### argocd (35d)

Standard ArgoCD install plus Image Updater. Not currently managed by ArgoCD (bootstrap-tier).

- **Deployments:** argocd-applicationset-controller, argocd-dex-server, argocd-image-updater-controller (24d, ~11d after initial ArgoCD install), argocd-notifications-controller, argocd-redis, argocd-repo-server, argocd-server
- **StatefulSets:** argocd-application-controller
- **Version:** ArgoCD v3.3.6 (upgrade to 3.3.10 pending — fixes platform-root cosmetic health rollup bug)

### default (37d)

Holds historical test artifacts. No production workloads.

- **Services:** kubernetes (default API), hello-world (orphaned, no backing pod)
- **Ingresses:** hello-ingress → hello.local (orphaned)
- **PVCs:** lh-restore-pvc (Terminating, stuck), test-volume-2 (Bound)
- **PVs:** lh-restore-pv (Terminating, stuck), test-volume-2-pv (Bound)
- **Pods:** None currently. Earlier today: lh-writer (Completed, deleted during audit)

### kube-system (37d)

k3s-bundled components. Managed by k3s install, not user-managed.

- **Deployments:** coredns, local-path-provisioner, metrics-server, traefik
- **DaemonSets:** svclb-traefik-be293049 (per-node Traefik service LB)
- **Jobs:** helm-install-traefik, helm-install-traefik-crd (one-shot bootstrap jobs, Completed, retained by k3s)
- **Headless Services (created by kube-prometheus-stack for scraping):** monitoring-kube-prometheus-{coredns, kube-controller-manager, kube-etcd, kube-proxy, kube-scheduler, kubelet}

### longhorn-system (26d)

Storage layer. Full Longhorn Helm install. Managed by ArgoCD Application `longhorn`.

- **Deployments:** csi-attacher (3/3), csi-provisioner (3/3), csi-resizer (3/3), csi-snapshotter (3/3), longhorn-driver-deployer, longhorn-ui (2/2)
- **DaemonSets:** engine-image-ei-75a03ec3 (3/3), longhorn-csi-plugin (3/3), longhorn-manager (3/3)
- **CronJobs:** backup-6h (cron `0 0/6 * * *`), snapshot-1h (cron `0 * * * *`)
- **Recurring Jobs:** Verified firing on schedule during 2026-05-16 outage recovery

### mana-archive (25d)

Production workload. Managed by ArgoCD Application `mana-archive` via Kustomize (`k8s/apps/mana-archive/base` + `overlays/homelab`).

- **Deployments:** mana-archive (1/1)
- **Services:** mana-archive (ClusterIP :80)
- **Ingresses:** mana-archive → mana.vanfreckle.com
- **PVCs:** mana-archive-data-longhorn (5Gi, Longhorn-backed, healthy)
- **Migration Jobs (defined but not actively running):** migrate-v3.yaml, migrate-v3-4.yaml

### observability (34d) — UNMANAGED

**Full kube-prometheus-stack Helm chart, installed manually 34 days ago. Not under ArgoCD. Repo contains `k8s/observability/namespace.yaml` and an empty `k8s/observability/prometheus-stack/` directory, indicating GitOps wiring was intended but never completed.**

- **Deployments:** monitoring-grafana, monitoring-kube-prometheus-operator, monitoring-kube-state-metrics
- **StatefulSets:** alertmanager-monitoring-kube-prometheus-alertmanager, prometheus-monitoring-kube-prometheus-prometheus
- **DaemonSets:** monitoring-prometheus-node-exporter (4/4 across all nodes)
- **Services:** alertmanager-operated, monitoring-grafana, monitoring-kube-prometheus-alertmanager, monitoring-kube-prometheus-operator, monitoring-kube-prometheus-prometheus, monitoring-kube-state-metrics, monitoring-prometheus-node-exporter, prometheus-operated

The stack is configured with control-plane monitoring enabled (scrapes coredns, controller-manager, etcd, kube-proxy, scheduler, kubelet). Whether Grafana has dashboards loaded, what ServiceMonitors exist, and what alerts are configured is unknown and is a Phase 2 investigation item.

## Networking

### External access path

All external traffic enters via **Cloudflare Tunnel → Traefik LoadBalancer (10.42.1.50–53:80) → Ingress → Service**. TLS terminates at Cloudflare; tunnel-to-origin is plaintext HTTP. Cloudflare Tunnel configuration lives on the Unraid host (not in this repo).

Nginx Proxy Manager is also in use for some services per `current-status.md`, but no in-cluster resources reference it; presumably an external-to-cluster traffic path.

### Public hostnames

| Hostname | Namespace | Service | Status |
|----------|-----------|---------|--------|
| mana.vanfreckle.com | mana-archive | mana-archive | Production |
| hello.local | default | hello-world | Dead — no backing pod, 37d old |

### Service inventory

- **argocd:** 8 ClusterIP services (server, repo-server, redis, dex, applicationset-controller, plus metrics endpoints)
- **default:** kubernetes (API), hello-world (orphaned)
- **kube-system:** kube-dns, metrics-server, traefik (LoadBalancer), plus 6 headless services for kube-prometheus-stack control plane scraping
- **longhorn-system:** longhorn-admission-webhook, longhorn-backend, longhorn-frontend (UI), longhorn-recovery-backend
- **mana-archive:** mana-archive
- **observability:** 8 services (see workload section above)

## Storage

### StorageClasses

| Name | Provisioner | Default | Reclaim Policy | Volume Binding | Notes |
|------|-------------|---------|----------------|----------------|-------|
| local-path | rancher.io/local-path | No | Delete | WaitForFirstConsumer | k3s-bundled; default-class annotation removed via `kubectl patch` on 2026-05-16 (needs Git reconciliation) |
| longhorn | driver.longhorn.io | Yes | Delete | Immediate | Production storage class |
| longhorn-static | driver.longhorn.io | No | Delete | Immediate | Origin unclear — likely manually created during backup validation work, used by `lh-restore-pv` and `test-volume-2-pv` |

### PersistentVolumes

| Name | Size | Status | Claim | Class | Notes |
|------|------|--------|-------|-------|-------|
| pvc-bf96b41e-... | 5Gi | Bound | mana-archive/mana-archive-data-longhorn | longhorn | Production data volume, 3 replicas, healthy |
| lh-restore-pv | 2Gi | Terminating | default/lh-restore-pvc | longhorn | Statically provisioned, validation leftover, stuck Terminating |
| test-volume-2-pv | 2Gi | Bound | default/test-volume-2 | longhorn | Statically provisioned, validation leftover |

### PersistentVolumeClaims

| Namespace | Name | Status | Size | Notes |
|-----------|------|--------|------|-------|
| mana-archive | mana-archive-data-longhorn | Bound | 5Gi | Production |
| default | lh-restore-pvc | Terminating | 2Gi | Validation leftover, stuck |
| default | test-volume-2 | Bound | 2Gi | Validation leftover |

### Backup configuration

- **Target:** NFS at `nfs://10.42.1.10:/mnt/user/backups/longhorn` (same Unraid host as cluster — single point of failure, off-host backups planned)
- **Schedule:** Backups every 6 hours, snapshots hourly
- **Validation:** End-to-end backup and restore was validated ~25 days ago using a now-removed harness (`lh-writer` pod writing data, `lh-restore-1` volume restored from backup, contents verified). Some validation artifacts (`test-volume-2`, `lh-restore-pv`) remain in `default` and are pending cleanup.

## ArgoCD Applications

Four Applications exist in the cluster. All defined in `k8s/argocd/`.

| Application | Source path | Sync Status | Health | Notes |
|-------------|-------------|-------------|--------|-------|
| platform-root | `k8s/argocd/root-app.yaml` | Synced | Progressing | App-of-apps; cosmetic Progressing wedge from known ArgoCD 3.3.6 health rollup bug, resolved by upgrade to 3.3.10 |
| longhorn | `k8s/argocd/apps/longhorn.yaml` | Synced | Healthy | Manages Longhorn install |
| mana-archive | `k8s/argocd/apps/mana-archive.yaml` | Synced | Healthy | Manages Mana Archive workload via Kustomize |
| platform | `k8s/argocd/apps/platform.yaml` | Synced | Healthy | Manages `k8s/platform/` — currently the `local-path` StorageClass override |


`k8s/argocd/image-updaters/mana-archive.yaml` exists and is presumably an Image Updater configuration for the mana-archive Application, but the Image Updater controller itself is not managed by any Application — see Drift Summary.

## GitOps Drift Summary

Components running in the cluster that ArgoCD does not manage. These are the audit's primary findings, ordered by risk.

### High risk

**kube-prometheus-stack (34d)** — The entire observability stack (Grafana, Prometheus, Alertmanager, kube-state-metrics, node-exporter, plus all associated CRDs and scrape configurations) is unmanaged. If deleted or corrupted, nothing in Git would restore it. Configuration drift since install (34 days) is unknown. Most significant single piece of unmanaged state in the cluster.

### Medium risk

**ArgoCD itself (35d)** — Installed manually, version v3.3.6. Method of install (kubectl apply, helm install, or other) is not documented. Customizations to the install are not documented. If ArgoCD dies, recovery requires reconstructing the install from memory. The `bootstrap.md` document referenced by `CLAUDE.md` does not yet exist and would close this gap.

### Low risk

**ArgoCD Image Updater (24d)** — Installed manually. Repo contains `helm/image-updater-values.yaml` (presumably the values used to install) but no ArgoCD Application manages the controller. Image Updater is functioning normally; risk is bootstrap-tier, not operational.

**local-path StorageClass annotation patch — RESOLVED 2026-05-19.** During the 2026-05-16 audit, two StorageClasses (`local-path` and `longhorn`) were both annotated as default. The `local-path` annotation was removed via `kubectl patch`, then reconciled into Git via the `platform` Application (`k8s/platform/storage/local-path-storageclass.yaml`). ArgoCD selfHeal now maintains the correct annotation. See docs/decisions/local-path-default-class-fix.md.

### Out-of-bounds symlinks in repo root — RESOLVED 2026-05-19

Six AI-context Markdown files were symlinked into the repo root pointing to `~/lab/ai-context/`. ArgoCD repo-server rejects out-of-bounds symlinks and failed manifest generation for the whole repo, breaking all Applications. Files removed from the repo and added to `.gitignore`. See docs/decisions/argocd-repo-hygiene.md.

### Validation manifests in repo that should not be reapplied

The `longhorn/validation/` directory in the repo contains:
- `lh-reader-pod.yaml`
- `lh-writer-pod.yaml`
- `lh-test-pvc.yaml`
- `lh-restore-pvc.yaml`
- `lh-restore-pv.yaml`
- `mana-archive-storage-migration.yaml`

These were applied manually during one-off backup validation work and were never deleted from the cluster afterward (leading to today's stuck Terminating PVC chain). The manifests should remain in the repo for reference but should not be reapplied. Worth a README in the directory documenting their one-shot nature.

## Manual cluster changes during 2026-05-16 audit

The following changes were made directly to cluster state and are not yet reflected in Git:

| Change | Time | Reason | Reconciliation needed |
|--------|------|--------|----------------------|
| Removed `is-default-class: true` annotation from `local-path` StorageClass | ~14:00 CDT | Both `local-path` and `longhorn` were marked default; correctness fix | Add manifest to Git that enforces `local-path` as non-default OR disable bundled local-path in k3s config |
| Deleted `lh-writer` pod, `lh-test-pvc`, and `lh-restore-1` volume from `default` namespace | ~13:00 CDT | Validation leftovers stuck in Terminating after outage | None — these were one-shot artifacts that should have been deleted long ago |
| Deleted `longhorn-uninstall` failed Job | ~12:00 CDT | Job fired as Helm pre-delete hook during chaotic outage recovery, blocked by Longhorn safety flag; no longer needed | None |
| Deleted and recreated `argocd-repo-server` pod | 2026-05-16 ~19:00 CDT | Init container stuck in CrashLoopBackOff (`ln: Already exists`) due to symlink surviving across pod restarts in EmptyDir | None — fresh pod ran cleanly |
| Removed stale finalizers from `longhorn` ArgoCD Application | 2026-05-19 | Application stuck with a build-day `deletionTimestamp` and stale `pre-delete` finalizers; showed `Deleting` badge and poisoned `platform-root` health rollup | None — `platform-root` recreated the Application cleanly from Git; documented in docs/decisions/argocd-repo-hygiene.md |

## Cleanup Backlog (Phase 2)

Resources in the cluster that should be removed or reconciled, in addition to the drift items above.

| Resource | Namespace | Status | Suggested action |
|----------|-----------|--------|------------------|
| Service hello-world | default | 37d, no backing pod | Delete via Git (if Git-managed) or directly |
| Ingress hello-ingress | default | 37d, points at hello-world | Delete |
| PVC test-volume-2 | default | 26d, validation leftover | Delete |
| PV test-volume-2-pv | default | 26d, statically provisioned, validation leftover | Delete after PVC |
| PVC lh-restore-pvc | default | 26d, Terminating but stuck | Investigate stuck finalizer (likely same pod-reference pattern as lh-test-pvc earlier today) |
| PV lh-restore-pv | default | 26d, Terminating but stuck | Resolves after PVC finalizes |

## Outage Incident Summary (2026-05-16)

Unraid host lost power overnight during a storm. On reboot, parity check began automatically. K3s VMs auto-started after the array came online.

**Observed during recovery:**

1. All four nodes returned to Ready within a few minutes of startup.
2. Longhorn CSI components CrashLoopBackOff'd briefly while waiting for instance-managers — self-resolved within ~5 minutes.
3. Longhorn `pvc-bf96b41e` (mana-archive) showed `degraded` robustness for several minutes while replicas re-attached on all 3 worker nodes — self-resolved to `healthy`.
4. Volume CR status field lagged replica state by ~1 minute after replicas were running; the YAML was authoritative before the table view caught up.
5. `argocd-repo-server` init container stuck in CrashLoopBackOff for ~9 hours due to symlink already existing in EmptyDir. Pod delete resolved it cleanly. Upstream ArgoCD bug — init script uses `ln -s` instead of `ln -sf`.
6. `longhorn-uninstall` Job appeared as Failed, having fired as a Helm pre-delete hook during the chaotic restart. The Longhorn safety flag (`deleting-confirmation-flag: false`) blocked any data deletion. The Job was a false alarm but worth knowing the hook exists.
7. `lh-test-pvc` in `default` namespace stuck in Terminating due to `pvc-protection` finalizer being held by a 25-day-old `lh-writer` pod in Completed state. Deleting the Completed pod released the finalizer; cleanup chain completed normally.

**Lessons captured for `docs/recovery.md` (future work):**

- Volume robustness lag is normal; check YAML rather than table view when verifying recovery
- Stuck Terminating PVCs need pod-reference check before finalizer patching — even Completed pods hold protection finalizers
- The longhorn-uninstall Helm hook can fire on restart; safety flag is the backstop, but worth knowing the trigger
- ArgoCD repo-server's init container has a non-idempotent symlink step that can break on recovery; pod delete resolves

**Data loss:** None. The 5 GiB mana-archive volume came back with all replicas, fully healthy.

## Open Questions for Phase 2

Items identified during the audit that require deliberate work to resolve. Not blocking; not in this document's scope to fix.

1. **What's actually configured in the observability stack?** Are there ServiceMonitors? PrometheusRules? Loaded Grafana dashboards? Is anything from `mana-archive` being scraped? Until this is known, the unmanaged kube-prometheus-stack can't be safely brought under GitOps.
2. **What's in `helm/image-updater-values.yaml`?** Does it match how Image Updater is actually configured in the cluster? When we wrap Image Updater in an ArgoCD Application, the answer determines whether we need to capture drift first.
3. **How was ArgoCD installed?** Recovering this is the first step toward writing `bootstrap.md`. Likely candidates: the official `install.yaml` manifest, the argo-cd Helm chart, or a custom kustomization.
4. **What's the `longhorn-static` StorageClass for, and is it still needed?** It was used by `test-volume-2-pv` and `lh-restore-pv`, both validation artifacts. If nothing else uses it, it can be removed alongside those.
5. **How is Cloudflare Tunnel configured?** The config is on the Unraid host. Documenting it (without exposing secrets) belongs in `bootstrap.md`.
6. **Are there other CronJobs or recurring Longhorn jobs not yet documented?** This inventory captures the two we saw (`backup-6h`, `snapshot-1h`); a check of `RecurringJob` CRD instances would confirm.

## Related Documents

- `CLAUDE.md` — Platform context and rules (authoritative on stack and posture)
- `ROADMAP.md` — Forward-looking phase plan
- `current-status.md` — High-level status; **this inventory supersedes it** where they conflict (notably the observability section, which describes the stack as "not yet built" when it has been running 34+ days)
- `README.md` — Repo overview
- `docs/bootstrap.md` — **Does not yet exist.** Should document how the platform was originally built, including ArgoCD install method and any out-of-band k3s configuration.
- `docs/recovery.md` — **Does not yet exist.** Should capture the post-outage playbook from today's incident.
- `docs/decisions/` — ADRs for individual decisions. Existing: `whoami-resolution.md`. To add: ADR for `local-path` default-class fix once reconciled into Git.
