# Runbook — Release Retraction (undo a bad Cartarch release)

**Added:** 2026-07-07
**Status:** Primary path **UNVERIFIED** — codified but never exercised; first real
use verifies the convergence inference (see below). Fallback path is the proven
swap-race-safe procedure.
**Spec of record:** Phase D v1 (`lifecycle-phase-d-v1-2026-07-07`), Decision D3.
**Detection:** the `verify-deploy` job in cartarch's `publish.yml` fires the
Discord alert that sends you here (⚠ `vX.Y.Z NOT CONFIRMED live…`).

## Purpose

A release deployed and `verify-deploy` said it is bad (or a human found it bad).
Undo it. This is **undo-in-one-command** for the common case: there is a single
promoter (`argocd-image-updater`, the `cartarch-updater` CR) and it converges on
the **highest available** semver tag. Remove the bad tag and it walks back on its
own — no reconciler suspended, no git fight, single-promoter preserved.

**Scope note:** the schema stays at head across a retraction (git tag stays, the
migration is not reverted). That is only safe because migrations are
backward-compatible with the previous release for the rollout window — the
expand→contract enforcement in the `ai-dev-team` harness exists precisely so this
runbook can leave the schema alone. If a release shipped a *non*-compatible
migration, this runbook does not cover it: you have a data problem, not a
deploy problem.

## Conventions (apply on ANY retraction)

- **Git tag and GitHub Release stay.** History is immutable; do not delete either.
- **Release body gets a header:** edit the GitHub Release to prepend
  `**RETRACTED <date>: <reason>**` so the changelog record self-documents.
  `gh release edit vX.Y.Z --notes "$(printf '**RETRACTED %s: %s**\n\n%s' "$(date +%F)" "<reason>" "$(gh release view vX.Y.Z --json body -q .body)")"`
- **Schema stays at head** (see scope note above).

---

## Primary path — delete the bad tag, let the updater converge  ⚠ UNVERIFIED

> **INFERENCE, not yet exercised.** The `cartarch-updater` CR uses
> `updateStrategy: semver`, so when the newest tag disappears it should write the
> **highest remaining** tag (an OLDER version) to `.argocd-source-cartarch.yaml`
> on its next poll, and `selfHeal` deploys it. This follows from
> highest-available-semver semantics but has **never been run**. The FIRST use of
> this path verifies it — watch the updater log and the write-back commit before
> trusting it, and update this status line to VERIFIED afterward.

1. **Delete the bad version from the GHCR `cartarch` package.** UI (Packages →
   `cartarch` → the `vX.Y.Z` version → Delete), or:
   ```
   # find the version id for the bad tag, then delete it
   gh api -H "Accept: application/vnd.github+json" \
     /user/packages/container/cartarch/versions \
     --jq '.[] | select(.metadata.container.tags[]? == "vX.Y.Z") | .id'
   gh api -X DELETE /user/packages/container/cartarch/versions/<VERSION_ID>
   ```
2. **Wait for the updater to converge.** On its next poll `cartarch-updater`
   re-resolves the highest remaining semver tag and commits it to
   `.argocd-source-cartarch.yaml`. Watch it:
   ```
   kubectl -n argocd logs deploy/argocd-image-updater -f | grep -i cartarch
   git -C <this repo> log -1 -- clusters/talos/manifests/cartarch/.argocd-source-cartarch.yaml
   ```
3. **`selfHeal` deploys the reverted tag.** Confirm via `verify-deploy`'s own
   probe — the public version should now report the older tag:
   ```
   curl -s https://cartarch.com/version
   ```
4. Apply the **Conventions** above (RETRACTED header on the bad Release).

If step 2 does not converge within a poll interval or two (updater picks the
wrong tag, or writes nothing), STOP and use the fallback — do not hand-edit the
source file while the updater is live (that is the swap race the fallback exists
to avoid).

---

## Fallback path — neutralize both reconcilers, then pin by hand

Use when the primary path is unavailable (can't delete the package version) or
misbehaves (updater won't converge / picks wrong). This is the swap-race lesson
from the rename cutover: **neutralize BOTH reconcilers before any manual pin, or
they fight each other over the image tag.**

1. **Stop ArgoCD's auto-sync on the app:**
   ```
   argocd app set cartarch --sync-policy none
   ```
2. **Suspend/disable the `cartarch-updater` CR** (so it can't re-bump the pin):
   ```
   kubectl -n argocd patch imageupdater cartarch-updater --type merge \
     -p '{"spec":{"applicationRefs":[]}}'
   # or scale/annotate to disable per the updater's mechanism; the point is it
   # must not write .argocd-source-cartarch.yaml while you pin.
   ```
3. **Pin the previous good version by immutable ref.** Prefer the digest
   (`@sha256:…`) over the tag so nothing can re-resolve it:
   ```
   # in clusters/talos/manifests/cartarch/kustomization.yaml (images: newTag/digest),
   # commit the previous good ref, then apply it directly.
   ```
4. **Investigate** the bad release while it's frozen.
5. **Re-enable both**, in this order, once a fixed forward release is ready:
   restore the `cartarch-updater` CR config, then
   `argocd app set cartarch --sync-policy automated` (with the same
   `selfHeal`/`prune` flags it had). Confirm the updater and ArgoCD agree on the
   tag before walking away.

Apply the **Conventions** (RETRACTED header) here too.

## Objects this runbook touches

| Thing | Value |
|-------|-------|
| ArgoCD Application | `cartarch` |
| ImageUpdater CR | `cartarch-updater` (ns `argocd`, `updateStrategy: semver`) |
| Image | `ghcr.io/jasonvandeventer/cartarch` |
| Write-back file | `clusters/talos/manifests/cartarch/.argocd-source-cartarch.yaml` |
| GHCR package | `cartarch` (owner `jasonvandeventer`) |
| Detection | `verify-deploy` job in cartarch `publish.yml` |
