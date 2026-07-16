# Data model

> **Audience:** engineers designing the database. **Purpose:** the entities the prototype
> already models, and the relational schema they imply.

> ## ⚠ SUPERSEDED IN PART — read this first
>
> **This doc's proposed schema is a design sketch, not the plan of record.** It was
> written on 2026-07-16 without knowledge that a database already existed.
>
> **The schema of record is [database-cluster-email.md](database-cluster-email.md)** —
> an isolated 33-table Cluster Email DB **ret by Taras**, built to merge into
> `credify_unified_schema.sql` (**105 tables, 319 indexes, 100 RLS policies**, verified on
> PostgreSQL 16.14).
>
> Its conventions win, and they differ from this document's on nearly every axis —
> quoted CamelCase not `snake_case`, TEXT cuid PKs minted **app-side** not
> `gen_random_uuid()`, `TIMESTAMP(3)` not `timestamptz`, Prisma not hand-written SQL,
> multi-tenant `organizationId` + RLS not single-tenant. See
> [ADR-0008](adr/0008-align-with-unified-credify-schema.md).
>
> **What is still worth reading here:**
> - The **Entities** section — verified against `index.html`, and unaffected.
> - **`form_fields.is_phi` / `mergeable`** — a PHI classification that **neither** the
>   isolated nor the unified schema has, and that this module needs
>   ([ADR-0005](adr/0005-phi-minimization-in-outreach.md)).
> - The reasoning on **suppression keying on address, not `contact_id`** — which Taras's
>   schema independently agrees with (`UNIQUE (organizationId, email)`, normalized
>   `LOWER(TRIM(email))`).
>
> Read the `CREATE TABLE` blocks below as an argument, not an instruction.

## Current persistence, in full

```
localStorage["credify_cluster_email_v1"] = JSON.stringify(stateSnapshot)
```

One key. One browser. One user. Verified at `index.html:1879`. Cleared by
`localStorage.removeItem(PERSIST_KEY)` in the reset handler — which also destroys the
audit log, a fact that is fine in a prototype and disqualifying in production.

## Entities (verified)

Counted programmatically from the seed constants.

