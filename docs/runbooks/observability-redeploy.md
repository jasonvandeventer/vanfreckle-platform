# Runbook — Observability Stack GitOps Redeploy

**Executed:** 2026-05-27
**Status:** Complete
**Decision record:** `docs/decisions/observability-adopt-vs-redeploy.md`

## Purpose

Moved `kube-prometheus-stack` from a hand-installed Helm release — invisible to
ArgoCD and running on `emptyDir` — to a GitOps-managed ArgoCD Application on
durable Longhorn storage. This retires the long-standing "manually installed,
unmanaged by ArgoCD" bootstrap-tier risk.

Per the ADR, this was a clean **redeploy** (decommission the manual release,
recreate under ArgoCD), not an in-place adoption. The manual release was at Helm
revision 1 with no user-supplied values (`helm get values` returned `null`) and,
on `emptyDir`, no metrics history worth preserving — so there was nothing to
adopt.

## Outcome

- ArgoCD Application `observability` — multi-source (chart + repo `$values`),
  `kube-prometheus-stack` pinned to chart `83.4.0`, `selfHeal` enabled. Cluster
  Application count is now 5.
- Prometheus (8Gi) and Grafana (5Gi) on Longhorn PVCs.
- Durability validated: metrics survived a deliberate Prometheus pod restart —
  the failure mode the old `emptyDir` install could not survive.

The redeploy did **not** go to plan. Two unplanned detours — a missing Grafana
Secret and a Longhorn capacity wall — are documented in the procedure below and
are the most useful part of this runbook.

## Gotchas — read before re-running

1. **`ServerSideApply=true` is mandatory.** The `kube-prometheus-stack` CRDs
   (notably `prometheuses.monitoring.coreos.com`) exceed the size limit for
   client-side apply's last-applied-configuration annotation. Without
   `ServerSideApply=true` in the Application's `syncOptions`, the sync fails on
   the CRD.

2. **A StatefulSet `volumeClaimTemplate` is immutable.** Changing the Prometheus
   PVC size or annotations after the first sync cannot be done in place. The
   supported fix: delete the StatefulSet (the prometheus-operator recreates it
   from the Prometheus CR within seconds) and delete the orphaned PVC, then let
   the new template apply.

3. **The Grafana admin Secret is hand-created and not in Git.** `values.yaml`
   references `grafana.admin.existingSecret: grafana-admin-credentials`. That
   Secret is deliberately kept out of the repo — no plaintext credentials in
   Git — and must exist before Grafana starts, or the pod fails with
   `CreateContainerConfigError`.

## Repository layout

- Application manifest: `k8s/argocd/apps/observability.yaml` — a flat file in
  the directory the `platform-root` app-of-apps scans. `platform-root` is a
  **non-recursive** Directory source; a manifest in a subdirectory would never
  be picked up.
- Values + namespace: `k8s/observability/prometheus-stack/values.yaml` and
  `k8s/observability/namespace.yaml` — supplied via the Application's second
  (`$values`) source.

## Rollback

The manual release was reproducible from the public chart with no values. To
revert the redeploy:

```
helm install monitoring prometheus-community/kube-prometheus-stack \
  --version 83.4.0 -n observability
```

This restores the prior (emptyDir) state exactly. Requires the
`prometheus-community` Helm repo to be registered (`helm repo list`).

## Procedure as executed

### Phase 0–1 — Discovery and state capture (read-only)

Confirmed the `platform-root` source path (`k8s/argocd/apps`) and that it is a
non-recursive Directory source; confirmed `longhorn` is a remote-Helm-type
Application (the pattern to mirror) and the `default` AppProject.

Captured the manual release: `helm list -n observability` returned release
`monitoring`, chart `kube-prometheus-stack-83.4.0`, **revision 1**.
`kubectl get pvc -n observability` returned nothing — confirming `emptyDir`. 13
ServiceMonitors, all chart defaults; none scraping the application.

### Phase 2 — Prepare the manifests

