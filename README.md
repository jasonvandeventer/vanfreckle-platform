# vanfreckle-platform

The **GitOps source of truth** for the platform that runs [Cartarch](https://github.com/jasonvandeventer/cartarch) — a self-hosted Magic: The Gathering collection manager with paying users in sight. Every Kubernetes resource is declared here and reconciled by ArgoCD.

> Formerly `mana-archive-platform`. Renamed to `vanfreckle-platform` (deliberately generic — the cluster already hosts more than one workload). The app it runs is **Cartarch** (formerly "Mana Archive"); some in-cluster identifiers (`mana-archive` namespace, ArgoCD Application, image path) still carry the old name pending the app-side infrastructure rename near public launch.

---

## Purpose

The platform layer of the system, kept separate from application code:

- Kubernetes manifests (Kustomize)
- ArgoCD Application definitions (app-of-apps)
- Observability stack (kube-prometheus-stack)
- Storage configuration (Longhorn) + scheduled snapshot/backup jobs
- Secrets (Sealed Secrets) and release automation (Argo CD Image Updater)
- MCP servers exposing the app and the docs vault to AI tooling

**App repo:** https://github.com/jasonvandeventer/cartarch (the in-cluster image path, ArgoCD Application, and namespace are still `mana-archive` — separate rename items, coordinated near launch)
**Docs/AI-context vault:** https://github.com/jasonvandeventer/cartarch-ai-context

---

## Architecture

> **Blue/green transition (as of 2026-06-20):** the live production cluster is the original **K3s** stack ("blue"). A new **Talos + vanilla-Kubernetes** cluster ("green", under `clusters/talos/`) has been built (Phases 3–9) and is the cutover target for the **v4 PostgreSQL migration** — its data tier is CNPG (PostgreSQL 18) with Barman-Cloud → Cloudflare R2 backup/restore proven end-to-end. The bullets below describe the live blue cluster; green's pins, topology, and status are in `clusters/talos/README.md`. Host RAM is oversubscribed only while both clusters run; this resolves when blue is decommissioned post-cutover.

- **K3s** v1.34.6 — four Rocky Linux 9.7 VMs on a single Unraid host (the named single-host SPOF; **blue / current prod**)
- **Argo CD** — GitOps controller; `selfHeal` + `prune` on every Application
- **Longhorn** — distributed block storage (default StorageClass) + NFS backup target
- **kube-prometheus-stack** — Prometheus / Grafana / Alertmanager
- **Sealed Secrets** — encrypted-secret-as-Git-artifact (bitnami-labs controller)
- **Cloudflare Tunnel → Traefik** — external entry for public hostnames

---

## GitOps model — app-of-apps

`platform-root` (`k8s/argocd/root-app.yaml`) reconciles `k8s/argocd/apps/`, which defines every child Application:

```
platform-root
├── platform          # cluster-scoped resources (local-path StorageClass override)
├── longhorn          # storage
├── mana-archive      # the Cartarch app (Deployment, Ingress, PVC)
├── observability     # kube-prometheus-stack (multi-source Helm + repo values)
├── recurring-jobs    # Longhorn snapshot-1h / backup-6h RecurringJobs
├── sealed-secrets    # SealedSecret controller
├── image-updater     # Argo CD Image Updater
├── cartarch-mcp      # MCP: read-only app/DB/log introspection
└── obsidian-mcp      # MCP: docs-vault access
```

> Git is the source of truth. ArgoCD continuously reconciles cluster state to match this repo — manual `kubectl` edits are reverted.

---

## Repository structure

```
k8s/
├── argocd/
│   ├── root-app.yaml              # the app-of-apps root
│   ├── apps/                      # one Application manifest per child
│   ├── image-updater/            # Image Updater Helm values
│   └── sealed-image-updater-git-creds.yaml
├── apps/
│   ├── mana-archive/             # the Cartarch app (base + homelab overlay)
│   ├── cartarch-mcp/ obsidian-mcp/
│   └── recurring-jobs/
├── observability/                # kube-prometheus-stack values + namespace
└── platform/                     # cluster-scoped platform resources
clusters/
└── talos/                        # green cluster: Talos machine-config + its own ArgoCD
                                  #   overlay (Longhorn, cert-manager, CNPG + Barman→R2)
docs/                             # runbooks, ADRs (docs/decisions/), recovery
```

> The `k8s/` tree reconciles the live **blue (K3s)** cluster; `clusters/talos/` is the self-contained source for the new **green (Talos)** cluster (its own ArgoCD overlay, never the `k8s/**` path).

---

## Documentation

Deeper, living docs are maintained in the AI-context vault ([cartarch-ai-context](https://github.com/jasonvandeventer/cartarch-ai-context), `vanfreckle-platform/`):

- `roadmap.md` — forward-looking priorities and the long-arc lifecycle
- `cluster-layout.md` — steady-state topology, namespaces, ArgoCD inventory
- `current-status.md` — current priorities, recent resolutions, known problems

In-repo, see `docs/decisions/` (ADRs), `docs/runbooks/`, `docs/recovery.md`, and `docs/restore-runbook.md`.

---

## Deployment flow

1. Commit a manifest change to this repo.
2. ArgoCD detects it and applies it to the cluster.
3. State reconciles automatically; Image Updater bumps app image tags on new `v*.*.*` releases via Git write-back.

No manual `kubectl apply` after initial bootstrap (ArgoCD itself, and a few sealed-secret/credential bootstrap items, are documented in `docs/recovery.md`).

---

## Known tradeoffs

- **Single-host SPOF** — all four VMs run on one Unraid host; accepted while load is small (see `roadmap.md` Resilience tier).
- **Longhorn capacity wall** — VM root disks are small; storage-hungry volumes are right-sized per-volume until the disks are expanded.
- **Off-host backups** — Longhorn snapshots currently target NFS on the same host; off-site copy is tracked, not yet done.
