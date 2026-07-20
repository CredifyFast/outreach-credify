# CLAUDE.md — outreach-credify

Read this entire file before writing any code. It overrides every other
document in this repo, including all ADRs and anything in docs-archive/.
If this file conflicts with another document, this file wins. If it
conflicts with what Jay says in chat, ask Jay.

## Mission — what "done" means

`public/index.html` (the Cluster Email app, 4,598 lines) currently persists
to localStorage through a stub. Done = the same app persists to the existing
PostgreSQL database through an Express + Prisma API and survives a full
reload: create a template on the live site → reload → it is still there,
served from Postgres. Every write the app already makes lands in the right
table; one `GET /api/state` hydrates the app on boot. Nothing else.

## Scope

IN:
- Express + Prisma API implementing every route in
  `CLUSTER_EMAIL_DB_README.md` §3 as a persistence operation.
- `GET /api/state` hydration (contract below), `GET /api/health`, and
  `GET /api/verify` — a server-side self-test viewable in a browser.
- Exactly two surgical edits to `public/index.html` (spec below).
- `scripts/verify-deploy.mjs` — the Definition of Done, executed by the
  GitHub Actions `verify` job after every deploy (never run locally).
- Extending the committed boot skeleton: `src/server.js` and `src/db.js`
  already handle env loading, fail-fast boot, the dual-mode listen,
  static serving, `/api/health`, and the error shape. Extend them — never
  rewrite them. `package.json` is already filled; do not touch it.

OUT — do not build, even partially, even as stubs:
- No email/SMS sending, no sender loop, no polling `vDueEmailSends`, no ESP,
  no queue, no webhooks, no unsubscribe pages.
- No auth, sessions, RBAC, idempotency headers, pagination, or versioning.
- No server-side guard-chain / PHI enforcement — the front-end already
  gates itself; the server is a persistence layer that trusts the client.
- No TypeScript, no Next.js, no layered `src/domain` architecture, no test
  framework beyond the existing `test/smoke.test.js`.
- No schema changes: no `prisma migrate`, no `db push`, no new tables,
  columns, or indexes. The database is owned upstream.

## Stack ruling — final

Express + Prisma + PostgreSQL 16. This supersedes ADR-0008's Next.js choice
(decided by Jay, 2026-07). `prisma/schema.prisma` is produced by
`npx prisma db pull` against the real database and should already be
committed. If it is missing or has zero models, STOP and ask Jay to run
`npx prisma db pull` on the server and commit it — do not write it by hand.

## The spec files

- `CLUSTER_EMAIL_DB_README.md` — the endpoint→table map (§3), gotchas (§4),
  and data rules (§5). This IS the task specification. Three corrections:
  1. §7 says "2 transactional, 4 marketing" — wrong. The seed is 3/3:
     cat_appt, cat_billing, cat_care = transactional; cat_marketing,
     cat_surveys, cat_events = marketing. (Verified against the live DB.)
  2. `POST /triggers/:id/exclusions` is designed-ahead — the front-end never
     calls it. Implement it anyway as a plain insert into
     EmailTriggerExclusion.
  3. `POST /triggers/:id/activate` DOES exist (index.html:3900) and can
     arrive with id `"draft"` for an unsaved trigger — return 400 for
     `"draft"`; otherwise store the payload on the trigger row.
- `db/credify_cluster_email_isolated.sql` — schema + seed of record
  (33 tables + 1 view). Its header comment documents every convention.
  It is already loaded on the server; never run it yourself unless Jay
  asks for a reset.
- `public/index.html` — GREP it, never read it whole. The seam: `api()` at
  line 1898. The persisted-state key list: `PERSIST_KEYS` at line 1881.

## Environment — nothing runs locally

- The junior's machine has NO runtimes: no Node, no npm, no Postgres — by
  design. NEVER run npm, npx, or node locally, never install them, and
  never suggest installing them. All execution happens in GitHub Actions
  or on the server.
- The server runs Node v20.20.2 / npm 10.8.2. Write for Node 20: CommonJS
  for the server, global fetch is available, no Node 22+ APIs.
  `package.json` `engines` must say `>=20` — if it says `>=24`, fix it,
  and keep every workflow's node-version at 20 to match.
