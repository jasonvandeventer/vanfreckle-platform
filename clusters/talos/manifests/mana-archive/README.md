# cartarch (mana-archive) app on green/Talos — v4.0.0 cutover deployment

STAGED manifests for moving the app to green at the v4.0.0 cutover (app + Postgres
co-located on green; blue decommissioned after). The app has only ever run on blue/k3s,
so **parity is the main risk** — this README is the parity record + the open gaps.

**Not applied, not synced.** This directory is deliberately absent from
`clusters/talos/argocd/apps/kustomization.yaml`, so green's ArgoCD ignores it. Deploy
is a window action: either add an Application CR pointing here, or `kubectl apply -k`
this dir during the window — AFTER the gaps below are closed.

## What's here
- `namespace.yaml` — `mana-archive` ns (own ns, not cnpg-system)
- `deployment.yaml` — v4.0.0 app image, 1 replica, Recreate, DATABASE_URL recomposed
  from the CNPG app secret, SESSION+RESEND from the SealedSecret, emptyDir `/data`
- `service.yaml` — ClusterIP `:80→8000` (mirrors blue; cloudflared targets this)
- `kustomization.yaml` — bundles the three, pins image `v4.0.0`

## Deltas from blue (all intentional)
| Blue | Green | Why |
|------|-------|-----|
| `run_migrations` initContainer | removed | SQLite boot-migrations retired at gate #4; schema built by the cutover alembic Job |
| Longhorn PVC 5Gi at `/data` | `emptyDir` | PG holds state; only the regenerable `panels_cache` writes to `/data` |
| SQLite via `DATA_DIR` | `DATABASE_URL` (psycopg v3) | the backend swap |
| Traefik Ingress | none | green has no ingress controller; cloudflared routes to the Service |
| ServiceMonitor | omitted | green observability deferred |
| no resources / no probes | modest resources + `/` probes | green additions (readiness gates tunnel traffic) |

## 🛑 Gaps to close BEFORE applying (window/secrets tasks — do NOT auto-resolve)

- **G1 — mirror `cartarch-prod-app` into the `mana-archive` namespace.** `secretKeyRef`
  is namespace-local; CNPG generates the secret in `cnpg-system`. The app cannot read it
  cross-namespace (the DB *Service* DNS works cross-ns; the *secret* does not). Mirror it
  with a reflector (emberstack) annotation on the source secret, or copy manually:
  ```sh
  kubectl -n cnpg-system get secret cartarch-prod-app -o yaml \
    | sed 's/namespace: cnpg-system/namespace: mana-archive/' \
    | kubectl -n mana-archive apply -f -   # re-copy if CNPG rotates it
  ```
- **G2 — apply `mana-archive-secrets` SealedSecret on green** (provides SESSION_SECRET_KEY
  + RESEND_API_KEY). The existing `k8s/secrets/mana-archive-secrets.sealedsecret.yaml`
  decrypts on green ONLY IF the blue→green sealed-secrets key reuse is done
  (`clusters/talos/argocd/apps/SEALED-SECRETS-KEY-REUSE.md`). Confirm the controller has
  the reused key, then apply the SealedSecret into the `mana-archive` ns.
- **G3 — cloudflared tunnel route.** Re-point `mana.vanfreckle.com` + `cartarch.com` from
  blue's app Service to green's `mana-archive` Service (B2.4). Green's cloudflared is itself
  a deferred build (`clusters/talos/argocd/apps/kustomization.yaml`).
- **G4 — image pinning.** Green pins `v4.0.0` and is NOT under an image-updater. Do not wire
  auto-update until the Phase C dry-run proves the migration.

## Order in the window
1. CNPG cluster up + cutover Jobs run + Stage-4 gate = GO (see `k8s/apps/mana-archive/cutover/`).
2. Close G1 + G2 (secrets in place in `mana-archive` ns).
3. Apply these manifests (or add the ArgoCD app).
4. Wait for readiness; smoke-test on PG.
5. G3: re-route the tunnel. Scale blue's app to 0.
