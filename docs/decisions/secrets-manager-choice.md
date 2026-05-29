# Decision: Adopt Sealed Secrets as the Platform Secrets Strategy

**Status:** Accepted
**Date:** 2026-05-28

## Context

The platform has grown to the point where its secret handling is the weakest link in its GitOps story. Until now, Kubernetes Secrets have been hand-applied via `kubectl create secret` or `kubectl apply` from local files. Concretely:

- Cloudflare tunnel token Secret
- Nginx Proxy Manager admin credentials (where used)
- Grafana admin password (currently chart-generated, not in Git)
- mana-archive application Secrets (where present)
- GHCR registry pull credential (image pull secret)

None of these are tracked in Git. None are reproducible if the cluster is rebuilt. All represent "the operator's laptop is the source of truth," which is exactly the GitOps anti-pattern the platform is trying to retire.

Two MCP servers are also queued (obsidian-mcp, cartarch-mcp). cartarch-mcp needs a kubernetes API token for log reading; obsidian-mcp has fewer secret needs but neither should ship before a real secrets strategy exists. This is the forcing function.

The roadmap (*Resilience & Production-Readiness → Secrets and recovery hardening*) names two candidates: Sealed Secrets and External Secrets Operator. This ADR picks one.

## Decision

**Adopt Sealed Secrets (bitnami-labs/sealed-secrets), controller installed via the official Helm chart, managed by ArgoCD.**

Operator workflow:

1. Operator generates a Kubernetes Secret YAML locally (never committed)
2. Operator runs `kubeseal` against the cluster's controller public key, producing a `SealedSecret` YAML
3. The `SealedSecret` is committed to Git
4. ArgoCD syncs the `SealedSecret` into the cluster
5. The controller decrypts it into a Kubernetes Secret in the target namespace
6. Workloads consume the Secret normally

## Rationale

### Why secrets-in-Git is the goal at all

Without secrets in Git, the cluster cannot be rebuilt from Git alone. That breaks the "reproducible from scratch" principle in the roadmap's guiding principles. Every operator action that creates a Secret is undocumented state.

### Sealed Secrets vs. External Secrets Operator (ESO)

| Axis | Sealed Secrets | External Secrets Operator |
|---|---|---|
| New infrastructure required | None (controller in-cluster) | External vault (AWS Secrets Manager, HashiCorp Vault, etc.) |
| Operator complexity | One tool: `kubeseal` | Vault + its auth + ESO + its config |
| Where secrets live | Encrypted in Git, decrypted in cluster | Plain in vault, fetched at runtime |
| Disaster recovery key | The controller's keypair (one Secret to back up) | Vault credentials + vault data |
| GitOps purity | Pure: Git is sufficient | Hybrid: Git + vault required to bootstrap |
| Operator surface area | Tiny | Significant |

Sealed Secrets fits the platform's actual posture today: small operator, single cluster, no existing vault, GitOps-first religion. ESO is the right tool when secrets need to be shared across many clusters, audited centrally, or rotated automatically — none of which apply here yet.

### Why not "just commit base64-encoded Secrets"

Kubernetes Secrets are base64-encoded, not encrypted. Committing them to a public repository (the platform repo is public) is equivalent to committing them in plaintext. Even in a private repo, GitHub leak scanners flag them and they would be exposed via any compromised CI step.

### Specifically why we picked the Helm-chart install

Three reasons:

1. **Matches existing repo patterns.** `longhorn.yaml` and `observability.yaml` are both Helm-chart-via-ArgoCD Applications. Adding `sealed-secrets.yaml` in the same shape minimizes cognitive load and rollout risk.
2. **Easier upgrades.** Bumping `targetRevision` and pushing is enough; no re-rendering.
3. **No values customization needed yet.** The chart's defaults are fine for our scale.

### Trade-offs we accept

