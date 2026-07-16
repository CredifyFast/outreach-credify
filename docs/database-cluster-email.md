# Cluster Email — Isolated Database (Junior Dev Guide)

> **Audience:** whoever builds the Cluster Email backend. **Purpose:** the isolated
> Postgres schema, its seed, and the endpoint→table map to code against.
>
> | | |
> | --- | --- |
> | **Ret by** | **Taras** |
> | Source | `OneDrive/Documents/CredifyFast/CLUSTER_EMAIL_DB_README.md` |
> | Received | 2026-07-16 · added to this doc set unmodified |
> | Status | 🟡 **Reviewed — accurate, with 3 corrections.** See [Reconciliation](#reconciliation--reviewers-appendix) |
>
> **Everything from here to §9 is Taras's text, verbatim.** Do not edit it in place — it
> is a received artifact. Corrections live in the
> [reviewer's appendix](#reconciliation--reviewers-appendix) at the bottom, and the
> upstream copy should be fixed by Taras rather than patched here.
>
> ⚠ **Two things to know before you follow this guide:**
> 1. **The SQL file it documents is not in this repo, and was not delivered with it.**
>    `credify_cluster_email_isolated.sql` is referenced throughout but could not be
>    located anywhere on this machine — the §1 quick start will fail until Taras sends it.
> 2. **§7's "2 transactional, 4 marketing" is wrong — the app seeds 3 and 3.** That split
>    decides who gets excluded at queue time. Read
>    [C-1](#c-1--category-kind-split-is-33-not-24-material) before loading any seed.

**Files:** `credify_cluster_email_isolated.sql` (schema + seed, one file) · this README
**Serves:** `CLUSTER_EMAIL_07-10-26_0510PM-PDT_SUMM-LINKS_SUPPORT.html`
**Generated:** 2026-07-15 (PDT) · PostgreSQL 16 · verified end-to-end on 16.14

This is a standalone database for the Cluster Email module only. You build and
test a real backend against it without touching the unified Credify schema.
When the module is proven, the tables move into `credify_unified_schema.sql`
following the **MERGE MAP** comment at the top of the SQL file — the names and
conventions already match, so the merge is mostly a lift.

---

## 1. Quick start

```bash
createdb credify_cluster_email
psql -d credify_cluster_email -f credify_cluster_email_isolated.sql
```

That's it. You now have 33 tables + 1 view, loaded with the exact demo data
the HTML file seeds itself with on first load (see §6). To reset at any time:

```bash
dropdb credify_cluster_email && createdb credify_cluster_email
psql -d credify_cluster_email -f credify_cluster_email_isolated.sql
```

Sanity check after loading:

```sql
SELECT count(*) FROM "Contact";        -- 36
SELECT count(*) FROM "EmailJob";       -- 2
SELECT count(*) FROM "vDueEmailSends"; -- 0 (both demo jobs already sent)
```

## 2. The one seam you code against

The front-end funnels **every** write through a single function, `api(method,
path, body)` (≈ line 1898 of the HTML). Today it's a stub that logs and
persists to localStorage. Your backend replaces that stub: change `api()` to
`fetch` your Express server, and implement the routes below. Nothing else in
the 6,000-line file needs to change.

The front-end **mints its own ids** (`"t" + Date.now()`, `c1`, `job_…`) and
sends them up — accept client ids, don't generate new ones. All tables carry
`"organizationId"`; hardcode `'org_demo'` server-side for now (the seeded org).

## 3. Endpoint → table map

Every call the HTML actually makes today, verified against the file. Bodies
are the front-end's state objects verbatim unless noted.

| Call | What it means | Tables touched |
|---|---|---|
| `POST /sends` | Queue a job (recipients embedded, fully rendered) | `EmailJob` + `EmailJobRecipient` (decompose `job.recipients[]`) |
| `DELETE /sends/:id` | **Cancel**, not delete → set `status='canceled'` | `EmailJob` |
| `POST /templates` / `PUT /templates/:id` | Create / update email template | `EmailTemplate` |
| `DELETE /templates/:id` | Delete template (queued jobs unaffected — they hold snapshots) | `EmailTemplate` |
| `POST /sms-templates` / `DELETE /sms-templates/:id` | SMS templates | `SmsTemplate` |
| `POST /categories` / `PUT /categories/:id` / `DELETE /categories/:id` | Preference categories | `EmailPrefCategory` |
| `POST /contact-types` / `PUT /contact-types/:id` / `DELETE /contact-types/:id` | Contact types (`system=true` rows are undeletable in the UI — enforce server-side too) | `ContactType` |
| `PUT /contacts/:id/preferences` `{prefs:{cat_x:bool,…}}` | Upsert the contact's whole pref set | `ContactEmailPref` (row per category) |
| `POST /contacts/:id/unsubscribe` `{scope:'marketing'}` | One-click unsub → flip all **marketing** categories false | `ContactEmailPref` |
| `POST /suppressions` `{email, reason}` | Add to kill-list (normalize: `LOWER(TRIM(email))`) | `EmailSuppression` |
| `DELETE /suppressions/:email` | ⚠️ Param is the **URL-encoded email**, not an id | `EmailSuppression` |
| `POST /sms-suppressions` / `DELETE /sms-suppressions/:id` | SMS STOP list | `SmsSuppression` |
| `POST /signatures` / `PUT /signatures/:id` / `DELETE /signatures/:id` | Signatures | `EmailSignature` |
| `POST /segments` / `PUT /segments/:id` / `DELETE /segments/:id` | Saved audiences (store `groups` JSON verbatim) | `Segment` |
| `POST /triggers` / `PUT /triggers/:id` | ⚠️ Whole trigger object incl. `steps[]` — decompose into step rows | `EmailTrigger` + `EmailTriggerStep` |
| `PUT /triggers/:id` `{enabled}` | Enable/disable toggle (partial body) | `EmailTrigger` |
| `DELETE /triggers/:id` | Delete (steps cascade) | `EmailTrigger` |
| `POST /triggers/:id/exclusions` | Goal met → permanently exclude contact | `EmailTriggerExclusion` |
| `POST /clicks` | Tracked link click | `EmailClickEvent` + update `EmailJobRecipient.clicked/clickedUrl/clickedAt` + `Contact.clicks` |
| `POST /audit` | Audit entry (`type`: send/open/click) | `EmailAuditLog` |
| `POST /deliverability/events` | ESP webhook sim — run the classifier rules (§5) | `DeliverabilityEvent` + `Contact` + maybe `EmailSuppression`/`ContactEmailPref` |
| `POST /deliverability/auth-check` `{domain}` | SPF/DKIM/DMARC check — fine to echo a canned result for now | — |
| `POST /deliverability/seed-test` | Inbox-placement seed test — canned result fine | — |
| `POST /notifications` | Fired open-notification | `EmailNotifLog` |
| `PUT /notify-prefs` `{scope,id,channel}` | Upsert (`scope`: all/type/contact; `id`→`refId`, null for all) | `NotifyPref` |
| `DELETE /notify-prefs/:scope/:id` | Reset to inherit → delete the row | `NotifyPref` |
| `PUT /settings/freqCap` · `/settings/quietHours` · `/settings/businessHours` | Replace the JSON value | `Setting` (that key) |
| `PUT /unsub-page` | Unsub confirmation email copy | `Setting` key `unsubPage` |
| `PUT /sms-stop-reply` | STOP auto-reply text | `Setting` key `stopReply` |

**GETs to add** (the HTML hydrates from localStorage today; for a real
backend, add one bulk `GET /state` — or per-resource GETs — returning each
table shaped like the front-end state: contacts with `prefs` reassembled from
`ContactEmailPref`, triggers with `steps[]` reassembled from
`EmailTriggerStep`, settings as `{freqCap, quietHours, …}` from `Setting`).

## 4. Gotchas that will bite you

1. **Epoch milliseconds.** `EmailJobRecipient.openedAt` / `clickedAt` arrive
   from the front-end as numbers (epoch ms). Convert before insert:
   `new Date(ms).toISOString()`. Everything else is already ISO-8601.
2. **Jobs are immutable once queued.** The front-end resolves merge tags,
   picks EN/ES per contact, renders HTML blocks, and computes each
   recipient's `sendAt` (quiet/business hours in the *contact's* time zone)
   at queue time. Never re-render from the template on send — send the
   snapshot columns (`subject`, `body`, `bodyHtml`).
3. **Suppression normalizes.** Always compare `LOWER(TRIM(email))`. The
   unique index is on `(organizationId, email)` — store it normalized.
4. **`DELETE /suppressions/:email`** — route param is the encoded email.
5. **Missing pref row = opted in.** `defaultPrefs()` opts everyone into
   everything; treat absent `ContactEmailPref` rows as `optedIn=true`.
6. **Triggers round-trip whole.** `PUT /triggers/:id` sends the full object
   with `steps[]`; delete-and-reinsert the step rows (keyed
   `(triggerId, stepKey)` — step ids `s1, s2…` repeat across triggers).
7. **Cancel ≠ delete.** `DELETE /sends/:id` flips `status='canceled'`. Rows
   stay for the audit trail.

## 5. Business rules the backend must enforce

These live in the front-end today (`classifyDeliverEvent()`,
`clusterRecipients()`); the server is the real enforcement point.

- **At queue time** exclude: suppressed emails; contacts opted out of the
  job's category **when the category is `kind='marketing'`** (transactional
  ignores opt-outs); hard-bounced contacts (`bounceStatus='hard'`).
- **Deliverability events** (`POST /deliverability/events`):
  - `delivered` → reset `Contact.softBounces=0`, `bounceStatus='ok'`.
  - `soft_bounce` → `softBounces+1`, `bounceStatus='soft'`,
    `lastBounceAt=now`; at **3** → suppress (`reason='soft_bounce_limit'`),
    `bounceStatus='hard'`.
  - `hard_bounce` → suppress immediately (`reason='hard_bounce'`),
    `bounceStatus='hard'`.
  - `complaint` → `complainedAt=now`, flip every **marketing** pref to
    false. Do **not** suppress — transactional still allowed.
- **Frequency cap / quiet hours / business hours** come from `Setting`;
  triggers may carry per-trigger overrides (`freqCapOverride`,
  `quietHoursOverride`).

## 6. The sender loop (your first real feature)

The view does the hard part:

```sql
SELECT * FROM "vDueEmailSends";  -- due, queued, unsuppressed recipients
```

Poll it every minute. For each row: hand to your ESP (or `console.log` in
dev), then stamp the recipient:

```sql
UPDATE "EmailJobRecipient"
SET "sentAt"=CURRENT_TIMESTAMP, "sendStatus"='sent', "providerMessageId"=$1
WHERE "id"=$2;
```

When a job has no unsent recipients left, mark it done:

```sql
UPDATE "EmailJob" j SET "status"='sent'
WHERE j."id"=$1 AND j."status"='queued'
  AND NOT EXISTS (SELECT 1 FROM "EmailJobRecipient" r
                  WHERE r."jobId"=j."id" AND r."sentAt" IS NULL);
```

`providerMessageId` / `sendStatus` / `sentAt` are already on the table
(nullable) so wiring SES/SendGrid/Postmark later needs no migration.

## 7. What's in the seed

Generated by executing the HTML's **own seed functions** headlessly and
dumping the resulting state — so the DB matches the app's first load exactly:

- 36 contacts (`c1…c36`) with full CRM axes, engagement counters, 24-hour
  open histograms, and 100-key `formData` for merge tags.
- 6 preference categories (2 transactional, 4 marketing) · 216 pref rows.
  **18 contacts** are opted out of ≥1 marketing category (the Preferences
  tab badge).
- 4 email templates (incl. the bilingual HTML-blocks one), 3 SMS templates,
  2 signatures, 4 triggers (8 steps), 5 forms × 20 fields.
- 2 already-**sent** demo jobs: `job_seed1` (4 recipients / 3 opens /
  2 clicks), `job_seed2` (3 / 2 / 1) — with rendered snapshots, RFC 8058
  unsub headers, and simulated ESP stamps.
- 4 deliverability events, and their consequences already applied: `c8`
  (`mbauer@example.com`) hard-bounced → in `EmailSuppression`,
  `bounceStatus='hard'`; `c11` complained → marketing prefs off.
- 15 audit entries, 3 click events, 1 notify pref (`all=off`), 6 settings.

## 8. Merging into the unified schema later

Read the **MERGE MAP** header in the SQL file — it lists, table by table,
what's a throwaway mini (drop it, point at the real unified table), what
lands as-is (all `Email*` tables), and the three judgment calls
(`SmsTemplate`→`NotifTemplate`?, `EmailAuditLog`→`AuditEvent`?, `Setting`
rows→`OrgSetting`). Two conventions were relaxed here on purpose and must be
restored at merge: **RLS/org-scoping policies** (omitted) and
`updatedAt` **defaults** (added for raw-SQL friendliness; Prisma owns
`updatedAt` in unified).

## 9. Acceptance checklist (already passing — rerun anytime)

| Check | Expected |
|---|---|
| Full file runs on a fresh DB with `-v ON_ERROR_STOP=1` | ends in `COMMIT`, zero errors |
| `SELECT count(*) FROM "Contact"` | 36 |
| Recipients/opens/clicks per job | `job_seed1` 4/3/2 · `job_seed2` 3/2/1 |
| Marketing opt-out badge query (§7) | 18 contacts |
| `c8` suppressed + `bounceStatus='hard'` | true |
| `vDueEmailSends` on fresh seed | 0 rows |
| Insert queued job w/ past `sendAt` → view | 1 row; suppress its email → 0 rows |
| Duplicate suppression / duplicate pref / recipient w/ bad contactId | all rejected by constraints |

---

# Reconciliation — reviewer's appendix

> **Added by the doc set, 2026-07-16. Not Taras's text.** Everything above this line is
> his, unmodified.

This section reconciles Taras's guide against `index.html` (md5 `7c02a77a…`, 4,598 lines)
and against [data-model.md](data-model.md) / [api-design.md](api-design.md), which were
written a day later **without knowledge that this database existed**.

## Verdict

**The guide is accurate and this schema should be adopted.** Taras's seed claims were
checked against the HTML's own seed logic and they hold — including numbers that are
hard to get right by accident. Where his document and mine disagree, **his is usually
right and mine is wrong**, because he read the concatenated route expressions properly
and I regex-matched only their first string literal.

Three corrections below (C-1 material, C-2/C-3 minor), plus what this discovery breaks in
my docs.

## What was verified against `index.html`

Every claim re-derived from the file. ✅ = re-computed and matched.

| Taras's claim | Result | How checked |
| --- | --- | --- |
| `api()` at ≈ line 1898 | ✅ exact | `index.html:1898` |
| 36 contacts, `c1…c36` | ✅ | `makeContacts()` loops `i<36`, ids `"c"+(i+1)` |
| 216 pref rows | ✅ | 36 × 6 categories |
| **18 contacts opted out of ≥1 marketing category** | ✅ **exact** | Replayed the seed: `i%4→cat_marketing`, `i%5→cat_events`, `i%7→cat_surveys` over `i=0..35`; union = 18 |
| 4 email templates (incl. bilingual HTML) | ✅ | Bracket-matched `SEED_TEMPLATES` → 4 (`Intro / Welcome`, `Balance Reminder`, `Partner Check-In`, `Welcome (HTML)`) |
| 3 SMS templates · 2 signatures | ✅ | `SEED_SMS_TEMPLATES`, `SEED_SIGNATURES` |
| 6 preference categories | ✅ | `SEED_CATEGORIES` |
| **4 triggers, 8 steps** | ✅ | `state.triggers` is reassigned at `index.html:1969`; step ids `s1,s2,s3 / s1,s2 / s1 / s1,s2` |
| **Step ids repeat across triggers** (gotcha 6) | ✅ | Confirms the `(triggerId, stepKey)` composite key |
| 5 forms × 20 fields = 100-key `formData` | ✅ | `mkForm()` × `TYPE_ORDER` |
| **Missing pref row = opted in** (gotcha 5) | ✅ | `defaultPrefs()` sets every category `true` |
| **Epoch ms** on `openedAt`/`clickedAt` (gotcha 1) | ✅ | `r.openedAt=Date.now()`, `r.clickedAt=Date.now()` |
| **Cancel ≠ delete** (gotcha 7) | ✅ | `j.status="canceled"; api("DELETE","/sends/"+j.id)` |
| `DELETE /suppressions/:email` is a **URL-encoded email** (gotcha 4) | ✅ | `api("DELETE","/suppressions/"+encodeURIComponent(e))` |
| `DELETE /notify-prefs/:scope/:id` | ✅ | `api("DELETE","/notify-prefs/"+scope+"/"+id)` |
| `PUT /contacts/:id/preferences` | ✅ | `api("PUT","/contacts/"+c.id+"/preferences",…)` |
| `POST /contacts/:id/unsubscribe` | ✅ | exists |
| Job snapshots (`subject`/`body`/`bodyHtml`) | ✅ | `bodyHtml` present |

The **18** is the strongest evidence the seed really was generated by executing the app's
own functions headlessly, as §7 claims. It's an inclusion–exclusion count over three
moduli — not a number you land on by hand.

## Corrections

### C-1 · Category kind split is 3/3, not 2/4 (**material**)

§7 says *"6 preference categories (2 transactional, 4 marketing)."* The app seeds **3
transactional and 3 marketing**:

| Category | `kind` in `index.html` |
| --- | --- |
| `cat_appt` — Appointment reminders | `transactional` |
| `cat_billing` — Billing & statements | `transactional` |
| `cat_care` — Care & clinical updates | `transactional` |
| `cat_marketing` — Newsletters & marketing | `marketing` |
| `cat_surveys` — Surveys & feedback | `marketing` |
| `cat_events` — Events & workshops | `marketing` |

**Why this matters rather than being a typo.** §5's queue-time rule keys on exactly this
field: *"contacts opted out of the job's category when the category is `kind='marketing'`
(transactional ignores opt-outs)."* So `kind` decides whether an opt-out is honored.

The direction of the error decides its severity:

- If the SQL seeds a category as **marketing** that the app treats as transactional →
  fail-safe. You over-exclude. Annoying, not harmful.
- If the SQL seeds a category as **transactional** that the app treats as marketing →
  **fail-open. Marketing mail goes to people who opted out of it.** That's a consent
  violation and, in this domain, a P1 ([operations-runbook.md](operations-runbook.md#incident-severities)).

The likeliest reading is that the *data* is right and only the prose miscounts — the
opt-out spread touches exactly `cat_marketing`, `cat_surveys`, `cat_events`, and the 18
count only works if those three are the marketing ones. But **verify before trusting it**:

```sql
SELECT "id","label","kind" FROM "EmailPrefCategory" ORDER BY "id";
-- expect: cat_appt, cat_billing, cat_care = transactional
--         cat_marketing, cat_surveys, cat_events = marketing
```

### C-2 · `POST /triggers/:id/exclusions` does not exist

The §3 map lists it as a call "the HTML actually makes today, verified against the file."
It doesn't. `grep -c exclusions index.html` → **0**.

Trigger exclusions live only in `state.trigExcluded[triggerId]`, a client-side `Set` that
is never sent through `api()`. The `EmailTriggerExclusion` table is still the right
destination — but **no endpoint feeds it yet**, so the route has to be designed, not
just implemented.

**Latent bug worth fixing while you're there:** `trigExcluded` is in `PERSIST_KEYS`
(`index.html:1881`) and holds `Set` objects. `JSON.stringify(new Set(["c1"]))` → `{}`.
So exclusions are silently lost on reload, and after hydration
`state.trigExcluded[t.id] || new Set()` returns a truthy `{}` whose `.has()` is
undefined — a `TypeError` waiting on the first trigger evaluation. Currently masked
because "+ New Trigger" is disabled. Serialize as an array.

### C-3 · Route missing from the map: `POST /triggers/:id/activate`

`index.html:3900` — `api("POST","/triggers/"+(t.id||"draft")+"/activate", {enrolled, steps, goals…})`.
Note the `"draft"` fallback: an unsaved trigger posts to `/triggers/draft/activate`.
The backend needs to reject or special-case that.

### C-4 · "the 6,000-line file" → 4,598 lines

Cosmetic. `index.html` is 4,598 lines.

## Where this contradicts my docs — **my errors**

Taras read the code more carefully than my extraction did. My route inventory regex
(`api\("METHOD","([^"]+)"`) captured only the **first string literal** of each path, so
every concatenated route came out truncated.

| My doc said | Actually | Verdict |
| --- | --- | --- |
| `PUT /contacts/{id}/prefs` | `PUT /contacts/{id}/**preferences**` | ❌ mine wrong |
| `DELETE /suppressions/{id}` | `DELETE /suppressions/{**url-encoded email**}` | ❌ mine wrong |
| `DELETE /notify-prefs/{id}` | `DELETE /notify-prefs/{**scope**}/{id}` | ❌ mine wrong |
| *(missing)* | `POST /contacts/{id}/unsubscribe` | ❌ mine missed it |
| *(missing)* | `POST /triggers/{id}/activate` | ❌ mine missed it |
| "`POST /triggers/{id}` is inconsistent — should be `PUT`" | It's `/triggers/{id}/**activate**`, a legitimate action route | ❌ **my "design bug" was not a bug** |
| Templates: `3 / 3` | **4** email / 3 SMS | ❌ mine wrong |

[api-design.md](api-design.md) and [data-model.md](data-model.md) have been corrected.

## Where this contradicts my docs — **architectural**

Bigger than the route typos. My [ADR-0002](adr/0002-node-express-postgres-backend.md) and
[data-model.md](data-model.md) were written from the repo alone, and the repo does not
contain — or mention — `credify_unified_schema.sql`. It exists: **105 tables, 319
indexes, 100 RLS policies, verified on PostgreSQL 16.14.**

| My doc assumed | The unified schema actually does |
| --- | --- |
| Node + **Express** | **Next.js + Prisma**, API at `chrome.credifyfast.com/api` |
| Plain SQL migrations, "no ORM auto-migration" | **Prisma owns the schema** |
| `snake_case` plural tables (`job_recipients`) | **Quoted CamelCase** (`"EmailJobRecipient"`) |
| `uuid` PKs, `gen_random_uuid()` server-side | **TEXT cuid PKs minted app-side** — 0 uses of `gen_random_uuid` |
| `timestamptz` | **`TIMESTAMP(3)`** |
| Single-tenant per deployment | **Multi-tenant**: `organizationId` + RLS on `app.current_org` |
| "No encryption at rest exists" | **AES-256-GCM envelopes** (`*Enc BYTEA` + `*Iv`/`*Tag`) |
| Audit log ⬜ not started | Append-only audit **already smoke-tested** |

**Taras's conventions are right and mine were wrong** — not on the merits, but on the
only thing that matters here: his match the schema this module has to merge into. A
module that arrives with `snake_case` and `gen_random_uuid()` would have to be rewritten
at merge time.

This is recorded as [ADR-0008](adr/0008-align-with-unified-credify-schema.md), which
supersedes the stack portion of ADR-0002. Per
[ADR-0001](adr/0001-record-architecture-decisions.md), accepted ADRs are immutable — 0002
stays as written, with its error preserved.

## Where my docs still add something

Not everything transfers. Two gaps in the isolated schema are worth closing before it
merges:

1. **No PHI classification.** The guide never mentions PHI, and PHI is in scope for this
   module — `contacts.formData` carries `ssn`, `dob`, `photo_id`, `home_address`,
   `tax_id`. [data-model.md](data-model.md) proposes `form_fields.is_phi DEFAULT true` +
   `mergeable DEFAULT false` (an allowlist), and
   [ADR-0005](adr/0005-phi-minimization-in-outreach.md) proposes blocking PHI in outbound
   bodies outright. The unified schema's AES-256-GCM envelopes are the mechanism; the
   classification still has to exist.
2. **The guard chain is only half covered.** §5 documents suppression, marketing opt-out,
   and hard-bounce exclusion — genuinely richer than my write-up, and the bounce
   classifier (soft ×3 → suppress; complaint → marketing off, no suppress) is detail I
   didn't have. But it omits the **PHI acknowledgment, discharged-contact
   acknowledgment, and frequency-cap acknowledgment** guards from `doQueueSend()`. All
   three must be enforced server-side
   ([ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md)).

Also worth flagging: **§3's `POST /audit` is client-driven.** A client that can skip the
call can act unaudited. Keep the route for UI telemetry, but the server must write audit
entries itself, in the same transaction as the action.

## Open questions for Taras

1. **Where is `credify_cluster_email_isolated.sql`?** Not in OneDrive, not on this
   machine. Nothing in §1 can run without it.
2. **Is `EmailPrefCategory.kind` 3/3 in the SQL** (see [C-1](#c-1--category-kind-split-is-33-not-24-material)),
   and is the README prose the only thing wrong?
3. **`POST /triggers/:id/exclusions`** — designed-ahead, or built against a different
   HTML? Same question for the "6,000-line" reference.
4. **Should the isolated DB carry PHI classification now**, or is that deferred to the
   merge? Deferring means the pilot runs without it.
5. **Does `organizationId` + RLS come along at merge**, or does the isolated DB stay
   org-scoped-but-unenforced? §8 says the policies are omitted on purpose — worth
   confirming they're restored, since that's the fence between agencies.

## Related

- [data-model.md](data-model.md) — the schema I proposed; superseded in convention by this
- [api-design.md](api-design.md) — corrected against Taras's endpoint map
- [ADR-0008](adr/0008-align-with-unified-credify-schema.md) — adopting these conventions
- [ADR-0005](adr/0005-phi-minimization-in-outreach.md) — the PHI gap above
- [project-status.md](project-status.md) — status updated to reflect this delivery
