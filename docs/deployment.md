# Deployment

> **Audience:** whoever stands this up. **Purpose:** infra, access, ports, config, and the
> isolation rules that keep a shared host from becoming a breach.

> ## ⚠ Nothing is deployed. There is no server, no host, no domain serving this.
>
> This document is **a plan, not a description**. No infrastructure has been provisioned.
> No hosting decision has been finalized. The only place this code has ever run is a
> browser opening a local file.
>
> The `app.credifyfast.com`, `portal.credifyfast.com`, and `track.credifyfast.com`
> references in `index.html` are **placeholder strings in seed data**. They are not
> deployed environments, and nothing resolves to this application.

## Current "deployment"

```
C:\xampp\htdocs\outreach-credify\index.html   ──▶  double-click  ──▶  browser
```

That's it. No web server is required — the app is a local file with no backend. XAMPP is
present on the maintainer's machine for other reasons and is **not part of this project**
([ADR-0002](adr/0002-node-express-postgres-backend.md)).

### ⚠ Isolation rules for the XAMPP host — these apply today

The repo lives inside `C:\xampp\htdocs\`, which is Apache's document root. If that Apache
is running, **every file under `htdocs` is served to anything that can reach the port** —
including sibling projects, stray exports, and backups.

That's fine for an inert prototype with fake data. It stops being fine the moment either
half of that sentence changes.

| Rule | Why |
| --- | --- |
| **Never put real client data anywhere under `htdocs`** | Not a CSV, not an export, not "just for one test." Apache will serve it to anyone who guesses the filename |
| **Never expose this Apache to a network** | Bind to localhost. It serves your whole `htdocs`, not just this project |
| **Never run production here** | Windows + XAMPP + shared docroot + no BAA. Every one of those is disqualifying on its own |
| **Assume anything in `htdocs` is public** | Treat it as a demo surface. If you wouldn't publish it, don't put it there |
| Keep `.env` out of `htdocs` | When one exists, it must live outside any document root. An `.env` in a docroot is a credential leak served over HTTP |

Production runs Node on its own host with nothing shared. The application server serves
the app; there is no document root full of unrelated files.

## Target infrastructure (⬜ not provisioned)

**No hosting provider has been selected.** The constraint that decides it is not price or
region — it's **who will sign a BAA** ([ADR-0007](adr/0007-baa-gated-vendor-selection.md)).

```
                    ┌──────────────┐
    users ─── TLS ─▶│ Load balancer│  443 only. HSTS. 80 redirects, never serves.
                    └──────┬───────┘
                           ▼
                    ┌──────────────┐
                    │ App (Node)   │  Next.js. Private subnet.
                    │ :3000        │  No public IP.
                    └──┬────────┬──┘
                       │        │
              ┌────────▼──┐  ┌──▼─────────────┐
              │ Postgres  │  │ Queue          │  scheduled + outbound
              │ :5432     │  │                │
              │ private   │  └──┬─────────────┘
              │ encrypted │     │
              └───────────┘     ▼
                          ┌──────────────┐
                          │ ESP / SMS    │  BAA required
                          └──────┬───────┘
                                 │ webhooks (signature-verified)
                                 ▼
                          back to the app