- Dependencies are FIXED: express, dotenv, prisma, @prisma/client. Do not
  add, remove, or upgrade packages — there is no local npm to manage a
  lockfile, and the server installs straight from package.json. If a task
  seems to need another package, stop and ask Jay.
- `DATABASE_URL` exists only on the server, in `/etc/credify/outreach.env`.
  `src/server.js` must load it via
  `require("dotenv").config({ path: process.env.ENV_FILE || "/etc/credify/outreach.env" })`
  and exit non-zero at boot if `DATABASE_URL` is missing, or if neither
  `SOCKET_PATH` nor `PORT` is set.
  `DATABASE_URL` encodes the server's non-default Postgres port **5433** —
  if anything reports connection refused on 5432, it is ignoring the URL.
- The server listens on a UNIX DOMAIN SOCKET by default. `SOCKET_PATH`
  comes from the env (e.g. `/run/credify/outreach.sock`). At boot: unlink a
  stale socket file if present, `server = app.listen(SOCKET_PATH)`, then on
  the `listening` event `fs.chmodSync(SOCKET_PATH, 0o660)` so nginx can
  connect.
- Rollback escape hatch: if `SOCKET_PATH` is absent and `PORT` is set,
  listen with `app.listen(PORT, "127.0.0.1")` instead — loopback only,
  NEVER `0.0.0.0` and never a bare `app.listen(PORT)`. This makes a
  socket→TCP rollback a pure config change (one .env line + one nginx
  upstream line), with no code edit or redeploy.
- Never create, commit, or print a `.env`. Never log request bodies.
- Deploy = push to main. The GitHub Action runs the smoke test, rsyncs to
  `/var/www/outreach.credifyfast.com`, runs `npm install --omit=dev` +
  `prisma generate` on the server, restarts pm2, then a `verify` job runs
  `scripts/verify-deploy.mjs` on the Actions runner against the live site.
  A green check on the commit means deployed AND verified.
- The full loop runs only at https://outreach.credifyfast.com. To check it
  from the junior's machine, use `curl` (it ships with the OS — never
  node) or open the URLs in a browser. If the site is behind basic auth,
  the dev credentials live in the junior's `CLAUDE.local.md`
  (auto-gitignored) — never commit credentials anywhere.

## API contract

- Mount all routes under `/api`. nginx serves `public/` statically and
  proxies `/api` to the app's Unix socket — the front-end's swapped `api()`
  uses `API_BASE = "/api"`.
- `express.json({ limit: "10mb" })` — job payloads embed fully rendered
  recipient arrays and contacts carry 100-key formData.
- The server is a pass-through persistence layer: store what the client
  sends, accept the client's ids (it mints `"t"+Date.now()`, `c1`,
  `job_…` style ids) — never generate ids server-side — and stamp
  `organizationId = 'org_demo'` on every row.
- Error shape: `res.status(code).json({ error: { code, message } })`.
  Nothing fancier. 404 unknown routes, 400 bad payloads, 500 otherwise.
