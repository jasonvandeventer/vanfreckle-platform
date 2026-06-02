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
| `mana-archive-secrets.sealedsecret.yaml` | Cartarch app secrets (`RESEND_API_KEY`, `SESSION_SECRET_KEY`) | `mana-archive` |
| `alertmanager-resend.sealedsecret.yaml` | Alertmanager → Resend SMTP key (email alerting) | `observability` |
| `r2-backup-credential.sealedsecret.yaml` | Cloudflare R2 creds for the Longhorn off-site BackupTarget | `longhorn-system` |

## One-time adoption of pre-existing Secrets

The **three legacy Secrets above** (`grafana-admin-credentials`,
`image-updater-git-creds`, `mana-archive-secrets`) pre-date Sealed Secrets and
existed as unmanaged, hand-created Secrets. The `alertmanager-resend`,
`r2-backup-credential`, and `cnpg-backup-r2` Secrets were sealed from scratch and
need no adoption. The controller will not overwrite a Secret it doesn't own, so
before each legacy one first reconciles, annotate the live Secret to allow
adoption:

```sh
kubectl -n observability annotate secret grafana-admin-credentials \
  sealedsecrets.bitnami.com/managed=true
kubectl -n argocd annotate secret image-updater-git-creds \
  sealedsecrets.bitnami.com/managed=true
kubectl -n mana-archive annotate secret mana-archive-secrets \
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
