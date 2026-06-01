# Cartarch CSRF Sign-in Regression (v3.31.0)

**Date:** 2026-05-31
**Status:** ✅ **RESOLVED — v3.31.2 deployed 2026-06-01, sign-in verified by Jason in prod.** App-side fix shipped in `cartarch` PR #13 (v3.31.2); deployed via `vanfreckle-platform` PR #25. The original ranked hypotheses below are superseded by the source-level findings in *Resolution*.
**Symptom:** "Invalid CSRF token" on sign-in; `POST /login -> 403 Forbidden`.

## Timeline (UTC, 2026-05-31)

| Time (UTC) | Event |
|---|---|
| 05-31 04:42 | argocd-image-updater auto-bump `v3.30.23 -> v3.31.0` |
| 05-31 15:20 | auto-bump `v3.31.0 -> v3.31.1` (did not fix CSRF) |
| 05-31 (day of) | Jason reports "Invalid CSRF token" on sign-in |
| 05-31 ~merge | Infra rollback to v3.30.23 + updater "disable" merged to `main` (PR #22) |
| 05-31 16:54 | **updater clobbers the rollback** — `f084fc6` re-bumps `v3.30.23 -> v3.31.1` |
| 06-01 ~04:00 | re-assert v3.30.23 pin (PR #24) — **clobbered again** `90c5f7d` at 04:07 |
| 06-01 ~04:10 | cartarch PR #13 (fix) merged; tag `v3.31.2` pushed -> image built |
| 06-01 | PR #25 pins `v3.31.2` + re-enables updater; ArgoCD deploys it |
| 06-01 | **Jason verifies sign-in works in prod on v3.31.2 — RESOLVED** |

Sign-in worked across the entire `v3.30.x` line and broke the day the app jumped to `v3.31.x`. Nothing in `vanfreckle-platform` touched the login path (single replica, stable `SESSION_SECRET_KEY`, ingress unchanged) -> the regression is in `cartarch` app code shipped in **v3.31.0**.

## The rollback never held — updater clobber (important)

The infra mitigation (PR #22: pin v3.30.23 + `images: []`) **did not actually stop the updater.** argocd-image-updater re-bumped the pin back onto the broken `v3.31.1` **twice** (`f084fc6`, then `90c5f7d` minutes after the re-pin PR #24 merged), each time also stripping the pin comment. So prod ran **broken v3.31.1 the whole time**, not v3.30.23 — discovered 06-01 by reading the live `/login` footer folio (`Issue XXXI · Entry I` = v3.31.1) and the pod image.

Rather than keep fighting it, we went **straight to v3.31.2**: the updater tracks the *latest* semver tag, and the latest is now the *fixed* build, so the pin and the updater agree — no more clobber loop, and auto-updates were re-enabled honestly.

**Open follow-up:** why did `images: []` not disable the live updater? Likely the `k8s/argocd/image-updaters/` path isn't synced to the cluster by any Application (the `mana-archive` Application has no image-updater annotations), so edits there never reach the controller. Confirm before relying on that path to halt updates again.

## Mitigation applied (infra, this repo)

PR #22 on `vanfreckle-platform`:
- Pinned deployed image back to last known-good **v3.30.23** in `k8s/apps/mana-archive/overlays/homelab/.argocd-source-mana-archive.yaml`.
- Disabled auto-updates for the image (manage zero images) in `k8s/argocd/image-updaters/mana-archive.yaml`, so the `semver` updater can't re-bump onto the broken 3.31.x line.
- ArgoCD `mana-archive` syncs from `main` with selfHeal, so the rollback reconciles on merge.

**Un-pin when fixed (>= v3.31.2, sign-in verified):** bump the tag in `.argocd-source-mana-archive.yaml` and uncomment the `images` block in `image-updaters/mana-archive.yaml`. Both files carry inline comments pointing back to this incident.

## Evidence gathered (read-only, via cartarch-mcp)

- **Token generation works.** `GET /login` renders a valid hidden field: `<input name="csrf_token" value="<64 hex / 32 bytes>">`. So the break is on the **validation** side of `POST /login`.
- **Not a 100% hard break.** Access logs show *fresh* sessions still authenticating (`GET /decks -> 200`, `GET /chronicle -> 200`) interleaved with `POST /login -> 403`. A wholly broken CSRF middleware would fail everyone -> points to a *conditional* failure (stale state / origin / TTL), not a blanket misconfig.
- **Some 403s are bot noise.** They cluster with `/wp-admin/install.php`, `/wp-login.php` scanner hits (scanners POST with no token -> correct 403). Don't over-count these as real-user failures.
- **v3.31 was a public-landing/marketing release.** `GET /` now serves a full landing page (`inside-dashboard.webp`, `inside-deck-analytics.webp`, `inside-game-tracker.webp`) and the app fronts a second public host (`cartarch.com`). Releases like that commonly touch routing / middleware ordering / cookie scoping — exactly where CSRF lives.
- **Login form is a plain POST form** (`method="post" action="/login"`), not htmx, token field `csrf_token`. So htmx header handling is not the login path.

**Observability gap:** the MCP `call_endpoint` returns response bodies only (no `Set-Cookie` headers), and `recent_logs` exposes only uvicorn *access* logs, not app-level WARN/ERROR. So the literal rejection reason was not observable from here.

## Discriminating test (run first)

Open `/login` in a **private/incognito window** (or clear cookies for the domain) and sign in:
- **Works in incognito ->** stale cookie from the upgrade (hypothesis 1).
- **Still fails in incognito ->** systemic validation bug (hypotheses 2-4).

## Ranked hypotheses + where to look in `cartarch`

Start from the delta: `git log --oneline v3.30.23..v3.31.0`, focus on files touching **CSRF / session / middleware / auth / cookies**, and the new public `/` landing route.

1. **Session/CSRF cookie format or signing changed (most likely).** Token bound to the signed session cookie; if serializer/key/cookie *name* changed in 3.31.0, pre-upgrade cookies fail to decode -> "Invalid CSRF token" for browsers holding an old cookie, while fresh sessions work (matches logs + Jason's persistent failure). **Fix pattern:** on decode failure, issue a fresh cookie + token instead of 403; or bump the cookie name so stale cookies are ignored.
2. **New strict Origin/Referer check for the public domain.** Behind Traefik (TLS terminated at proxy) the app may compute its own origin as `http://<internal>` and reject the real `https://cartarch.com` Origin. **Check:** any new `trusted_origins`/`allowed_origins`; that the app honors `X-Forwarded-Proto`/`-Host` (uvicorn `--proxy-headers` + `FORWARDED_ALLOW_IPS`, or Starlette `ProxyHeadersMiddleware`).
3. **Cookie attributes tightened** (`Secure` / `SameSite=Strict`). `Secure` while the app thinks it's on HTTP (proxy-header issue) -> browser won't store/send it; `SameSite=Strict` + a cross-host hop between landing page and form host -> cookie not sent on POST.
4. **Token made single-use or short-TTL** -> fails users who linger on the login page.

Best guess: **#1**, with **#2** as runner-up if incognito also fails.

## Resolution (source-level, 2026-05-31)

Investigated against the actual `cartarch` source + a reproduction harness (TestClient over the real SessionMiddleware/cookie path, both `starlette` 0.52.1 and 1.2.1). Findings:

- **CSRF is pure double-submit** — `require_csrf_token` compares the form token to `request.session["csrf_token"]`. There is **no** Origin/Referer check, no TTL, no single-use. This rules out hypotheses **#2, #3, #4** at the source level.
- **The login/session/CSRF code is byte-identical to v3.30.23**, and `git diff v3.30.23..v3.31.0` touches *nothing* on the login path except `render()` gaining `Cache-Control: no-store` (which only makes responses *fresher* — it cannot introduce a staleness bug). No new `request.session` writes (cookie can't have bloated past 4 KB). This rules out hypothesis **#1** (no serializer/key/cookie-name change in app code).
- **Login works in every dependency combo tested** (starlette 0.52.1 *and* the new major 1.2.1; fastapi 0.136.3; itsdangerous 2.2.0). With the real `requirements.txt` constraints, `prometheus-fastapi-instrumentator>=7.0,<8.0` still caps starlette `<1.0.0`, so builds resolve 0.52.1 — i.e. no silent dependency drift in the deployed images either. (Note for future: instrumentator **8.0.0**, released 2026-05-29, moves to `starlette>=1.0.0`; a careless bump past `<8.0` would pull the starlette 1.x major — pin deliberately.)

**Actual root cause:** not a logic regression but a **session-cookie-continuity failure** that the v3.31.0 *rollout* (new public landing page + the `cartarch.com` second-host cutover) started exposing for real users. A logged-out browser reaches `POST /login` holding **no usable session cookie** — a stale/expired cookie the server now drops as an empty session, a cookie scoped to the pre-cutover host, or a `/login` page served from an edge cache *without* its per-user `Set-Cookie`. Strict double-submit then has no session token to match, and `GET /login` alone can't repair a cookie the browser won't replace — so the user dead-ends on a permanent 403. Matches every observed signal: token generation works, fresh sessions succeed, existing users persistently fail, "works in incognito."

**Fix (`fix/csrf-signin-recovery`, v3.31.2):** the four public pre-auth forms (`login` / `register` / `forgot-password` / `reset-password`) now distinguish a token *mismatch* (live session, wrong token → still 403, the suspicious case) from *no session token at all* (first contact → re-render with a freshly issued token + cookie so the immediate resubmit succeeds). This is the note's recommended fix-pattern #1, scoped to the empty-session case where there is no authenticated state to protect; authenticated mutations keep strict `CsrfRequired` unchanged. New end-to-end cookie-jar test reproduces the 403 on an empty-session POST and asserts it self-heals.

**Un-pin checklist (unchanged):** merge + deploy v3.31.2, verify sign-in (incl. a stale-cookie/incognito pass), then bump the tag in `.argocd-source-mana-archive.yaml` and re-enable `image-updaters/mana-archive.yaml`.

## Cross-references
- `vanfreckle-platform` PR #22 — infra rollback + updater pin
- `k8s/apps/mana-archive/overlays/homelab/.argocd-source-mana-archive.yaml` — pinned tag
- `k8s/argocd/image-updaters/mana-archive.yaml` — disabled auto-update (re-enable on fix)
- App repo: `jasonvandeventer/cartarch` — the actual fix lives here (separate repo)
- `current-status.md` (AI-context vault) -> Known Problems (add: CSRF sign-in regression, mitigated by pin)