- **Key rotation is a manual workflow.** The controller can rotate keys automatically (default: 30 days for new keys; old keys retained for decryption). We accept default behavior for now and document the manual rotation procedure as a future improvement.
- **The controller's master key is a single point of failure.** If the Secret `sealed-secrets-key` in the `sealed-secrets` namespace is destroyed and not restored from a backup, every `SealedSecret` in Git becomes permanently undecryptable. Mitigation: explicit backup procedure (see *Master Key Backup* below).
- **`kubeseal` must be installed on every machine that creates SealedSecrets.** A small operational requirement; acceptable.

## Master Key Backup

The controller's master keypair lives in a Secret named (by convention) `sealed-secrets-key*` in the `sealed-secrets` namespace. **Without this Secret, every SealedSecret in Git is irrecoverable.** It must be backed up.

Backup procedure (run after the controller first starts, and re-run on rotation):

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > sealed-secrets-master.yaml.bak

# Encrypt before storing off-host (Sealed Secrets cannot encrypt its own backup).
# Recommended: age or gpg, stored in a password manager or off-site backup.
age -p -o sealed-secrets-master.yaml.age sealed-secrets-master.yaml.bak
rm sealed-secrets-master.yaml.bak
```

The encrypted backup goes in a separate location from the platform repo (password manager, encrypted USB, etc.). It is NOT committed to Git, even encrypted, because compromise of the repo + the encryption passphrase would still equal compromise of every platform Secret.

Restore procedure (cluster rebuild):

1. Install the Sealed Secrets controller (via ArgoCD as usual)
2. **Before allowing the controller to generate a fresh keypair**, apply the backed-up `sealed-secrets-master.yaml`
3. Restart the controller so it picks up the existing key
4. All existing SealedSecrets now decrypt successfully

This procedure should live in `docs/restore-runbook.md` as a separate failure mode.

## Operator Workflow

Workflow for creating a new application Secret:

```bash
# 1. Create the Secret locally (never commit this file)
kubectl create secret generic my-app-secret \
  --from-literal=api-key=REDACTED \
  --from-literal=db-password=REDACTED \
  --namespace my-app \
  --dry-run=client -o yaml > /tmp/my-app-secret.yaml

# 2. Encrypt it against the cluster's public key
kubeseal --controller-namespace sealed-secrets \
         --controller-name sealed-secrets-controller \
         --format yaml \
         < /tmp/my-app-secret.yaml \
         > k8s/apps/my-app/base/sealed-secret.yaml

# 3. Delete the plaintext file
rm /tmp/my-app-secret.yaml

# 4. Add to the app's kustomization, commit, push
#    ArgoCD syncs the SealedSecret, the controller unwraps it into a Secret.
```

## Validation

After the controller is running, verify the full path before trusting it:

1. Create a test SealedSecret with non-sensitive contents
2. Push to Git
3. Confirm ArgoCD syncs it
4. Confirm the controller materializes the underlying Secret
5. Confirm a test pod can consume the Secret as expected
6. Test the master-key backup AND restore procedure on a throwaway cluster or by deleting and recreating the controller (and confirming the test SealedSecret still decrypts)

Step 6 is the critical one — backups whose restore procedure has not been tested are not backups.

## Migration Plan for Existing Secrets

In rough order:

1. **Cloudflare tunnel token** — highest leverage, currently hand-applied
2. **GHCR pull secret** — used by every workload that pulls from GHCR
3. **Grafana admin password** — promote from chart-generated to known-and-rotatable
4. **mana-archive application secrets** — whatever the app uses
5. **MCP secrets** when those land (cartarch-mcp k8s API token)

Each migration: create new SealedSecret in Git, sync, verify the consuming workload still works, delete the hand-applied Secret. Don't try to do all of them at once.

## Related

- `roadmap.md` → *Resilience & Production-Readiness → Secrets and recovery hardening* (originating roadmap item)
- `docs/restore-runbook.md` → master-key restore procedure (to be added)
- `backup-strategy.md` → master-key backup is now part of the platform's backup posture
