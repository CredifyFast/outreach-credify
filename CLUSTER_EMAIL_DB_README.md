# Cluster Email — Isolated Database (Junior Dev Guide)

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
