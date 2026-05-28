# Decision: Secrets Manager (Sealed Secrets)

**Date:** 2026-05-27
**Status:** Decided; implementation tracked as `roadmap.md` Near-Term item 4
**Supersedes:** the open "Sealed Secrets or External Secrets Operator" question previously parked in `roadmap.md` *Resilience & Production-Readiness → Secrets and recovery hardening* and *Phase 5 → Secrets Management*

## Context

The platform has accumulated several out-of-band secrets:

- Cloudflare Tunnel token
- Nginx Proxy Manager admin credentials
- `grafana-admin-credentials` (in the `observability` namespace) — hand-created during the 2026-05-27 observability redeploy, deliberately not in Git, must be recreated on any cluster rebuild or Grafana fails to start
- Mana Archive / cartarch application secrets

The roadmap's Near-Term item 5 (deploy `obsidian-mcp` and `cartarch-mcp` under GitOps) requires committing a `CARTARCH_PROD_DB_URL` Secret without leaving plaintext in the repo. This was the forcing function — the open "pick a secrets manager when earned" question is now blocking concrete work.

The choice was between two real candidates:

- **Sealed Secrets** (bitnami-labs) — a controller in the cluster decrypts a `SealedSecret` CRD into a regular Kubernetes `Secret`. The encrypted form is what lives in Git.
- **External Secrets Operator (ESO)** — pulls secrets at runtime from an external store (Vault, AWS Secrets Manager, 1Password Connect, etc.) and materializes them as Kubernetes Secrets in-cluster.

Vault was explicitly out of scope per existing roadmap guidance ("avoid adding Vault before the platform needs it").

## Decision

**Adopt Sealed Secrets.**

Deployed as an ArgoCD Application under `platform-root`. Existing out-of-band secrets migrated onto sealed manifests committed to Git. Future secrets land sealed by default.

## Rationale

Four properties of the platform pushed the decision toward Sealed Secrets:

1. **Pure-GitOps alignment.** The encrypted secret *is* the Git artifact. No out-of-band store, no sync loop, no second source of truth. Matches the existing guiding principle "Git is the source of truth" without exception.
2. **No new infrastructure to run.** Sealed Secrets is one controller in-cluster. ESO additionally requires running and securing a backend (Vault, 1Password Connect, or a cloud secret manager). For a single operator on a homelab, that is more surface area than the platform's current threat model justifies.
3. **ArgoCD-native.** ArgoCD sees the `SealedSecret` CRD it does not try to decrypt; the controller decrypts and produces the actual `Secret`. Zero friction with the existing GitOps flow.
4. **Boring and documented.** Does one thing. Matches the guiding principle "prefer boring, documented operations over clever automation."

ESO is more attractive *if* the platform later migrates to a cloud provider with a managed secret manager (referenced under `roadmap.md` Open Decisions → Hosting). That migration is undecided and possibly years away. Paying the ESO complexity tax today for a hypothetical future is the wrong tradeoff. The decision is reversible: if hosting changes, Sealed Secrets can be retired in favor of ESO without affecting the broader architecture.

## Consequences

**Positive:**

- Unblocks `roadmap.md` Near-Term item 5 (MCP deployment) — `cartarch-mcp`'s DB URL can be sealed and committed
- Retires `grafana-admin-credentials` (and the other out-of-band Secrets) as hand-created bootstrap-tier artefacts
- Sets the pattern for every future Secret committed to the repo

**Operational obligation — master key backup:**
The Sealed Secrets controller has a master key. Lose it (cluster wipe, host loss, filesystem failure on the Unraid host) and every sealed secret in Git becomes useless until restored. This obligation folds into the off-host backups item in `roadmap.md` (Resilience tier) — `backup-strategy.md` covers it explicitly, and it is recorded as a bootstrap secret in `docs/recovery.md`. This is the one new failure mode introduced by the decision; it is real and must be addressed before paying-user load arrives.

**Natural pairing:** Image Updater is currently installed manually and not ArgoCD-managed (an existing bootstrap-tier risk in `current-status.md`). Sealed Secrets adoption is the same shape of fix ("controller in cluster but not managed by ArgoCD" → "controller managed by ArgoCD"). Knocking both out in the same sprint is real economy of motion; flagged here, the choice to pair them is operational rather than architectural.

## Alternatives considered

- **External Secrets Operator (ESO).** Rejected for current setup: extra infrastructure, second source of truth, optimized for cases the platform does not yet have. Reconsider if hosting moves to managed Kubernetes with a managed secret backend.
- **Vault.** Explicitly out of scope per existing roadmap guidance. The complexity is not justified by the current threat model or scale.
- **Continue with plain Kubernetes Secrets + out-of-band creation.** The current baseline. Tolerable when the secret count is small and the operator is the only person who touches the cluster; not tolerable as soon as Secrets need to be committed to Git or rebuilt on recovery without manual reapplication of every credential.

## References

- `roadmap.md` Near-Term item 4 (this work's tracking entry)
- `roadmap.md` Near-Term item 5 (MCP rollout — the forcing function)
- `roadmap.md` Resilience & Production-Readiness → Off-host, off-site backups (master-key backup obligation)
- `roadmap.md` Phase 5 → Secrets Management (progression path)
- `current-status.md` Known Problems (Image Updater pairing opportunity)
- `observability.md` *Secrets* section (the `grafana-admin-credentials` precedent)
- `backup-strategy.md` *Sealed Secrets controller master key* (the operational obligation)