| Entity | Source | Count | Notes |
| --- | --- | --- | --- |
| Contact types | `SYSTEM_TYPE_LABELS` | **20** | Paired Prospective/Active: `Prospective Patient`/`Patient`, `Prospective Referral Source`/`Referral Source Partner`, … |
| Field types | `FIELD_TYPES` | **20** | `text, textarea, email, phone, number, currency, percent, date, time, select, multiselect, radio, checkbox, rating, scale, signature, file, address, ssn, url` |
| Forms | `SEED_FORMS` via `mkForm()` | **5** | `demographics`, `financial`, `insurance`, `clinical`, `consent` |
| Statuses | `SEED_STATUSES` | **10** | Operational position |
| Stages | `SEED_STAGES` | **6** | `New Lead → Contacted → Intake Scheduled → In Treatment → Discharged → Closed` |
| Lead sources | `SEED_LEAD_SOURCES` | **8** | Website Form, Google Ads, Psychology Today, Physician Referral, … |
| Lead types | `SEED_LEAD_TYPES` | **6** | Self-Pay, Commercial, Medicaid, EAP, Sliding-Scale, Grant-Funded |
| Categories | `SEED_CATEGORIES` | **6** — **3 transactional / 3 marketing** | `kind` drives consent: marketing honors opt-outs, transactional ignores them. Transactional: `cat_appt`, `cat_billing`, `cat_care`. Marketing: `cat_marketing`, `cat_surveys`, `cat_events`. ⚠ [database-cluster-email.md](database-cluster-email.md) §7 miscounts this as 2/4 — see [C-1](database-cluster-email.md#c-1--category-kind-split-is-33-not-24-material) |
| Reps | `REPS` | **5** | Name + title |
| Templates | `SEED_TEMPLATES` / `SEED_SMS_TEMPLATES` | **4** / 3 | `kind: text \| html`. Email: Intro / Welcome · Balance Reminder · Partner Check-In · Welcome (HTML, bilingual) |
| Triggers | `state.triggers` (`index.html:1969`) | 4 (8 steps) | Step ids (`s1,s2…`) **repeat across triggers** — key on `(triggerId, stepKey)` |
| Contacts | `makeContacts()` | 36 (`c1…c36`) | 100-key `formData` (5 forms × 20 fields); 18 opted out of ≥1 marketing category |

**`ssn` and `signature` are first-class field types.** The form engine is built to
capture a Social Security Number and a patient signature, and any captured field is
addressable as a merge tag. That single fact drives most of
[security-compliance.md](security-compliance.md).

### The PHI classification (verified)

`index.html:1441-1443` — this is the entire PHI detection surface:

```js
const PHI_TAG_SLUGS = new Set(["clinical"]);
const PHI_TAG_KEYS  = new Set(["ssn","tax_id","subscriber_ssn","patient_ssn","ssn_last4",
                               "dob","primary_dx","symptoms","risk_level","phq9_severity",
                               "gad7_score","presenting_concern","diagnosis"]);
function isPhiTag(slug,key){ return PHI_TAG_SLUGS.has(slug) || PHI_TAG_KEYS.has(key); }
```

Plus 5 literal regex patterns (`PHI_PATTERNS`): SSN `\d{3}-\d{2}-\d{4}`, MRN, DOB,
member/subscriber ID, and diagnosis references (`dsm-5`, `icd-10`, "diagnosed with").

**This list is a denylist, and denylists are wrong by default.** `home_address` isn't in
it. Neither is `photo_id`, or `income_doc`, or `fin_signature` — all real fields in the
seeded forms, all identifying. The right model is a **field-level `phi` flag on the form
definition** (allowlist: nothing is safe unless marked safe), not a hardcoded set of key
names that has to be kept in sync by hand. Carried into the schema below as
`form_fields.is_phi`.

## Relationships

```
 contact_types (20) ────┐
                        │  N:1
 statuses (10) ─────┐   │
 stages (6) ────┐   │   │
 lead_sources(8)│   │   │
 lead_types (6) │   │   │
 users (5) ─────┤   │   │
                ▼   ▼   ▼
              ┌─────────────┐
              │  contacts   │
              └──────┬──────┘
                     │ 1:N
        ┌────────────┼────────────┬──────────────┐
        ▼            ▼            ▼              ▼
 contact_field   suppressions  notify_prefs  job_recipients
   _values        (email/sms)   (per category)     │
        │                                          │ N:1
        │ N:1                                      ▼
        ▼                                     ┌─────────┐
  form_fields ──N:1──▶ forms (5)              │  jobs   │
        │                                     └────┬────┘
        │                                          │ N:1
        │                                          ▼
        │                                    templates ──N:1──▶ categories (6)
        │                                          │
        ▼                                          ▼
   is_phi flag                             delivery_events
                                          (open/click/bounce)

  audit_log ── references everything, owns nothing, deletes never
```

## Proposed schema (⬜ not built)

PostgreSQL. Conventions below the SQL.

```sql
-- ─── identity ───────────────────────────────────────────────
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         citext NOT NULL UNIQUE,
  display_name  text   NOT NULL,
  title         text,                      -- "Director of Outreach"
  role          text   NOT NULL,           -- rbac; see security-compliance.md
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ─── taxonomies ─────────────────────────────────────────────
CREATE TABLE contact_types (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,        -- ct_prospective_patient
  label       text NOT NULL,
  lifecycle   text NOT NULL CHECK (lifecycle IN ('prospective','active')),
  is_system   boolean NOT NULL DEFAULT false,   -- the 20 seeded types
  sort_order  integer NOT NULL DEFAULT 0
);

CREATE TABLE statuses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE, label text NOT NULL, sort_order integer NOT NULL DEFAULT 0
);

CREATE TABLE stages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,               -- stg_disch
  label text NOT NULL,
  sort_order integer NOT NULL,
  is_discharged boolean NOT NULL DEFAULT false   -- drives the discharge guard
);

CREATE TABLE lead_sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text NOT NULL UNIQUE, label text NOT NULL
);
CREATE TABLE lead_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text NOT NULL UNIQUE, label text NOT NULL
);

-- ─── contacts ───────────────────────────────────────────────
CREATE TABLE contacts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_type_id  uuid NOT NULL REFERENCES contact_types(id),
  status_id        uuid REFERENCES statuses(id),
  stage_id         uuid REFERENCES stages(id),
  lead_source_id   uuid REFERENCES lead_sources(id),
  lead_type_id     uuid REFERENCES lead_types(id),
  assigned_rep_id  uuid REFERENCES users(id),
  display_name     text   NOT NULL,
  email            citext,
  mobile_phone     text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz              -- soft delete; audit needs the row
);

-- ─── forms: EAV, because agencies customize fields ──────────
CREATE TABLE forms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,               -- demographics|financial|insurance|clinical|consent
  name text NOT NULL,
  category text NOT NULL
);

CREATE TABLE form_fields (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  form_id   uuid NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
  key       text NOT NULL,                 -- first_name, ssn, dob
  label     text NOT NULL,
  type      text NOT NULL CHECK (type IN (
              'text','textarea','email','phone','number','currency','percent','date',
              'time','select','multiselect','radio','checkbox','rating','scale',
              'signature','file','address','ssn','url')),
  -- Allowlist, not denylist. Default true: a field is PHI until proven otherwise.
  is_phi    boolean NOT NULL DEFAULT true,
  -- May this field ever appear in an outbound body? See ADR-0005.
  mergeable boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (form_id, key)
);

CREATE TABLE contact_field_values (
  contact_id    uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  form_field_id uuid NOT NULL REFERENCES form_fields(id) ON DELETE CASCADE,
  value         text,                      -- encrypted at rest when is_phi
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, form_field_id)
);

-- ─── consent ────────────────────────────────────────────────
CREATE TABLE categories (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,               -- cat_appt, cat_billing, cat_marketing
  label text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('transactional','marketing')),
  description text
);

-- Hard block. Absolute, beats everything, no override anywhere.
CREATE TABLE suppressions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel    text NOT NULL CHECK (channel IN ('email','sms')),
  address    citext NOT NULL,              -- email or E.164; NOT contact_id — see note
  reason     text NOT NULL,                -- unsubscribe|bounce|complaint|manual|sms_stop
  source     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, address)
);

-- Soft, per-category consent. Transactional may still be permitted.
CREATE TABLE notify_prefs (
  contact_id  uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  enabled     boolean NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, category_id)
);

-- ─── templates ──────────────────────────────────────────────
CREATE TABLE templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel     text NOT NULL CHECK (channel IN ('email','sms')),
  kind        text NOT NULL CHECK (kind IN ('text','html')),
  name        text NOT NULL,
  category_id uuid REFERENCES categories(id),
  subject     text,                        -- null for sms
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ─── jobs ───────────────────────────────────────────────────
CREATE TABLE jobs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id    uuid NOT NULL REFERENCES templates(id),
  category_id    uuid REFERENCES categories(id),
  sent_by        uuid NOT NULL REFERENCES users(id),
  status         text NOT NULL CHECK (status IN ('queued','sending','sent','canceled','failed')),
  mode           text NOT NULL CHECK (mode IN ('immediate','scheduled')),
  scheduled_at   timestamptz,
  tracking       boolean NOT NULL DEFAULT true,
  -- Snapshots: the template can change tomorrow; the audit trail cannot.
  subject_snapshot text,
  body_snapshot    text NOT NULL,
  -- The audience *criteria*, for reproducibility. Never the resolved IDs alone.
  audience_criteria jsonb NOT NULL,
  -- Acknowledgments, captured at queue time with who/when.
  phi_ack_by      uuid REFERENCES users(id),
  phi_ack_at      timestamptz,
  phi_findings    jsonb,
  discharge_ack_at timestamptz,
  discharge_ack_sig text,                  -- hash of recipient ids; invalidates on change
  cap_ack_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  idempotency_key text UNIQUE
);

CREATE TABLE job_recipients (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id       uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  contact_id   uuid NOT NULL REFERENCES contacts(id),
  address      citext NOT NULL,            -- snapshot: email at send time
  status       text NOT NULL CHECK (status IN
                 ('pending','sent','delivered','bounced','failed','skipped')),
  skip_reason  text,                       -- suppressed|opted_out|freq_cap|quiet_hours
  provider_message_id text,
  sent_at      timestamptz,
  UNIQUE (job_id, contact_id)
);

CREATE TABLE delivery_events (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_recipient_id uuid NOT NULL REFERENCES job_recipients(id) ON DELETE CASCADE,
  type             text NOT NULL CHECK (type IN
                     ('open','click','hard_bounce','soft_bounce','complaint','unsubscribe')),
  url              text,                   -- click only
  occurred_at      timestamptz NOT NULL,
  raw              jsonb,                  -- provider payload, PHI-scrubbed
  UNIQUE (job_recipient_id, type, occurred_at)   -- webhooks retry; dedupe
);

-- ─── settings ───────────────────────────────────────────────
CREATE TABLE settings (
  key        text PRIMARY KEY,             -- freqCap|quietHours|businessHours|footer|unsubPage
  value      jsonb NOT NULL,
  updated_by uuid REFERENCES users(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─── audit: append-only, outlives everything ────────────────
CREATE TABLE audit_log (
  id          bigserial PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid REFERENCES users(id),
  actor_label text NOT NULL,               -- denormalized: users may be deleted
  event_type  text NOT NULL,
  entity_type text,
  entity_id   uuid,
  job_id      uuid,
  summary     text NOT NULL,               -- never PHI
  metadata    jsonb                        -- never PHI
) PARTITION BY RANGE (occurred_at);

REVOKE UPDATE, DELETE ON audit_log FROM app_user;   -- append-only, enforced by grant
```

### Two schema decisions worth defending

**`suppressions` keys on address, not `contact_id`.** If a person unsubscribes and you
later create a second contact record with the same email, keying on `contact_id` means
you'd cheerfully email them again. Suppression is a property of the *address*, and the
uniqueness constraint is what makes "we never email a suppressed address" true rather
than aspirational.

**`jobs` snapshots subject and body.** A template edited next month must not rewrite what
you sent last month. The audit trail's job is to answer "what did we actually send to
this person," and that answer has to be immutable.

## Conventions

| Convention | Rule |
| --- | --- |
| Keys | `uuid` PKs, `gen_random_uuid()`. Exception: `audit_log` uses `bigserial` — ordering matters and it's never joined from outside |
| Naming | `snake_case`, plural tables, `<entity>_id` FKs |
| Time | `timestamptz` always, UTC always. Never `timestamp`. Users see local; the DB stores absolute |
| Email | `citext` — case-insensitive, because `Jay@x.com` and `jay@x.com` are the same person and the suppression list must agree |
| Deletes | Soft (`deleted_at`) for contacts. Audit needs the row. `audit_log` is never deleted at all |
| Enums | `text` + `CHECK`, not PG `enum` types — adding a value to a PG enum is a migration headache |
| PHI | `form_fields.is_phi` defaults **true**. Encrypt those values at rest |
| Slugs | Stable, machine-readable, never displayed. Labels change; slugs don't |

## Indexes

Driven by the actual query patterns in `clusterRecipients()` and the guard chain.

```sql
-- audience filtering: the hot path, runs on every audience change
CREATE INDEX idx_contacts_type      ON contacts(contact_type_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_status    ON contacts(status_id)       WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_stage     ON contacts(stage_id)        WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_rep       ON contacts(assigned_rep_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_email     ON contacts(email)           WHERE deleted_at IS NULL;

-- suppression: checked once per recipient per send. Must be fast and exact.
-- (UNIQUE(channel,address) already indexes this — named here because it is load-bearing.)

-- frequency cap: "has this contact been sent to in the last N days?"
CREATE INDEX idx_job_recipients_contact_sent ON job_recipients(contact_id, sent_at DESC);

-- job views
CREATE INDEX idx_jobs_status_sched  ON jobs(status, scheduled_at);
CREATE INDEX idx_jobs_sent_by       ON jobs(sent_by, created_at DESC);

-- rates/clicks reporting
CREATE INDEX idx_delivery_events_type_time ON delivery_events(type, occurred_at DESC);

-- audit filtering (the Audit tab filters by user, type, source, date range)
CREATE INDEX idx_audit_actor_time   ON audit_log(actor_id, occurred_at DESC);
CREATE INDEX idx_audit_type_time    ON audit_log(event_type, occurred_at DESC);
CREATE INDEX idx_audit_job          ON audit_log(job_id) WHERE job_id IS NOT NULL;

-- EAV lookup
CREATE INDEX idx_cfv_field ON contact_field_values(form_field_id);
```

`idx_job_recipients_contact_sent` is the one that matters most — the frequency cap runs
per recipient per send, so a 2,000-recipient job does 2,000 of these lookups.

## Migrations and seed

**⬜ Nothing exists.** When it does:

| Concern | Approach |
| --- | --- |
| Tool | Plain SQL files, `NNNN_description.sql`, forward-only. No ORM auto-migration — a tool that can silently drop a column has no business near an audit table |
| Ordering | Numbered, sequential, applied in a transaction, recorded in `schema_migrations` |
| Rollback | Write the down-migration, but expect not to use it. For anything destructive, prefer a new forward migration. See [operations-runbook.md](operations-runbook.md#rollback) |
| Seed: reference data | The 20 contact types, 20 field types, 5 forms, 10 statuses, 6 stages, 8 sources, 6 lead types, 6 categories are **real reference data** — migrate them in, don't treat them as fixtures |
| Seed: demo data | Contacts, templates, jobs are **fixtures**. Dev/demo only. Never seeded into production |
| **Never** | No real client data in fixtures, ever. Not "anonymized" real data either — that's a re-identification bet you don't need to take |

The prototype's `SEED_*` constants are the source for the reference-data migration. They
are the maintainer's actual domain model, and they are the most valuable thing to port
faithfully.

## Related

- [architecture.md](architecture.md) — where this sits
- [api-design.md](api-design.md) — the routes over these tables
- [security-compliance.md](security-compliance.md) — encryption, retention, RBAC
- [ADR-0002](adr/0002-node-express-postgres-backend.md) — why Postgres
- [ADR-0005](adr/0005-phi-minimization-in-outreach.md) — the `is_phi` / `mergeable` rules
