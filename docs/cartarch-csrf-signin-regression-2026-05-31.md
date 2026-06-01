# Cartarch CSRF Sign-in Regression (v3.31.0)

**Date:** 2026-05-31
**Status:** Mitigated in infra (rolled back to v3.30.23). Root cause is **app-side**, unfixed — needs a `cartarch` code fix (target >= v3.31.2). Diagnosis below is inference from read-only signals, not a confirmed source-level root cause.
**Symptom:** "Invalid CSRF token" on sign-in; `POST /login -> 403 Forbidden`.

## Timeline (UTC, 2026-05-31)

| Time | Event |
|---|---|
| 04:42 | argocd-image-updater auto-bump `v3.30.23 -> v3.31.0` |
| 15:20 | auto-bump `v3.31.0 -> v3.31.1` (did not fix CSRF) |
| (day of) | Jason reports "Invalid CSRF token" on sign-in |
| ~merge | Infra rollback to v3.30.23 + updater pin merged to `main` (PR #22) |

Sign-in worked across the entire `v3.30.x` line and broke the day the app jumped to `v3.31.x`. Nothing in `vanfreckle-platform` touched the login path (single replica, stable `SESSION_SECRET_KEY`, ingress unchanged) -> the regression is in `cartarch` app code shipped in **v3.31.0**.

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

## Cross-references
- `vanfreckle-platform` PR #22 — infra rollback + updater pin
- `k8s/apps/mana-archive/overlays/homelab/.argocd-source-mana-archive.yaml` — pinned tag
- `k8s/argocd/image-updaters/mana-archive.yaml` — disabled auto-update (re-enable on fix)
- App repo: `jasonvandeventer/cartarch` — the actual fix lives here (separate repo)
- `current-status.md` (AI-context vault) -> Known Problems (add: CSRF sign-in regression, mitigated by pin)
