# Observability Stack: Adopt vs Redeploy

**Status:** Accepted
**Date:** 2026-05-20
**Decision:** Redeploy clean under ArgoCD; decommission the manual Helm release.

## Context

`kube-prometheus-stack` has run in the `observability` namespace for 38 days,
installed manually via Helm and unmanaged by ArgoCD — a known bootstrap-tier
risk recorded in `current-status.md`. The repo carries
`k8s/observability/namespace.yaml` and an empty `prometheus-stack/` directory:
GitOps wiring started and abandoned. This ADR records the investigation and the
adopt-vs-redeploy decision. No deploys were performed; investigation was
read-only (`helm get`, `kubectl get`) and introduced no drift.

## Findings

| Probe | Result | Implication |
|---|---|---|
| `helm list` | release `monitoring`, chart `kube-prometheus-stack-83.4.0`, revision **1** | Never upgraded; live state equals one untouched chart render |
| `helm get values` | `null` | **Zero user-supplied values** — nothing custom to port |
| `kubectl get pvc -n observability` | **No resources found** | Prometheus + Grafana run on emptyDir |
| Prometheus CR | `retention: 10d`, no `storage` / `volumeClaimTemplate` | Retention is aspirational; no durable TSDB |
| Pod restarts | Prometheus ×4 (last 3d23h ago), Grafana ×6 | TSDB and Grafana SQLite already wiped repeatedly |
| ServiceMonitors | 12, all chart defaults; 0 PodMonitors | No curated scrape targets; nothing scraping mana-archive |

The decisive fact is the absent PVC. With emptyDir storage and 4–6 pod restarts
already behind it, there is no metrics history and no surviving hand-built
Grafana content to preserve. The current data horizon is ~4 days and evaporates
on the next restart.

## Decision

**Redeploy clean.** Adoption — relabeling live resources for ArgoCD ownership,
untangling the orphan Helm release secret — is the fiddly path, and its sole
rationale is preserving history. There is no history. Adoption would preserve
nothing while costing effort, so it is rejected.

Because `helm get values` is `null` and the release is at revision `1`, the
running install is fully reproducible from the public chart. "Redeploy" here is
low-risk: the only thing recreated is ephemeral state that has already been
discarded multiple times.

## Execution outline

(No deploys performed yet — this ADR is the decision, not the change.)

1. Author `k8s/observability/prometheus-stack/`: an ArgoCD `Application` (Helm
   source, `kube-prometheus-stack`, **pinned** to a current semver chart
   version) plus a `values.yaml`. Target the existing `observability`
   namespace — `namespace.yaml` already declares it.
2. Wire the Application into the `platform-root` app-of-apps.
3. Decommission the manual release: `helm uninstall monitoring -n observability`
   so no orphan release secret lingers. The `monitoring.coreos.com` CRDs are
   Helm-retained and stay in place for the new install.
4. Let ArgoCD sync; verify selfHeal.

This retires the "manually installed, unmanaged by ArgoCD" bootstrap-tier risk.

## values.yaml must-haves

The current install has *no* values — the redeploy is the opportunity to set
what was missing:

- **Persistence (the actual latent fix).**
  `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate` and
  `grafana.persistence.enabled: true`, both on Longhorn (default StorageClass,
  per platform rules). Without this the redeploy faithfully reproduces the
  emptyDir problem.
- **retention** — keep `10d` or set deliberately; only meaningful once storage
  is durable.
- **Grafana admin credentials** — currently a chart-generated secret. Do not
  commit plaintext; use a sealed/external secret.
- **CRD ownership** — the chart bundles CRDs and they already exist. Decide
  chart-managed vs separately-managed; note the known ArgoCD + Helm CRD
  friction.

## One check before executing

`helm get values` returning `null` would not reveal hand-applied
`PrometheusRule` or `AlertmanagerConfig` CRs. Run
`kubectl get prometheusrule,alertmanagerconfig -A` — if every result is a
`monitoring-kube-prometheus-*` default, the redeploy is unconditionally clean.
Optionally log into Grafana to confirm only provisioned dashboards exist
(`kubectl -n observability get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d`);
emptyDir plus 6 restarts means none should have survived regardless.

## Out of scope / follow-up

None of the 12 ServiceMonitors scrape mana-archive — the existing stack could
not have diagnosed the import timeouts that triggered this work. Post-redeploy,
a Git-managed ServiceMonitor for mana-archive is the deliberate add, contingent
on the app exposing a Prometheus `/metrics` endpoint (application-side work,
tied to the Scryfall bulk-download refactor — separate workstream).
