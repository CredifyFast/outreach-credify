# outreach-credify — Cluster Email

Single-file front-end (`public/index.html`) backed by an Express + Prisma
API persisting to an existing PostgreSQL database.
Live at https://outreach.credifyfast.com.

## Start here

**Humans and AI agents: read [`CLAUDE.md`](CLAUDE.md) first.** It is the
authoritative contract for scope, stack, environment, and definition of
done, and it overrides every other document in this repository.

The task specification is
[`CLUSTER_EMAIL_DB_README.md`](CLUSTER_EMAIL_DB_README.md) — the
endpoint→table map. The schema + seed of record is
[`db/credify_cluster_email_isolated.sql`](db/credify_cluster_email_isolated.sql),
already loaded on the server.

## How work happens

Nothing runs on a local machine — no Node, no npm, no Postgres, by design.
The loop:

1. Edit → push to `main`.
2. GitHub Actions runs the smoke test, deploys to the server over SSH,
   then verifies the live site.
3. Done = a green check on the commit **and** green JSON at
   [`/api/verify`](https://outreach.credifyfast.com/api/verify).

Quick health check:
[`/api/health`](https://outreach.credifyfast.com/api/health) →
`{"ok":true,"contacts":36}`.

## Repo map

| Path | What it is |
|---|---|
| `public/` | The app (`index.html`) + landing page — the only web-served folder |
| `src/` | Express server: `server.js` (boot skeleton — extend, don't rewrite) · `db.js` (Prisma client) |
| `prisma/schema.prisma` | Introspected from the live DB via `db pull` — never `migrate` |
| `db/` | Schema + seed of record |
| `scripts/` | `verify-deploy.mjs`, run by CI after every deploy |
| `test/` | Smoke test, run by CI on every push |
| `.github/workflows/` | `ci.yml` (tests) · `deploy.yml` (deploy + verify) |

Server configuration lives at `/etc/credify/outreach.env` on the server —
never in this repo. [`.env.example`](.env.example) documents the variable
names only.

Full design history for the future, larger version of this module lives on
the `docs-full` branch. It is background, not instructions for the current
build.