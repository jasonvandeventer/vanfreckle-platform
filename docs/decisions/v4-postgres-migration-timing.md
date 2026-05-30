# Decision: Timing of the v4 PostgreSQL Migration vs. Continued Platform Work

**Status:** Proposed
**Date:** 2026-05-29

## Context

The Cartarch app is at **v3.30.22** and has held a hard **"SQLite-until-v4"** invariant across 65 successive releases — every v3 release is zero-schema, zero-migration. **v4** is the PostgreSQL migration, framed in `cartarch/roadmap.md` not as a scaling chore but as the architectural unblock for the product vision (multi-writer durable state, event-sourced game tracker, multi-tenancy substrate, real concurrency). That same roadmap explicitly parks it: *"Likely a multi-month effort when it lands. Not the next thing; the right thing when timing aligns."*

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
- It is a **multi-month effort** against a product with **real users on prod now** — the cutover (parallel deploy + data migration) carries its own risk and must be done carefully, not rushed by a corruption scare.
- The corruption risk is **mitigable in the interim** at far lower cost: clean-shutdown SQLite handling (WAL checkpoint on SIGTERM, adequate `terminationGracePeriodSeconds`, `journal_mode` review), plus the existing 6h Longhorn backups and `docs/restore-runbook.md`. These shrink the urgency without committing months.
- **Higher-immediate-ROI platform work is cheaper:** off-host backups + a real restore test (Phase 4) protect the actual data *whatever* v4's timing; Alertmanager receivers would have paged on the Grafana crashloop we found by hand. These are days, not months.
- Open v3 roadmap items (v3.27.9/11/13, the v3.29.x social arc) are unfinished; v4 freezes v3 feature delivery for its duration.

## Decision (proposed)

**Hybrid — do not start the multi-month v4 yet; close the cheap, high-ROI resilience slice first, and formally schedule v4 as the next *major* initiative behind a concrete trigger.**

Concretely, in order:

1. **Immediately: interim SQLite hardening** (days). Verify/implement WAL checkpoint + clean close on `SIGTERM`, sufficient grace period, and `journal_mode`/`synchronous` review for cartarch. Cheapest reduction of the corruption probability.
2. **Next: the Phase-4 resilience slice that protects data regardless of v4** — off-host backups + an exercised restore test, and Alertmanager receivers so storage/crashloop alerts actually page. These are independently valuable and de-risk the wait.
3. **Then: v4 as the next major initiative,** planned properly (parallel-deploy + data-migration cutover that also lands the in-cluster rename), not triggered reactively.

**Revisit trigger to pull v4 forward ahead of that order — any one of:**
- a third SQLite-on-Longhorn corruption incident (the interim hardening proved insufficient),
- first paying users onboarded (downtime/data-loss tolerance drops), or
- a conscious freeze of the v3 feature backlog (the opportunity cost of v4 disappears).

## Consequences

- **Accepted:** cartarch keeps running on SQLite for the near term, carrying a *mitigated* corruption risk rather than an eliminated one. This is a deliberate, time-boxed bet that interim hardening + backups hold until v4 lands properly.
- **Accepted:** the rename sweep, cartarch-mcp DB access, and multi-tenancy stay deferred — consistent with their existing "folds into v4" status.
- **Gained:** the data is protected sooner and more cheaply (backups + alerting + hardening) than a months-long migration would, and v4 gets planned rather than panic-started.
- **Risk:** if corruption recurs before the interim hardening lands, the bet fails — hence trigger #1. The restore runbook is the backstop.

## References
- `sqlite-longhorn-corruption-analysis-2026-05-29.md` — root-cause analysis (the forcing function)
- `cartarch/roadmap.md` → *v4 Platform Migration* (scope of v4)
- `roadmap.md` → Resilience & Production-Readiness (off-host backups, recovery testing); *Pending Cross-Cutting Sweeps* (the in-cluster rename folded into v4)
- `docs/restore-runbook.md` — the reactive backstop while on SQLite