```

Requirements, regardless of provider:

| Requirement | Why |
| --- | --- |
| **BAA with the hosting provider** | PHI on their disks. Non-negotiable |
| Encryption at rest, volume level | Plus column encryption for `is_phi` values |
| Private networking for the DB | **Postgres never gets a public IP.** Ever |
| Managed KMS | Keys out of env vars |
| Automated encrypted backups | With a **tested** restore |
| Audit logging at the infra layer | Who touched the box |
| Single tenant | See [security-compliance.md](security-compliance.md#isolation) |

## Repo & access

| | |
| --- | --- |
| Canonical | [github.com/CredifyFast/outreach-credify](https://github.com/CredifyFast/outreach-credify) |
| Default branch | `main` |
| Visibility | Private (assumed — **verify**; a public repo of a PHI system's schema is its own risk) |
| Protection | ⬜ None configured. Phase 0 should require PR + green CI |

### Access model (⬜ not established)

| Principle | Rule |
| --- | --- |
| Least privilege | Prod DB access is break-glass, logged, time-boxed. Not a standing grant |
| Deploy keys | Read-only, per-environment, rotated. Never a personal PAT |
| No shared accounts | Every action traces to a person. This is a HIPAA access-control requirement, not a preference |
| Offboarding | Revoke on the last day. Sessions are server-side precisely so this is instant |
| MFA | Required on GitHub, hosting, ESP, and the DB |

**Nobody develops against production.** If a bug needs prod data to reproduce, that's a
logging and observability gap — fix that instead. "I'll just query prod quickly" is how
PHI ends up in a terminal scrollback, a screenshot, and a Slack thread.

## Ports

| Port | Service | Exposure | Notes |
| --- | --- | --- | --- |
| 443 | HTTPS | **Public** | The only public port |
| 80 | HTTP | Public | **301 to 443 only.** Never serves content |
| 3000 | Node / Next.js | **Private** | Behind the LB. No public binding |
| 5432 | Postgres | **Private** | App subnet only. Never public, never `0.0.0.0` |
| 80/443 | XAMPP Apache (local) | **localhost only** | Dev machine. Not production. See isolation rules |

## Serving model

| Layer | Approach |
| --- | --- |
| Static (`index.html`, `home.html`, fonts) | Served by the app or a CDN. No build step today |
| API | Same origin, `/api/*`. Same origin means the session cookie works and CORS stays off |
| Fonts | **Self-host before launch.** Today they load from `fonts.googleapis.com` — a third-party request from a PHI application, leaking referrer and adding an availability dependency for zero benefit |
| Uploads (`file`, `signature`, `photo_id` fields) | Private object storage. **Never** under a document root. Signed, expiring URLs only |

That last row matters more than it looks. The form engine accepts `photo_id` and
`income_doc` uploads. A misconfigured upload path that lands in a web-served directory
turns "we collected a driver's license" into "we published a driver's license."

## Deploy procedure (⬜ target)

**Manual and gated.** No auto-deploy to anything holding PHI. The seconds saved are not
worth an unreviewed change reaching patient data.

1. **Pre-flight** — CI green on `main`; migrations reviewed; rollback plan written;
   backup verified fresh.
2. **Announce** — who's deploying, what, expected impact.
3. **Backup** — snapshot the DB. Note the snapshot id.
4. **Migrate** — forward-only, in a transaction. Additive changes only during a rolling
   deploy; destructive ones need a maintenance window.
5. **Deploy** — rolling. Health check must pass before the next instance.
6. **Verify** — health endpoint, a real login, one send in a canary account, and check
   the audit log recorded it.
7. **Watch** — 30 minutes on error rate, queue depth, send failures.

**Rollback:** see [operations-runbook.md](operations-runbook.md#rollback). Roll back code
freely; **database rollbacks are usually the wrong move** — prefer a forward fix.

## Configuration reference

All config comes from the environment. **Names only below** — see
[.env.example](../.env.example). Values live in a secret manager, never in the repo, never
in a wiki, never in a Slack DM.

| Group | Variables | Notes |
| --- | --- | --- |
| Core | `NODE_ENV`, `PORT`, `APP_BASE_URL` | |
| Database | `DATABASE_URL`, `DATABASE_SSL`, `DATABASE_POOL_MAX` | SSL required in prod |
| Session | `SESSION_SECRET`, `SESSION_IDLE_TIMEOUT_MIN`, `SESSION_ABSOLUTE_TIMEOUT_H` | Rotating invalidates all sessions — that's a feature |
| Encryption | `KMS_KEY_ID`, `KMS_REGION` | Never a raw key in env |
| ESP | `ESP_PROVIDER`, `ESP_API_KEY`, `ESP_WEBHOOK_SECRET`, `ESP_FROM_DOMAIN` | **BAA required** |
| SMS | `SMS_PROVIDER`, `SMS_API_KEY`, `SMS_WEBHOOK_SECRET`, `SMS_FROM_NUMBER` | **BAA required** |
| Queue | `QUEUE_URL`, `QUEUE_CONCURRENCY` | |
| Links | `UNSUBSCRIBE_TOKEN_SECRET`, `TRACKING_BASE_URL` | Unsubscribe URLs are permanent — rotating this secret breaks links already in inboxes |
| Ops | `LOG_LEVEL`, `SENTRY_DSN` | **Every vendor here needs a BAA** |
| Flags | `FEATURE_SENDING_ENABLED`, `FEATURE_SMS_ENABLED` | The kill switch. Default **off** |

**`FEATURE_SENDING_ENABLED` defaults to off in every environment**, including production,
until [go-live](security-compliance.md#go-live-checklist) passes. It is also the incident
kill switch — flip it off and all outbound stops.

**`UNSUBSCRIBE_TOKEN_SECRET` deserves special care.** Unsubscribe links live in people's
inboxes forever. Rotating that secret breaks every link ever sent, which means someone who
tries to opt out silently fails to — a CAN-SPAM problem and a trust problem. If it must
rotate, support the old secret for verification indefinitely.

**Fail fast.** On boot, validate every required var and exit non-zero if any is missing.
A server that starts without `ESP_WEBHOOK_SECRET` and silently accepts unsigned webhooks
is worse than one that refuses to start.

## Related

- [operations-runbook.md](operations-runbook.md) — running it once it's up
- [security-compliance.md](security-compliance.md) — isolation, encryption, BAAs
- [.env.example](../.env.example) — every variable name
- [ADR-0002](adr/0002-node-express-postgres-backend.md) — why not XAMPP
