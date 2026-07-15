# cartarch app on green/Talos

The prod Cartarch app, live on green/Talos in the `cnpg-system` namespace (app +
Postgres co-located; blue/k3s decommissioned after the v4.0.0 cutover). This README is
the parity record vs the old blue Deployment.

**Synced** by `clusters/talos/argocd/apps/cartarch.yaml` (automated prune+selfHeal, SSA)
and promoted by argocd-image-updater (semver) via `.argocd-source-cartarch.yaml`.

## Namespace
The app runs **in `cnpg-system`**, co-located with the `cartarch-prod` CNPG cluster.
This makes the CNPG-generated `cartarch-prod-app` secret and the `cartarch-prod-rw`
service both same-namespace, so there is **no cross-namespace secret mirror**.
`cnpg-system` already exists on the cluster, so there is no `namespace.yaml` here.

## What's here
- `deployment.yaml` — app image, 1 replica, Recreate, DATABASE_URL recomposed from the
  CNPG app secret, SESSION+RESEND from `cartarch-secrets`, emptyDir `/data`
- `service.yaml` — NodePort `:80→8000` on `nodePort: 30080` (cloudflared on Unraid targets
  `10.42.1.63:30080` — this number is load-bearing)
- `migrate-job.yaml` — `cartarch-migrate`, PreSync hook (alembic upgrade head)
- `cronjob.yaml` — `cartarch-price-ingest`, daily 12:00 UTC (07:00 UTC-5)
- `cartarch-secrets.sealedsecret.yaml` — SESSION_SECRET_KEY + RESEND_API_KEY, sealed for
  `cnpg-system` (in-git; the earlier out-of-band apply is retired)
- `kustomization.yaml` — bundles the above; `newTag` kept maintained-correct as a
  fallback, the image-updater override is authoritative

## Deltas from blue (all intentional)
| Blue | Green | Why |
|------|-------|-----|
| `run_migrations` initContainer | removed | SQLite boot-migrations retired at gate #4; schema built by the PreSync alembic Job |
| Longhorn PVC 5Gi at `/data` | `emptyDir` | PG holds state; only the regenerable `panels_cache` writes to `/data` |
| SQLite via `DATA_DIR` | `DATABASE_URL` (psycopg v3) | the backend swap |
| Traefik Ingress | none | green has no ingress controller; cloudflared routes to the NodePort Service |
| ServiceMonitor | omitted | green observability deferred |
| no resources / no probes | modest resources + `/` probes | green additions (readiness gates tunnel traffic) |
