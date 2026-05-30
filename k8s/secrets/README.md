# k8s/secrets — standalone SealedSecrets

GitOps home for `SealedSecret` manifests that don't belong to a single app's
kustomize base — platform/bootstrap-tier secrets that previously existed only as
hand-applied Kubernetes Secrets. Reconciled by the `platform-secrets` ArgoCD
Application (`k8s/argocd/apps/platform-secrets.yaml`), which is a non-recursive
Directory source over this folder with `include: '*.sealedsecret.yaml'` (so this
README is ignored by ArgoCD).

Each manifest declares its own target namespace; the single Application spans
namespaces because the `default` AppProject allows destination namespace `*`.

## Contents

| File | Secret | Namespace |
|---|---|---|
| `grafana-admin-credentials.sealedsecret.yaml` | Grafana admin login (kube-prometheus-stack) | `observability` |
| `image-updater-git-creds.sealedsecret.yaml` | Argo CD Image Updater git write-back creds | `argocd` |

## One-time adoption of pre-existing Secrets

Both secrets pre-date Sealed Secrets and exist as unmanaged, hand-created
Secrets. The controller will not overwrite a Secret it doesn't own, so before
each one first reconciles, annotate the live Secret to allow adoption:

```sh
kubectl -n observability annotate secret grafana-admin-credentials \
  sealedsecrets.bitnami.com/managed=true
kubectl -n argocd annotate secret image-updater-git-creds \
  sealedsecrets.bitnami.com/managed=true
```

The sealed values were captured from the live Secrets, so adoption changes no
credential and triggers no workload restart.

## Out of scope — not Kubernetes Secrets

The roadmap's "migrate remaining hand-created Secrets" item also named the
**Cloudflare tunnel token** and the **Nginx Proxy Manager credentials**. Neither
is a Kubernetes Secret: `cloudflared` and NPM run on the Unraid host, outside
the cluster (confirmed 2026-05-29 — no cloudflared workload and no
cloudflare/NPM Secret in any namespace). Sealed Secrets only encrypts Kubernetes
Secrets, so these cannot be sealed into this repo. Their backup/recovery posture
belongs in `backup-strategy.md` and `docs/recovery.md` instead.