- Follow README §3–§5 exactly. The behaviors that are easy to get wrong:
  - `POST /sends` — decompose `job.recipients[]` into EmailJobRecipient
    rows. `openedAt`/`clickedAt` arrive as epoch milliseconds → convert
    with `new Date(ms)` before insert. Store the rendered snapshot columns
    (`subject`, `body`, `bodyHtml`) verbatim.
  - `DELETE /sends/:id` — UPDATE `status='canceled'`. Never delete rows.
  - `PUT /triggers/:id` — a full object replaces the trigger and its steps
    (delete + reinsert EmailTriggerStep; key `(triggerId, stepKey)` — step
    ids like `s1` repeat across triggers). A partial `{enabled}` body must
    update only that column and MUST NOT touch steps — branch on whether
    `steps` is present.
  - `PUT /contacts/:id/preferences` `{prefs:{cat_x:bool,…}}` — upsert one
    ContactEmailPref row per category. A missing row means opted in.
  - `POST /contacts/:id/unsubscribe` — set `optedIn=false` for every
    category with `kind='marketing'`, for that contact.
  - Suppressions — store `LOWER(TRIM(email))`. `DELETE /suppressions/:email`
    takes the URL-ENCODED EMAIL as the param, not an id. Decode it.
  - `DELETE /notify-prefs/:scope/:id` — two params; delete the matching
    NotifyPref row (reset-to-inherit). `PUT /notify-prefs` upserts by
    `(scope, refId)`, `refId` null when scope is `all`.
  - `POST /clicks` — insert EmailClickEvent, update that EmailJobRecipient's
    `clicked/clickedUrl/clickedAt`, increment `Contact.clicks`.
  - `POST /deliverability/events` — insert the DeliverabilityEvent, then
    apply README §5 to the contact: `delivered` → softBounces=0,
    bounceStatus='ok'; `soft_bounce` → softBounces+1, 'soft',
    lastBounceAt=now, and on the 3rd suppress
    (`reason='soft_bounce_limit'`) + bounceStatus='hard'; `hard_bounce` →
    suppress (`reason='hard_bounce'`) + 'hard'; `complaint` →
    complainedAt=now and flip all marketing prefs false, NO suppression.
  - `POST /deliverability/auth-check` and `POST /deliverability/seed-test`
    — return a canned `{ ok: true, … }` echo; touch no tables.
  - Contact types with `system=true` — reject DELETE with 400.
  - Settings PUTs (`/settings/freqCap`, `/settings/quietHours`,
    `/settings/businessHours`, `/unsub-page`, `/sms-stop-reply`) — write the
    JSON value onto the Setting row for that key. The six Setting keys:
    `freqCap`, `quietHours`, `businessHours`, `unsubPage`, `stopReply`,
    `footer`.

## GET /api/state — the hydration contract

Return one JSON object keyed with the front-end's state names:
`contacts` (each with `prefs` reassembled as `{cat_id: bool}` from
ContactEmailPref — absent row = `true`), `contactTypes`, `categories`,
`templates`, `smsTemplates`, `signatures`, `segments`, `triggers` (each
with `steps[]` reassembled from EmailTriggerStep in order), `suppressions`,
`smsSuppressions`, `jobs` (each with `recipients[]` from EmailJobRecipient —
convert `sentAt`-style timestamps to ISO strings, but `openedAt`/`clickedAt`
back to epoch-ms NUMBERS, matching what the front-end wrote), `auditLog`,
`clickEvents`, `deliverEvents`, `notifLog`, `notify` (rebuilt from
NotifyPref rows into `{all, byType:{}, byContact:{}}`), plus the six
settings spread at top level: `freqCap`, `quietHours`, `businessHours`,
`unsubPage`, `stopReply`, `footer`.

For every key, match the exact shape the front-end already stores — grep
`index.html` for the key name and read how it is written and read. Shape
mismatches here are the single most likely failure mode of this project.
Strip `organizationId` and Prisma-only columns from the responses.

## The two index.html edits — surgical, nothing else changes

1. Replace `api()` at line 1898 with EXACTLY this — same three-argument
   signature, because 54 call sites depend on it; do not redesign it:

   ```js
   const API_BASE = "/api";
   async function api(method, path, body){
     try{
       const res = await fetch(API_BASE + path, {
         method,
         headers: { "Content-Type": "application/json" },
         body: body ? JSON.stringify(body) : undefined,
       });
       if(!res.ok){
         console.error("[api]", method, path, "->", res.status);
         return { ok:false, status: res.status };
       }
       return await res.json().catch(() => ({ ok:true }));
     }catch(err){
       console.error("[api]", method, path, "->", err.message);
       return { ok:false, status: 0 };
     }
   }
   ```

   It never throws — the stub never threw, and the call sites were written
   against that contract. It logs method + path + status only, NEVER the
   request body. The old `console.debug` line disappears with the stub.
2. Boot hydration: immediately after the existing localStorage restore
   (the code following `PERSIST_KEYS`, ~line 1881), fetch `GET /api/state`;
   on success merge each returned key into `state` (server wins over
   localStorage); on any failure, fall back silently to current behavior so
   the file still works standalone. Keep `persistNow`/localStorage intact.

