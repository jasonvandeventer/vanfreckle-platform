# Decision: Timing of the v4 PostgreSQL Migration vs. Continued Platform Work

**Status:** Accepted
**Date:** 2026-05-29

> **Update 2026-06-20 — see the dated addendum at the end.** The "v4 — soon" decision has held and materially advanced: app-side readiness gates are done and shipped on prod (v3.39.9), and CNPG + Barman-Cloud → Cloudflare R2 backup/restore is now **proven end-to-end and GitOps-codified** on the new green/Talos cluster — which **overturns** the earlier "Barman sidecar wall → consider VolumeSnapshot" caveat.

## Context

The Cartarch app is at **v3.30.22** and has held a hard **"SQLite-until-v4"** invariant across 65 successive releases — every v3 release is zero-schema, zero-migration. **v4** is the PostgreSQL migration, framed in `cartarch/roadmap.md` not as a scaling chore but as the architectural unblock for the product vision (multi-writer durable state, event-sourced game tracker, multi-tenancy substrate, real concurrency). That same roadmap parks it as *"Likely a multi-month effort … the right thing when timing aligns."*

**On that "multi-month" estimate — it does not match demonstrated velocity and should not be treated as the cost.** The commit history shows 502 commits since 2026-03-31, running 9–39 commits/day; the entire v3.28 Folio redesign (14 sub-releases), the v3.29 social arc, and the v3.30 line all shipped in ~2 weeks (May 14–28), with 14 releases on 2026-05-27 alone. At that pace the v4 *build* is plausibly days-to-weeks of focused work, not months. **The binding constraint on v4 is not engineering time — it is the one-time production data cutover (SQLite→Postgres migration on a live, real-user database, irreversible if mishandled).** This reframes the whole decision: the question is not "can we afford months for v4" (we can't, and don't need to), it is "what de-risks the cutover, and what protects the data in the meantime."

Several things have changed under that framing in the last few days, which is why the timing deserves an explicit decision rather than a silent default:

1. **SQLite-on-Longhorn corruption has happened twice in two days** — cartarch ext4 (2026-05-28) and Grafana SQLite (2026-05-29). Root cause: a stateful-pod reschedule detaches/reattaches the Longhorn volume, and an unclean detach leaves the single-writer filesystem inconsistent; replica count does not protect against it. See `sqlite-longhorn-corruption-analysis-2026-05-29.md`. Grafana was made immune by going ephemeral; **cartarch's real user data cannot be — Postgres (crash-safe WAL) is the durable fix.**
2. **The in-cluster rename is deliberately deferred into v4.** The remaining `mana-archive` identifiers (K3s namespace, GHCR image path, ArgoCD Application name, and the `mana_archive.db` filename) are planned to be closed as a *parallel deploy under the new name + PVC data migration* — which is exactly the shape of the v4 cutover. v4 is the natural moment to finish the rename sweep.
3. **`cartarch-mcp` DB introspection is broken pending v4** — `run_query`/`describe_schema` point at the wrong DB path; the note says it "self-clears at the v4 rename."
4. **The platform foundation just got materially stronger:** Sealed Secrets adopted, all in-cluster secrets sealed, observability stack healthy and now scraping the app, Longhorn capacity wall resolved (40→100GB). The platform is in a good state to either harden further (Phase 4/5) or absorb a migration.

So the live question: **what is the next major investment — continued platform Phase 4/5 reliability/security work (and remaining v3 features), or starting the v4 Postgres cutover now?**

## Forces

**Pulling v4 forward:**
- It is the only *durable* fix for the cartarch corruption class (real user data).
- It closes three deferred threads at once (rename sweep, cartarch-mcp DB access, the multi-tenancy/commercial substrate).
- The product vision (shared games/binders/collections, event-sourced tracker) is blocked on it regardless.

**Holding v4 back:**
- The risk is the **production data cutover** (parallel deploy + SQLite→Postgres migration) against **real users on prod now** — irreversible if mishandled, so it must be sequenced and validated carefully, not rushed by a corruption scare. (Calendar size is *not* the blocker — at the demonstrated velocity the build is days-to-weeks, not months. The gate is cutover care on live data.)
- The corruption risk is **mitigable in the interim** at far lower cost: clean-shutdown SQLite handling (WAL checkpoint on SIGTERM, adequate `terminationGracePeriodSeconds`, `journal_mode` review), plus the existing 6h Longhorn backups and `docs/restore-runbook.md`. These shrink the urgency immediately, for hours of work.
- **Higher-immediate-ROI platform work is cheaper:** off-host backups + a real restore test (Phase 4) protect the actual data *whatever* v4's timing; Alertmanager receivers would have paged on the Grafana crashloop we found by hand. These are days of work, and they protect the data and the v4 cutover alike.
- Open v3 roadmap items (v3.27.9/11/13, the v3.29.x social arc) are unfinished; v4 freezes v3 feature delivery for its duration.

