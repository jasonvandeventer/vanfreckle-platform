# k8s/apps/barman-cloud-plugin — vendored plugin release manifest

The CloudNativePG **Barman Cloud Plugin**, applied via GitOps as a vendored,
version-pinned release manifest. Reconciled by the `barman-cloud-plugin` ArgoCD
Application (`k8s/argocd/apps/barman-cloud-plugin.yaml`), a non-recursive
Directory source over this folder with `include: 'manifest.yaml'` (so this
README is ignored by ArgoCD).

## Why vendored (not a remote URL)

The plugin is distributed as a single release `manifest.yaml` (CRDs + RBAC +
deployment + cert-manager `Certificate`s), not a Helm chart. ArgoCD can't source
a release-download URL directly, and pinning matters for a backup component, so
the manifest lives in Git.

## Bootstrap / version bump

```sh
# Pin: v0.12.0 (current as of 2026-06-01 — check the releases page before bumping)
curl -fsSL -o k8s/apps/barman-cloud-plugin/manifest.yaml \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.12.0/manifest.yaml
git add k8s/apps/barman-cloud-plugin/manifest.yaml
```

Then commit. ArgoCD applies it (wave `0`) after cert-manager (`-2`) and the CNPG
operator (`-1`), before the cartarch-postgres cluster (`1`).

## Prerequisites

- **cert-manager** must be installed and its API ready (`cmctl check api`) — the
  manifest includes `Certificate` resources. Provided by the `cert-manager`
  ArgoCD Application.
- **CNPG operator >= 1.26** (we run 1.29.1 via chart 0.28.2).

## Verify after sync

```sh
kubectl -n cnpg-system rollout status deployment barman-cloud
kubectl get crd objectstores.barmancloud.cnpg.io
```