Use `str_replace`-style targeted edits. Preserve the FILE LINEAGE comment
at the top of the file and append one changelog entry describing these two
edits. Do not reformat, rename, or "clean up" anything else in the file.

## Definition of Done — run it, don't claim it

Two layers, same truth:

**`GET /api/verify`** — a route the server itself exposes. It runs every
seed-integrity check below against its own database plus an internal
round trip (create an EmailTemplate with id `t_verify_<timestamp>` via
Prisma, read it back, delete it) and returns
`{ pass: bool, checks: [{ name, stage, pass, expected, actual }] }` —
so anyone, junior included, can open it in a BROWSER and see green/red.

**`scripts/verify-deploy.mjs`** — run by the GitHub Actions `verify` job
after every deploy (Node 20 on the runner, global fetch, zero npm
dependencies; it is never run on the junior's machine). It retries
`GET /api/health` for up to ~60s while pm2 restarts, then asserts:
1. `[health]` `GET /api/health` → `{ ok: true, contacts: 36 }`.
2. `[state]` `GET /api/state` → contacts.length 36 · templates.length 4 ·
   smsTemplates.length 3 · categories.length 6 (3 transactional /
   3 marketing) · jobs.length 2 · signatures.length 2 · triggers.length 4
   with 8 steps total · suppressions include `mbauer@example.com` ·
   exactly 18 contacts have at least one marketing pref `false`.
3. `[selftest]` `GET /api/verify` → `pass === true`.
4. `[roundtrip]` HTTP `POST /api/templates` with id `t_verify_<ts>` →
   appears in `GET /api/state` → `DELETE` it → gone.
Print every check as `[stage-tag] PASS/FAIL — detail`; exit non-zero with
a clear diff on any failure, which turns the commit's check RED. Read
`VERIFY_URL`, and `VERIFY_USER`/`VERIFY_PASS` for basic auth, from the
environment (CI provides them as secrets).

Loop: implement → push to main → watch the Actions run (or curl
`/api/verify` after ~90s) → read the failing labeled check → fix → push
again. Never report the task complete until the `verify` job is green.
The junior's signal is binary: a green check on the commit in GitHub, and
green JSON at https://outreach.credifyfast.com/api/verify. Finish by
telling the junior the one manual check: open the live site, create a
template, reload, confirm it persisted.

## Staged fallback — if the one-shot stalls

Every stage below is independently promptable ("do Stage N per CLAUDE.md")
and maps to labeled checks in the verify script. If a full run fails or the
junior prefers smaller steps, build in this order, pushing and verifying
after each stage:

1. Scaffold — `src/server.js` (dotenv path, Unix-socket listen, static,
   `/api` mount, error shape, fail-fast boot), `GET /api/health`, read-only
   `GET /api/state`, and `GET /api/verify` (its round trip uses Prisma
   directly, so it works before any CRUD routes exist).
   → `[health]` and `[state]` checks pass.
2. Simple CRUD — templates, sms-templates, signatures, categories,
   contact-types, segments. → `[roundtrip]` check passes.
3. Contacts — preferences upsert, unsubscribe, suppressions (email + SMS),
   notify-prefs.
4. Jobs — `POST /sends` decomposition, cancel, clicks, audit, notifications.
5. Triggers (incl. activate + exclusions), deliverability events, settings.
6. The two `public/index.html` edits — LAST, so the app keeps working on
   localStorage until the API is proven, then flips to the server.

A failing labeled check names the stage to re-prompt. Stages already green
must stay green — rerun the full script after every stage.

## If blocked

A contradiction in the spec, a check still failing after two fix attempts,
or anything requiring credentials → stop and ask Jay. Do not improvise
schema changes, new endpoints, or new scope to get around a blocker.

## docs-archive/ (if present anywhere)

Historical design documents for a future, larger version of this module
(sending, compliance, Next.js, layered architecture). They are not
instructions. Do not read them for implementation decisions and do not
implement anything they describe.