## Decision

**Hybrid — don't panic-start v4 on the corruption scare, but treat it as a near-term initiative (not a far-off epic): land the cheap data-protection first because it *also* de-risks the v4 cutover itself, then do v4 — which at the demonstrated velocity is weeks of work, not months.**

Concretely, in order:

1. **Immediately: interim SQLite hardening** (hours–days). Verify/implement WAL checkpoint + clean close on `SIGTERM`, sufficient grace period, and `journal_mode`/`synchronous` review for cartarch. Cheapest reduction of the corruption probability, and it protects the data during the v4 build itself.
2. **Next: off-host backups + an exercised restore test** — these protect the live data *and* are the safety net for the v4 cutover (a clean, restorable pre-migration copy is exactly what you want before a SQLite→Postgres switch). Add Alertmanager receivers here too so storage/crashloop alerts actually page.
3. **Then: v4 — soon.** At this velocity it is the realistic next major initiative, not a someday. Plan the cutover (parallel-deploy + data migration that also lands the in-cluster rename) deliberately; the engineering throughput is clearly there.

**Revisit trigger to pull v4 forward ahead of that order — any one of:**
- a third SQLite-on-Longhorn corruption incident (the interim hardening proved insufficient),
- first paying users onboarded (downtime/data-loss tolerance drops), or
- a conscious freeze of the v3 feature backlog (the opportunity cost of v4 disappears).

## Consequences

- **Accepted:** cartarch keeps running on SQLite for the near term, carrying a *mitigated* corruption risk rather than an eliminated one. This is a deliberate, time-boxed bet that interim hardening + backups hold until v4 lands properly.
- **Accepted:** the rename sweep, cartarch-mcp DB access, and multi-tenancy stay deferred — consistent with their existing "folds into v4" status.
- **Gained:** the data is protected immediately and cheaply (backups + alerting + hardening) rather than waiting on the migration, and v4 — close behind at this velocity — gets planned rather than panic-started.
- **Risk:** if corruption recurs before the interim hardening lands, the bet fails — hence trigger #1. The restore runbook is the backstop.

## References
- `sqlite-longhorn-corruption-analysis-2026-05-29.md` — root-cause analysis (the forcing function)
- `cartarch/roadmap.md` → *v4 Platform Migration* (scope of v4)
- `roadmap.md` → Resilience & Production-Readiness (off-host backups, recovery testing); *Pending Cross-Cutting Sweeps* (the in-cluster rename folded into v4)
- `docs/restore-runbook.md` — the reactive backstop while on SQLite

## Update — 2026-06-20 (status reconciliation)

Recording where this decision stands today so the ADR isn't read as still-pending. The
hybrid order above held; the data-protection and platform work landed, and v4 is now in
its final pre-cutover stretch.

- **App-side v4 readiness gates are done and shipped to prod (v3.39.9):** the Alembic
  baseline, the FK parent-delete enforcement harness (green on SQLite **and** PostgreSQL 18),
  and the app-side FK-safety work (pool config, `DATA_DIR` guard, leaf-first
  `storage_locations` delete). The prod FK-orphan sweep came back clean (0/0, in-pod, 06-19).
- **Backup/restore is no longer the open risk.** CNPG (operator 1.29.1) + the Barman-Cloud
  Plugin (v0.12.0) backing up to Cloudflare R2 and **restoring** is proven end-to-end and
  GitOps-codified on the green/Talos cluster (dedicated `cartarch-cnpg-backups` bucket).
  This **overturns** the earlier "Barman sidecar wall → consider VolumeSnapshot" caveat —
  the plugin path works.
- **Platform target changed:** the cutover lands on the new **Talos + vanilla-Kubernetes
  cluster** ("green"), not blue/K3s. See `clusters/talos/` and `clusters/talos/README.md`.
- **Migration tooling:** `pgloader` was retired in favour of a model-based scripted loader
  (`scripts/migrate_sqlite_to_pg.py` in the cartarch repo).
- **Remaining before the v4.0.0 cutover** (now a pure backend swap): stand up the *prod*
  CNPG cluster (`clusters/talos/manifests/cnpg-cartarch-prod/`) + prove a restore → a
  scripted SQLite→PostgreSQL rehearsal → a write-freeze cutover window (runbook: vault
  `cartarch/v4-cutover-runbook-2026-06-19.md`).