Discovery during this phase changed the design. The repo already contained
`k8s/observability/prometheus-stack/values.yaml` (authored earlier) and an
untracked copy of the ADR — GitOps wiring that had been started and abandoned.
The values file's own header declared it was meant to be consumed via a
multi-source `$values` ref. The design was therefore switched from a
single-source Application with inline values to a **multi-source** Application
matching that intent, and `namespace.yaml` was re-authored.

A `git status` / `git log --follow` review untangled the working-tree state (a
modified `namespace.yaml`, an untracked ADR and values file). Lesson: settle the
git picture before touching the cluster.

Four files were committed together: the Application manifest, the namespace
manifest, the values file, and the ADR.

### Phase 3 — Decommission the manual release

```
helm uninstall monitoring -n observability
```

Removes Deployments, StatefulSets, Services, the chart's
ServiceMonitors/PrometheusRules, and the Prometheus/Alertmanager CRs. **Retains**
the CRDs (Helm never deletes CRDs — the new install reuses them) and the
namespace. No PVCs existed to clean.

### Phase 4 — Hand over to ArgoCD

Committed and pushed; `platform-root` created the `observability` Application on
next sync. **Verify** the new Application actually exists and manages real
resources — not a vacuous `Synced/Healthy` over zero resources, a failure mode
the platform has hit before with non-recursive source paths.

### Phase 5 — First sync, two failures

**Grafana — `CreateContainerConfigError`.** Expected: `values.yaml` references
`grafana-admin-credentials`, which had never been created. Resolved by creating
the Secret by hand:

```
kubectl create secret generic grafana-admin-credentials -n observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<chosen-password>'
```

The keys must match `userKey`/`passwordKey` in `values.yaml`. Grafana recovered
on its own once the Secret existed.

**Prometheus — stuck `Init:0/1`.** The Longhorn volume went `detached / faulted`;
pod events showed `FailedAttachVolume ... volume is not ready for workloads`.
Root cause, from the longhorn-manager logs: `insufficient storage` — the
intended 20Gi volume at the cluster-default 2 replicas could not be scheduled.
The four cluster VMs each run on a ~34Gi root disk; with existing volumes and
Longhorn's overprovisioning and minimal-free-space guards, only roughly 7–9Gi
per node was actually placeable. The 12TB Unraid array does not reach the VMs.

Resolved by right-sizing the request, not the cluster: the `values.yaml`
Prometheus PVC was set to **8Gi** with a per-volume `longhorn.io/replica-count:
"1"` annotation. Because the `volumeClaimTemplate` is immutable, the StatefulSet
and the orphaned 20Gi PVC were deleted so the new template could apply:

```
kubectl delete statefulset prometheus-kube-prometheus-stack-prometheus -n observability
kubectl delete pvc prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 -n observability
```

After committing the updated `values.yaml` and re-syncing, the 8Gi
single-replica volume scheduled, attached, and Prometheus reached `2/2 Running`;
the Application went `Synced / Healthy`.

### Phase 6 — Acceptance test

Confirmed Prometheus held metrics, deleted the Prometheus pod, waited for the
reschedule, and confirmed pre-restart data was still present. This is the proof
the `emptyDir` problem is gone — the old install could not have survived this.

## Open follow-ups

- **Longhorn capacity expansion.** The ~34Gi-per-node ceiling caps every future
  volume. Tracked in `roadmap.md` (Resilience & Production-Readiness tier) as
  deliberate, ADR-worthy work.
- **Grafana Secret to a secrets manager.** `grafana-admin-credentials` is a
  hand-created, out-of-band object; record it in `docs/recovery.md` (bootstrap
  secrets) and fold it into the secrets-manager adoption (roadmap Near-Term
  item 5).
- **Application ServiceMonitor.** None of the chart-default ServiceMonitors
  scrape the mana-archive app. A Git-managed ServiceMonitor is the next
  observability step; it must carry the label `release: kube-prometheus-stack`
  to be scraped, and is gated on the app exposing a `/metrics` endpoint.
