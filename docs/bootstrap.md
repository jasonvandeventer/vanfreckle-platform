# Platform Bootstrap

**Last Updated:** [TODO: fill on completion]
**Status:** **Draft skeleton — populate from operator's notes and shell history.** This document captures *how the platform was originally built* so the cluster can be rebuilt from scratch if needed.

This complements `docs/recovery.md`, which covers recovering an *existing* cluster after a partial failure. Bootstrap is the from-scratch procedure; the two overlap on bootstrap-tier Secrets because that step is identical in both cases.

> **Note to the operator (delete on completion):** every `[TODO]` block below is a place where the original procedure needs to be captured. The structure below is the *expected* shape based on the platform inventory in `cluster-layout.md` — adjust freely if your actual bootstrap diverged. Anything you can't remember exactly is worth a one-line "best-guess; verify on next rebuild" note rather than leaving it blank.

## Prerequisites

[TODO: confirm or correct this list — likely missing items the operator added during the original build.]

- Unraid host with sufficient capacity for the cluster VMs (CPU, RAM, disk)
- VM template or installer for Rocky Linux 9.7
- Domain name (`vanfreckle.com`) with Cloudflare DNS active
- Cloudflare account with Zero Trust enabled (for the Tunnel)
- GitHub account with the platform manifests repository accessible
- Operator workstation with `kubectl`, `helm`, `argocd` CLIs installed

## Step 1 — Provision the VMs

[TODO: capture the actual VM creation steps. The cluster-layout shows four VMs (`node1` control-plane+worker, `node2`–`node4` workers), each with a ~34Gi root filesystem on Rocky 9.7. Worth recording:]

- Exact VM resource sizing (vCPU, RAM, disk per node)
- Rocky Linux 9.7 install method (ISO, kickstart, template?)
- Networking — static IPs vs DHCP reservations, hostname assignments
- SSH key distribution mechanism
- Any host-level prep on Unraid (VM defaults, network bridge, storage location for VM disks)

[TODO: note the disk-size choice in hindsight. The ~34Gi root is now the Longhorn capacity ceiling (`roadmap.md` Resilience tier). If you were to do this again, would you provision larger? Record that lesson here.]

## Step 2 — Install K3s

[TODO: capture the K3s install. Cluster is currently on `v1.34.6`. Likely covers:]

- Server install on `node1`
  - Install command (typically `curl -sfL https://get.k3s.io | sh -`, with flags)
  - Any `--write-kubeconfig-mode`, `--disable`, or `--cluster-init` flags used
  - How the cluster token was captured for joining agents
- Agent install on `node2`–`node4`
  - Install command using the captured token + server URL
- Post-install verification (`kubectl get nodes`, expected node count, etc.)

## Step 3 — Install Longhorn

[TODO: capture the Longhorn install. Likely Helm-based:]

- Add the Longhorn Helm repo
- Install command with any custom values
- Set `longhorn` as the default StorageClass (note: this is the step that later interacts with `docs/decisions/local-path-default-class-fix.md` — the K3s built-in `local-path` was also default until reconciled non-default via Git)
- Verify Longhorn pods come up
- Confirm `longhorn-system` namespace exists and is healthy

## Step 4 — Install ArgoCD

[TODO: ArgoCD install steps. Bootstrap chicken-and-egg note: ArgoCD itself is not managed by ArgoCD; this step is intentionally manual on every rebuild. Likely covers:]

- Manifest-based install (`kubectl apply -n argocd -f <upstream-install.yaml>`) or Helm
- Initial admin password retrieval
- CLI login from the operator workstation
- Repository registration — the platform manifests repo at GitHub
- Any tweaks to the install (resource limits, custom values, etc.)

## Step 5 — Apply the `platform-root` Application

[TODO: capture the app-of-apps bootstrap. Likely a single `kubectl apply` of the Application manifest that lives at `k8s/argocd/apps/platform-root.yaml`:]

```bash
kubectl apply -f k8s/argocd/apps/platform-root.yaml
```

This Application discovers and creates every other Application listed in `cluster-layout.md`. After this step, the cluster's state is GitOps-managed.

[TODO: note the order in which Applications come up after `platform-root` lands. `longhorn` and `platform` (the local-path reconciliation) are the early ones; `mana-archive` and `observability` follow.]

## Step 6 — Recreate bootstrap-tier Secrets

These Secrets must exist before the ArgoCD-managed workloads can come up. They are intentionally not in Git (or are slated to move into Sealed Secrets once `roadmap.md` Near-Term item 4 lands):

- `grafana-admin-credentials` in the `observability` namespace — see `observability.md` *Secrets* section for the exact recreation command
- Cloudflare Tunnel token
- Nginx Proxy Manager admin credentials
- Mana Archive / cartarch application secrets

Each is also documented in `docs/recovery.md` (the live source for the recreation procedure). After Sealed Secrets adoption, most of these will instead be recoverable from the GitOps repo provided the controller master key is restored — see `backup-strategy.md`.

## Step 7 — Install Argo CD Image Updater

[TODO: capture the Image Updater install. Currently a manual install (a Known Problem in `current-status.md`); planned to be brought under ArgoCD alongside Sealed Secrets adoption. Until that pairing lands, document the manual install here.]

## Step 8 — Configure Cloudflare Tunnel

[TODO: capture the Cloudflare Tunnel setup. Likely covers:]

- Create the tunnel in the Cloudflare Zero Trust dashboard
- Where `cloudflared` actually runs (on the Unraid host? in the cluster as a Deployment? both?)
- Configure tunnel routes (currently `cartarch.com` and `mana.vanfreckle.com` → cluster's Traefik service)
- Validate the tunnel comes up and the hostnames route correctly

## Step 9 — Verify

[TODO: post-bootstrap verification checklist. Suggested items:]

- All ArgoCD Applications `Synced + Healthy` (count matches `cluster-layout.md`)
- Longhorn storage available, `longhorn` is the default StorageClass, `local-path` is non-default
- `cartarch.com` and `mana.vanfreckle.com` reachable externally
- Observability stack reachable via port-forward (`svc/kube-prometheus-stack-grafana` on `:80`)
- A throwaway test pod can claim a Longhorn PVC and write to it

## Recovery vs bootstrap

This document is *from scratch*. For recovering a cluster that already existed and partially failed, see `docs/recovery.md`. The two documents intentionally overlap on Step 6 (bootstrap-tier Secrets) because that procedure is identical in both cases.

## Lessons learned (recorded after the fact)

[TODO: as bootstrap procedures change or as rebuilds happen, capture lessons here so the next bootstrap is smoother than the last. Existing candidates from the platform's history:]

- VM root disk sizing — the ~34Gi root filesystems became the Longhorn capacity ceiling (`roadmap.md` Resilience tier); larger root disks or a separate Longhorn data disk would prevent this from recurring.
- Empty ArgoCD Applications — a non-recursive source path that does not reach the intended subdirectory will sync vacuously. Always add a `kustomization.yaml` at the source path so the Application actually manages something. See `docs/decisions/argocd-repo-hygiene.md`.
- Out-of-bounds symlinks — the repo-server's working directory must not be symlinked outside the repo, or ArgoCD breaks across the entire repository. See `docs/decisions/argocd-repo-hygiene.md`.
