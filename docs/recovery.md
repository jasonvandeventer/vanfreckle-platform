# Cluster Recovery Playbook

**Status:** Draft stub — to be expanded with full playbook in a dedicated session
**Last updated:** 2026-05-16

## Purpose

Step-by-step procedure for recovering the platform after an unplanned outage (power loss, host crash, network partition, etc.). The goal: a documented path from "cluster is down" to "verified healthy" that any operator can follow without prior tribal knowledge.

## Status

Stub created during 2026-05-16 post-outage audit. Full playbook to be written in a future session. Lessons learned during the 2026-05-16 outage are captured in `inventory.md` under "Outage Incident Summary"; those should be folded into this document when it is fleshed out.

## Lessons captured 2026-05-16 (to incorporate into full playbook)

1. **Wait for Unraid parity check before bringing cluster up.** Parity scan competes with cluster I/O.
2. **Bring control plane (node1) up first**, then agent nodes (node2-4).
3. **Allow 5–10 minutes for Longhorn replica rebuilds** before judging volume health. Replicas show Degraded during rebuild; this is expected.
4. **Volume CR `robustness` field can lag replica state.** Check the YAML directly when the table view seems wrong.
5. **Stuck Terminating PVCs:** check for Completed pods still referencing the PVC before patching finalizers. The `pvc-protection` finalizer is held by *any* pod referencing the PVC, including ones in Completed state.
6. **`longhorn-uninstall` Job can appear as Failed during recovery.** This is the Helm pre-delete hook firing during a chaotic restart; the Longhorn safety flag (`deleting-confirmation-flag`) is the backstop. Failed status here means the safety worked, not that anything is broken.
7. **`argocd-repo-server` init container can stick in CrashLoopBackOff** with `ln: Already exists` after unclean shutdown. Delete the pod; the Deployment will create a fresh one with a clean EmptyDir. Upstream ArgoCD bug, unrelated to local config.

## Recovery verification checklist

To be turned into a tested playbook. Initial draft:
```
kubectl get nodes
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n argocd get pods
kubectl -n argocd get applications
kubectl get pvc -A
kubectl get pods -A | grep -vE 'Running|Completed'
```
All of: nodes Ready, Longhorn pods Running, volumes attached/healthy or detached (not faulted), ArgoCD pods Running, Applications Synced, PVCs Bound, last command returns only header.

## Bootstrap secrets (not in Git)

Some Kubernetes Secrets are deliberately kept out of the GitOps repo — no
plaintext credentials in Git — and must be recreated by hand on a cluster
rebuild. Until a secrets manager is adopted (see `roadmap.md`, Near-Term
item 5), this list is the record of what those are and how to recreate them.

### `grafana-admin-credentials`

- **Namespace:** `observability`
- **Consumed by:** Grafana, via `grafana.admin.existingSecret` in
  `k8s/observability/prometheus-stack/values.yaml`.
- **Symptom if missing:** the Grafana pod fails to start with
  `CreateContainerConfigError`. The rest of the observability stack is
  unaffected.
- **Recreate:**

  ```
  kubectl create secret generic grafana-admin-credentials -n observability \
    --from-literal=admin-user=admin \
    --from-literal=admin-password='<password>'
  ```

  The data keys (`admin-user`, `admin-password`) must match `userKey` and
  `passwordKey` in the values file. Once the Secret exists, Grafana recovers on
  its own — `kubectl` retries `CreateContainerConfigError` automatically; no pod
  delete is required.
- **Created:** 2026-05-27, during the observability GitOps redeploy. See
  `docs/runbooks/observability-redeploy.md`.
