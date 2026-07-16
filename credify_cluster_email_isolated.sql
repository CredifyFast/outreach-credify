-- =============================================================================
-- CREDIFY CLUSTER EMAIL — ISOLATED MODULE DATABASE (PostgreSQL 16)
-- =============================================================================
-- Database: credify_cluster_email      Generated: 2026-07-15 14:33 PDT
-- Serves:   CLUSTER_EMAIL_07-10-26_0510PM-PDT_SUMM-LINKS_SUPPORT.html
-- Purpose:  A standalone, junior-dev-friendly database for wiring the Cluster
--           Email front-end to a real backend and testing it in isolation,
--           BEFORE these tables are merged into credify_unified_schema.sql.
--
-- WHAT THIS FILE IS
--   The COMPLETE create + seed script for a fresh install. One psql run gives
--   you every table the module needs plus the exact demo data the HTML file
--   seeds itself with on first load (36 contacts, 4 email templates, 2 sent
--   demo jobs with opens/clicks, 4 triggers, deliverability events, the
--   auto-suppression they cause, and all settings). The front-end's api()
--   wrapper (one function, line ~1898 of the HTML) is the only seam the
--   backend needs to satisfy — see CLUSTER_EMAIL_DB_README.md for the
--   endpoint → table map.
--
-- CONVENTIONS (identical to credify_unified_schema.sql so the merge is cheap)
--   * Prisma style: quoted CamelCase table/column names, TEXT primary keys
--     minted app-side (the front-end already mints ids via uid()/Date.now()
--     and sends them up — the server accepts them).
--   * TIMESTAMP(3); the app reads/writes ISO-8601 UTC strings.
--     NOTE: EmailJobRecipient.openedAt / clickedAt arrive from the current
--     front-end as epoch MILLISECONDS (numbers) — the API layer converts
--     (new Date(ms).toISOString()) before writing. Everything else is ISO.
--   * Every tenant-scoped table carries "organizationId". Row-Level Security
--     and the credify_app role are intentionally OMITTED in this isolated DB
--     (dev friction); they come back when these tables land in the unified
--     schema. One org is seeded: 'org_demo'.
--   * "updatedAt" columns get DEFAULT CURRENT_TIMESTAMP here so raw SQL and
--     psql inserts just work. The unified file leaves updatedAt default-less
--     because Prisma fills it — drop the defaults at merge if Prisma owns it.
--   * JSONB for admin-edited config documents (segment groups, trigger entry/
--     goals, template blocks, footers); child tables for everything queried,
--     joined, or counted relationally.
--   * Enums only for genuinely FIXED lifecycle vocabularies. Anything an
--     admin can edit in the UI (categories, types, statuses) is config DATA.
--   * Append-only log tables (EmailAuditLog, EmailClickEvent,
--     DeliverabilityEvent, EmailNotifLog) carry contact/job SNAPSHOT columns
--     (name, email, templateName) and deliberately have NO foreign keys —
--     logs must survive deletion of what they describe, exactly like the
--     front-end keeps working when a template or contact disappears.
--
-- =============================================================================
-- MERGE MAP — where every table goes when it joins credify_unified_schema.sql
-- =============================================================================
--   ISOLATED TABLE            UNIFIED DESTINATION
--   ----------------------    ---------------------------------------------
--   Organization              already exists — drop this mini, use unified
--   User (mini)               already exists — drop this mini, use unified
--   Contact (mini)            already exists — the [Cluster ext] columns
--                             (opens, sends, clicks, openHistory, peakHour,
--                             softBounces, bounceStatus, lastBounceAt,
--                             complainedAt, lang, tz) move onto unified
--                             "Contact"; formData is replaced by the real
--                             Submission / DemographicRecord pipeline.
--   ContactCrmEvent           replaced by the unified WorkflowEvent outbox —
--                             this mini exists only so the trigger engine's
--                             event-entry conditions are testable standalone.
--   ContactType               already exists — drop mini, use unified
--   ActionType                already exists (the CRM's status vocabulary;
--                             the front-end calls these "statuses", st_*)
--   PipelineStage             already exists — drop mini, use unified
--   StageAction               already exists — drop mini, use unified
--   LeadSource / LeadType     already exist — drop minis, use unified
--   DistributionList          already exists (buckets = kind 'bucket')
--   DistributionRule          already exists (kind 'distribution' |
--                             'redistribution' — same discriminator)
--   TouchRule                 already exists — drop mini, use unified
--   Form (mini)               already exists — fields JSONB is a stand-in
--                             for Form + FormVersion
--   EmailPrefCategory         NEW table — lands as-is
--   ContactEmailPref          NEW table — lands as-is
--   EmailSuppression          NEW table — lands as-is
--   SmsSuppression            NEW table — lands as-is
--   EmailTemplate             unified EmailTemplate gains the [Cluster ext]
--                             columns: categoryId, kind, bilingual, blocks,
--                             es, attachment
--   SmsTemplate               NEW — or fold into NotifTemplate
--                             (channel='sms', meta.categoryId); decide at merge
--   EmailSignature            NEW table — lands as-is
--   Segment                   NEW table — lands as-is
--   EmailTrigger(+Step,       NEW tables — cousins of Sequence/SequenceStep;
--     +Exclusion)             keep separate (richer entry/goals/branch shape)
--   EmailJob                  NEW table — lands as-is
--   EmailJobRecipient         NEW table — lands as-is; ALSO append one
--                             ContactEmailLog row per recipient at send time
--                             so sends show on the CRM contact timeline
--   EmailClickEvent           NEW table — lands as-is
--   DeliverabilityEvent       NEW table — lands as-is
--   EmailAuditLog             NEW — or fold into unified AuditEvent; decide
--                             at merge
--   NotifyPref                NEW table — lands as-is
--   EmailNotifLog             fold into unified NotificationLog at merge
--   Setting                   rows move into unified OrgSetting (same
--                             key/value shape, keys: clusterEmail.*)
--   vDueEmailSends (view)     folds into the answer365 vDueAutomationWork
--                             due-state pattern
-- =============================================================================


-- =============================================================================
-- PART 0 — ENUMS
-- Only genuinely fixed vocabularies. Admin-editable lists (contact types,
-- statuses, preference categories) are DATA, never enums.
-- =============================================================================

-- EmailTemplate.kind — plain text vs block-based HTML builder.
CREATE TYPE "TemplateKind" AS ENUM ('text', 'html');

-- EmailPrefCategory.kind — CAN-SPAM split: transactional emails ignore
-- marketing opt-outs; marketing emails honor them + carry one-click unsub.
CREATE TYPE "PrefCategoryKind" AS ENUM ('transactional', 'marketing');

-- EmailJob.mode — send now vs scheduled (buildJob()).
CREATE TYPE "EmailJobMode" AS ENUM ('immediate', 'scheduled');

-- EmailJob.status — queued → sent, or canceled ("cancel-job" action).
CREATE TYPE "EmailJobStatus" AS ENUM ('queued', 'sent', 'canceled');

-- DeliverabilityEvent.type — the four ESP webhook events the classifier
-- understands (classifyDeliverEvent()): delivered resets the soft-bounce
-- counter; hard_bounce suppresses; complaint kills marketing categories;
-- soft_bounce counts toward the limit (3) then suppresses.
CREATE TYPE "DeliverabilityType" AS ENUM ('delivered', 'soft_bounce', 'hard_bounce', 'complaint');


-- =============================================================================
-- PART 1 — TENANCY + MODULE-LOCAL COPIES OF CRM REFERENCE DATA
-- Everything in this PART is a deliberately SIMPLIFIED stand-in carrying only
-- the fields the Cluster Email module actually reads. At merge these minis
-- are dropped and the module's tables re-point at the real unified tables.
-- =============================================================================

-- The tenant. Mini stand-in for unified "Organization".
CREATE TABLE "Organization" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "Organization_pkey" PRIMARY KEY ("id")
);

-- STATE.reps — the people who send email and get assigned contacts.
-- Mini stand-in for unified "User" (id, label→name, title only).
CREATE TABLE "User" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "title" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "User_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "User_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.contactTypes — the 20 system contact types (Prospective X / X pairs).
-- "system" types can't be deleted in the UI; "sortOrder" is STATE order.
CREATE TABLE "ContactType" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "system" BOOLEAN NOT NULL DEFAULT false,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT "ContactType_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "ContactType_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.statuses — the CRM status vocabulary (st_attempt … st_lost).
-- Named "ActionType" because that is this vocabulary's table in the unified
-- schema (ContactStatusHistory's from/to ids point at it).
CREATE TABLE "ActionType" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    CONSTRAINT "ActionType_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "ActionType_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.stages — pipeline stages (stg_new … stg_closed).
CREATE TABLE "PipelineStage" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT "PipelineStage_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "PipelineStage_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.stageActions — loggable stage actions (sa_vm … sa_dcsum); trigger
-- event-entry conditions reference these (eventType 'stage_action_logged').
CREATE TABLE "StageAction" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    CONSTRAINT "StageAction_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "StageAction_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.leadSources (ls_*).
CREATE TABLE "LeadSource" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    CONSTRAINT "LeadSource_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "LeadSource_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.leadTypes (lt_*). Template conditional blocks can key on these
-- (e.g. the Welcome HTML block shown only to lt_comm).
CREATE TABLE "LeadType" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    CONSTRAINT "LeadType_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "LeadType_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.buckets (bk_*) — unified models buckets as DistributionList rows of
-- kind 'bucket', so the mini keeps that name + discriminator.
CREATE TABLE "DistributionList" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "kind" TEXT NOT NULL DEFAULT 'bucket',
    CONSTRAINT "DistributionList_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "DistributionList_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.distRules + STATE.redistRules — one table discriminated by kind,
-- exactly like unified "DistributionRule".
CREATE TABLE "DistributionRule" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "kind" TEXT NOT NULL CHECK ("kind" IN ('distribution', 'redistribution')),
    CONSTRAINT "DistributionRule_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "DistributionRule_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.touchRules (tr_*) — cadence programs; contacts carry touchStep +
-- nextTouchDueAt.
CREATE TABLE "TouchRule" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "steps" INTEGER NOT NULL DEFAULT 1,
    CONSTRAINT "TouchRule_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "TouchRule_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.forms — the 5 demo intake forms (20 fields each). "fields" is the
-- verbatim [{key,label,type}] array; merge tags ({{slug.key}}) resolve
-- against it. Mini stand-in for unified Form + FormVersion.
CREATE TABLE "Form" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "category" TEXT,
    "fields" JSONB NOT NULL DEFAULT '[]',
    CONSTRAINT "Form_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "Form_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "Form_organizationId_slug_key" ON "Form" ("organizationId", "slug");

-- STATE.contacts — mini stand-in for unified "Contact", carrying ONLY what
-- this module reads: identity + address/tz (quiet-hours scheduling runs on
-- the contact's own clock), the ten CRM axes the audience filters use,
-- engagement counters (Open Rates tab), deliverability state (bounce
-- classifier), preferred language (bilingual templates), and "formData" —
-- the flattened {"slug.key": value} object that merge tags resolve against.
-- PHI note: formData holds demo values only. In the unified DB this blob is
-- REPLACED by the Submission/DemographicRecord pipeline where clinical PHI
-- is app-encrypted; do not ship real PHI through this isolated column.
CREATE TABLE "Contact" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "firstName" TEXT NOT NULL DEFAULT '',
    "lastName" TEXT NOT NULL DEFAULT '',
    "name" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "phone" TEXT,
    "street" TEXT,
    "city" TEXT,
    "zip" TEXT,
    "tz" TEXT,                          -- IANA zone, e.g. America/Los_Angeles
    "lang" TEXT NOT NULL DEFAULT 'en',  -- 'en' | 'es' (pickVersion())
    "typeId" TEXT,
    "leadSourceId" TEXT,
    "leadTypeId" TEXT,
    "stageId" TEXT,
    "statusId" TEXT,                    -- → ActionType (front-end: statusId)
    "bucketId" TEXT,                    -- → DistributionList
    "distributionRuleId" TEXT,
    "assignedRepId" TEXT,               -- front-end property: assignedRep
    "redistributedById" TEXT,           -- front-end: redistributedBy (rule id)
    "redistributedAt" TIMESTAMP(3),
    "touchRuleId" TEXT,
    "touchStep" INTEGER NOT NULL DEFAULT 0,
    "nextTouchDueAt" TIMESTAMP(3),
    "lastStageActionId" TEXT,
    "opens" INTEGER NOT NULL DEFAULT 0,
    "sends" INTEGER NOT NULL DEFAULT 0,
    "clicks" INTEGER NOT NULL DEFAULT 0,
    "openHistory" JSONB NOT NULL DEFAULT '[]',  -- 24 ints, opens by hour
    "peakHour" INTEGER,
    "softBounces" INTEGER NOT NULL DEFAULT 0,
    "bounceStatus" TEXT NOT NULL DEFAULT 'ok',  -- 'ok' | 'soft' | 'hard'
    "lastBounceAt" TIMESTAMP(3),
    "complainedAt" TIMESTAMP(3),
    "formData" JSONB NOT NULL DEFAULT '{}',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "Contact_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "Contact_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "Contact_typeId_fkey" FOREIGN KEY ("typeId")
        REFERENCES "ContactType" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_leadSourceId_fkey" FOREIGN KEY ("leadSourceId")
        REFERENCES "LeadSource" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_leadTypeId_fkey" FOREIGN KEY ("leadTypeId")
        REFERENCES "LeadType" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_stageId_fkey" FOREIGN KEY ("stageId")
        REFERENCES "PipelineStage" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_statusId_fkey" FOREIGN KEY ("statusId")
        REFERENCES "ActionType" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_bucketId_fkey" FOREIGN KEY ("bucketId")
        REFERENCES "DistributionList" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_distributionRuleId_fkey" FOREIGN KEY ("distributionRuleId")
        REFERENCES "DistributionRule" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_assignedRepId_fkey" FOREIGN KEY ("assignedRepId")
        REFERENCES "User" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_redistributedById_fkey" FOREIGN KEY ("redistributedById")
        REFERENCES "DistributionRule" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_touchRuleId_fkey" FOREIGN KEY ("touchRuleId")
        REFERENCES "TouchRule" ("id") ON DELETE SET NULL,
    CONSTRAINT "Contact_lastStageActionId_fkey" FOREIGN KEY ("lastStageActionId")
        REFERENCES "StageAction" ("id") ON DELETE SET NULL
);
CREATE INDEX "Contact_organizationId_idx" ON "Contact" ("organizationId");
CREATE INDEX "Contact_organizationId_typeId_idx" ON "Contact" ("organizationId", "typeId");
CREATE INDEX "Contact_organizationId_statusId_idx" ON "Contact" ("organizationId", "statusId");
CREATE INDEX "Contact_organizationId_assignedRepId_idx" ON "Contact" ("organizationId", "assignedRepId");
CREATE INDEX "Contact_email_idx" ON "Contact" ("email");

-- contact._recentEvents — recent CRM events the trigger engine's event-entry
-- conditions match against (form_submitted / stage_action_logged /
-- tag_applied / inbound_deliverability). Standalone stand-in for the unified
-- WorkflowEvent outbox; "meta" holds the event's extra keys verbatim
-- (formSlug, stageActionId, tag, delivType).
CREATE TABLE "ContactCrmEvent" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "contactId" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "meta" JSONB NOT NULL DEFAULT '{}',
    CONSTRAINT "ContactCrmEvent_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "ContactCrmEvent_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "ContactCrmEvent_contactId_fkey" FOREIGN KEY ("contactId")
        REFERENCES "Contact" ("id") ON DELETE CASCADE
);
CREATE INDEX "ContactCrmEvent_organizationId_contactId_at_idx"
    ON "ContactCrmEvent" ("organizationId", "contactId", "at");


-- =============================================================================
-- PART 2 — EMAIL PREFERENCE CENTER + SUPPRESSION
-- The compliance core: category opt-ins (Preferences tab), the permanent
-- email suppression list (Suppression tab), and SMS opt-outs (Unsubscribe
-- tab). clusterRecipients() must exclude suppressed addresses and, for
-- marketing categories, opted-out contacts — mirror that in every send path.
-- =============================================================================

-- STATE.categories — email preference categories (cat_*). kind decides the
-- CAN-SPAM footer: marketing gets one-click unsubscribe, transactional gets
-- manage-preferences only.
CREATE TABLE "EmailPrefCategory" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "kind" "PrefCategoryKind" NOT NULL DEFAULT 'marketing',
    "description" TEXT,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT "EmailPrefCategory_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailPrefCategory_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- contact.prefs — one row per contact per category. The front-end's
-- defaultPrefs() opts everyone into everything; a MISSING row therefore
-- means opted-in ("optedIn" true). PUT /contacts/:id/preferences upserts the
-- whole set. A spam complaint flips every marketing category to false
-- (classifyDeliverEvent → marketingOff).
CREATE TABLE "ContactEmailPref" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "contactId" TEXT NOT NULL,
    "categoryId" TEXT NOT NULL,
    "optedIn" BOOLEAN NOT NULL DEFAULT true,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ContactEmailPref_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "ContactEmailPref_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "ContactEmailPref_contactId_fkey" FOREIGN KEY ("contactId")
        REFERENCES "Contact" ("id") ON DELETE CASCADE,
    CONSTRAINT "ContactEmailPref_categoryId_fkey" FOREIGN KEY ("categoryId")
        REFERENCES "EmailPrefCategory" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "ContactEmailPref_contactId_categoryId_key"
    ON "ContactEmailPref" ("contactId", "categoryId");
CREATE INDEX "ContactEmailPref_organizationId_categoryId_optedIn_idx"
    ON "ContactEmailPref" ("organizationId", "categoryId", "optedIn");

-- STATE.suppressions — the permanent email kill-list. Keyed by NORMALIZED
-- email (trim + lowercase — normalizeEmail()); the API's delete route is
-- DELETE /suppressions/:email (URL-encoded email, not id). Reasons written
-- by the front-end today: 'hard_bounce', 'soft_bounce_limit', plus manual
-- adds from the Suppression tab — keep TEXT, not an enum.
CREATE TABLE "EmailSuppression" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "reason" TEXT NOT NULL DEFAULT 'manual',
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailSuppression_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailSuppression_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "EmailSuppression_organizationId_email_key"
    ON "EmailSuppression" ("organizationId", "email");

-- STATE.smsSuppressions — SMS STOP list. The manual-add form accepts a free
-- string (name OR phone) and the front-end stores it in contact/name/phone
-- alike; keep all three so the API can round-trip the object verbatim.
CREATE TABLE "SmsSuppression" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "contact" TEXT NOT NULL,
    "name" TEXT,
    "phone" TEXT,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SmsSuppression_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "SmsSuppression_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);


-- =============================================================================
-- PART 3 — TEMPLATES + SIGNATURES
-- =============================================================================

-- STATE.templates — email templates. kind 'text' uses subject/body with
-- {{slug.key}} merge tags; kind 'html' uses "blocks" (heading/text/button/
-- image/divider/spacer rows, each optionally gated by a cond on CRM fields
-- or tag presence). "es" holds the Spanish version {subject, body, blocks}
-- when bilingual; pickVersion() serves it to lang='es' contacts.
-- "attachment" = {file:{name,type,size,dataUrl}|null, image:{...}|null}.
-- Attachments arrive as base64 dataUrls from the single-file front-end (file
-- ≤10MB, image ≤2MB); fine for isolated testing, move to object storage +
-- URL at merge. Merge: these columns extend unified "EmailTemplate".
CREATE TABLE "EmailTemplate" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "categoryId" TEXT,
    "kind" "TemplateKind" NOT NULL DEFAULT 'text',
    "bilingual" BOOLEAN NOT NULL DEFAULT false,
    "subject" TEXT NOT NULL DEFAULT '',
    "body" TEXT NOT NULL DEFAULT '',
    "blocks" JSONB,
    "es" JSONB,
    "attachment" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailTemplate_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailTemplate_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTemplate_categoryId_fkey" FOREIGN KEY ("categoryId")
        REFERENCES "EmailPrefCategory" ("id") ON DELETE SET NULL
);
CREATE INDEX "EmailTemplate_organizationId_idx" ON "EmailTemplate" ("organizationId");

-- STATE.smsTemplates — SMS templates (no subject; body carries merge tags +
-- the required "Reply STOP" line). Merge candidate: NotifTemplate
-- (channel='sms').
CREATE TABLE "SmsTemplate" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "categoryId" TEXT,
    "body" TEXT NOT NULL DEFAULT '',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SmsTemplate_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "SmsTemplate_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "SmsTemplate_categoryId_fkey" FOREIGN KEY ("categoryId")
        REFERENCES "EmailPrefCategory" ("id") ON DELETE SET NULL
);

-- STATE.signatures — reusable sender signatures appended to sends.
CREATE TABLE "EmailSignature" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "title" TEXT,
    "phone" TEXT,
    "email" TEXT,
    "org" TEXT,
    "body" TEXT NOT NULL DEFAULT '',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailSignature_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailSignature_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);


-- =============================================================================
-- PART 4 — SEGMENTS + TRIGGERS (drip sequences)
-- =============================================================================

-- STATE.segments — saved audiences. "groups" is the builder's verbatim
-- document: [{match:'all'|'any', conditions:[{field, op, value}]}]; groups
-- OR together, conditions inside a group AND/OR per match. Evaluated by
-- evalCondition() against Contact columns — the API can evaluate in SQL or
-- return the JSON for client-side evaluation (what the HTML does today).
CREATE TABLE "Segment" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "groups" JSONB NOT NULL DEFAULT '[]',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "Segment_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "Segment_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);

-- STATE.triggers — automated drip sequences. Distinct from (and richer than)
-- the CRM's Sequence: "entry" is either a field condition
-- {field, op, value} or an event condition {field:'__event', eventType,
-- formSlug|stageActionId|tag|delivType}; "goals" ([{kind:'status'|'stage',
-- value}]) exit + permanently exclude a contact when met; "branch" is the
-- (currently disabled) A/B branch config; freqCap/quietHours overrides let a
-- trigger bypass org settings. Steps live in EmailTriggerStep.
CREATE TABLE "EmailTrigger" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "entry" JSONB NOT NULL DEFAULT '{}',
    "segmentId" TEXT,
    "tracking" BOOLEAN NOT NULL DEFAULT true,
    "goals" JSONB NOT NULL DEFAULT '[]',
    "freqCapOverride" BOOLEAN NOT NULL DEFAULT false,
    "quietHoursOverride" BOOLEAN NOT NULL DEFAULT false,
    "branch" JSONB NOT NULL DEFAULT '{"enabled": false}',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailTrigger_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailTrigger_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTrigger_segmentId_fkey" FOREIGN KEY ("segmentId")
        REFERENCES "Segment" ("id") ON DELETE SET NULL
);

-- trigger.steps[] — one email per step, delayed {n, unit:'hours'|'days'}
-- after enrollment/previous step. "stepKey" is the front-end's per-trigger
-- step id (s1, s2, …) — unique only within a trigger, hence the surrogate
-- PK + composite unique. Triggers round-trip as whole JSON objects through
-- PUT /triggers/:id; the API decomposes steps into these rows.
CREATE TABLE "EmailTriggerStep" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "triggerId" TEXT NOT NULL,
    "stepKey" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "templateId" TEXT,
    "delayN" INTEGER NOT NULL DEFAULT 0,
    "delayUnit" TEXT NOT NULL DEFAULT 'days' CHECK ("delayUnit" IN ('hours', 'days')),
    CONSTRAINT "EmailTriggerStep_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailTriggerStep_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTriggerStep_triggerId_fkey" FOREIGN KEY ("triggerId")
        REFERENCES "EmailTrigger" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTriggerStep_templateId_fkey" FOREIGN KEY ("templateId")
        REFERENCES "EmailTemplate" ("id") ON DELETE SET NULL
);
CREATE UNIQUE INDEX "EmailTriggerStep_triggerId_stepKey_key"
    ON "EmailTriggerStep" ("triggerId", "stepKey");

-- STATE.trigExcluded — contacts permanently excluded from a trigger (goal
-- met). POST /triggers/:id/exclusions adds; the enrollment pass skips them.
CREATE TABLE "EmailTriggerExclusion" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "triggerId" TEXT NOT NULL,
    "contactId" TEXT NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailTriggerExclusion_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailTriggerExclusion_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTriggerExclusion_triggerId_fkey" FOREIGN KEY ("triggerId")
        REFERENCES "EmailTrigger" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailTriggerExclusion_contactId_fkey" FOREIGN KEY ("contactId")
        REFERENCES "Contact" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "EmailTriggerExclusion_triggerId_contactId_key"
    ON "EmailTriggerExclusion" ("triggerId", "contactId");


-- =============================================================================
-- PART 5 — SEND JOBS
-- Jobs are IMMUTABLE ONCE QUEUED: buildJob() resolves every merge tag,
-- picks each contact's language version, renders HTML blocks, and computes
-- each recipient's own sendAt (quiet/business hours in the CONTACT's time
-- zone) at queue time. Later template edits or deletes must never mutate a
-- queued send — that is why EmailJobRecipient carries full content
-- snapshots and EmailJob snapshots templateName.
-- =============================================================================

-- STATE.jobs — one row per send job (POST /sends). "typeIds" is the
-- audience's contact-type filter snapshot (display-only after queue, so
-- JSONB not a join table). "footer" is the CAN-SPAM footer config snapshot.
-- "sentBy" is the sender's display name exactly as the front-end stores it.
-- Canceling (DELETE /sends/:id) sets status='canceled' — never delete rows.
CREATE TABLE "EmailJob" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "templateId" TEXT,
    "templateName" TEXT NOT NULL DEFAULT '',
    "categoryId" TEXT,
    "kind" "TemplateKind" NOT NULL DEFAULT 'text',
    "bilingual" BOOLEAN NOT NULL DEFAULT false,
    "typeIds" JSONB NOT NULL DEFAULT '[]',
    "mode" "EmailJobMode" NOT NULL DEFAULT 'immediate',
    "scheduledAt" TIMESTAMP(3),
    "tracking" BOOLEAN NOT NULL DEFAULT true,
    "status" "EmailJobStatus" NOT NULL DEFAULT 'queued',
    "source" TEXT NOT NULL DEFAULT 'cluster',  -- 'cluster' | 'trigger' | 'abtest'
    "triggerId" TEXT,
    "note" TEXT NOT NULL DEFAULT '',
    "footer" JSONB,
    "portalNotice" BOOLEAN NOT NULL DEFAULT false,
    "sentBy" TEXT NOT NULL DEFAULT '',
    CONSTRAINT "EmailJob_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailJob_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailJob_templateId_fkey" FOREIGN KEY ("templateId")
        REFERENCES "EmailTemplate" ("id") ON DELETE SET NULL,
    CONSTRAINT "EmailJob_categoryId_fkey" FOREIGN KEY ("categoryId")
        REFERENCES "EmailPrefCategory" ("id") ON DELETE SET NULL,
    CONSTRAINT "EmailJob_triggerId_fkey" FOREIGN KEY ("triggerId")
        REFERENCES "EmailTrigger" ("id") ON DELETE SET NULL
);
CREATE INDEX "EmailJob_organizationId_status_idx" ON "EmailJob" ("organizationId", "status");
CREATE INDEX "EmailJob_organizationId_createdAt_idx" ON "EmailJob" ("organizationId", "createdAt");

-- job.recipients[] — one row per contact per job with the fully-resolved
-- content snapshot (subject/body/bodyHtml), per-recipient tracking state
-- (trackId, opened/openedAt, clicked/clickedUrl/clickedAt), the RFC 8058
-- one-click unsubscribe headers, and the recipient's own sendAt.
-- providerMessageId/sendStatus/sentAt are EMPTY today — nullable ESP columns
-- so real sending (SES/SendGrid/Postmark) wires in without a migration.
-- NOTE: the front-end sends openedAt/clickedAt as epoch ms — convert to ISO
-- in the API layer before insert.
CREATE TABLE "EmailJobRecipient" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "jobId" TEXT NOT NULL,
    "contactId" TEXT NOT NULL,
    "name" TEXT NOT NULL DEFAULT '',
    "email" TEXT NOT NULL,
    "typeId" TEXT,
    "lang" TEXT NOT NULL DEFAULT 'en',
    "sendAt" TIMESTAMP(3),
    "trackId" TEXT,
    "opened" BOOLEAN NOT NULL DEFAULT false,
    "openedAt" TIMESTAMP(3),
    "clicked" BOOLEAN NOT NULL DEFAULT false,
    "clickedUrl" TEXT,
    "clickedAt" TIMESTAMP(3),
    "subject" TEXT NOT NULL DEFAULT '',
    "body" TEXT NOT NULL DEFAULT '',
    "bodyHtml" TEXT,
    "unsubToken" TEXT,
    "unsubUrl" TEXT,
    "listUnsubscribe" TEXT,
    "listUnsubscribePost" TEXT,
    "providerMessageId" TEXT,
    "sendStatus" TEXT,
    "sentAt" TIMESTAMP(3),
    CONSTRAINT "EmailJobRecipient_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailJobRecipient_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailJobRecipient_jobId_fkey" FOREIGN KEY ("jobId")
        REFERENCES "EmailJob" ("id") ON DELETE CASCADE,
    CONSTRAINT "EmailJobRecipient_contactId_fkey" FOREIGN KEY ("contactId")
        REFERENCES "Contact" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "EmailJobRecipient_jobId_contactId_key"
    ON "EmailJobRecipient" ("jobId", "contactId");
CREATE INDEX "EmailJobRecipient_organizationId_sendAt_idx"
    ON "EmailJobRecipient" ("organizationId", "sendAt");
CREATE INDEX "EmailJobRecipient_trackId_idx" ON "EmailJobRecipient" ("trackId");


-- =============================================================================
-- PART 6 — EVENTS, AUDIT, NOTIFICATIONS
-- Append-only logs. Snapshot columns, no FKs — see header note.
-- =============================================================================

-- STATE.deliverEvents — the ESP webhook feed (Deliverability tab). "action"
-- is the classifier's human-readable outcome text; "suppressed" true when
-- THIS event added the address to EmailSuppression.
CREATE TABLE "DeliverabilityEvent" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "contactId" TEXT,
    "name" TEXT,
    "email" TEXT,
    "type" "DeliverabilityType" NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "action" TEXT,
    "suppressed" BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT "DeliverabilityEvent_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "DeliverabilityEvent_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE INDEX "DeliverabilityEvent_organizationId_at_idx"
    ON "DeliverabilityEvent" ("organizationId", "at");

-- STATE.clickEvents — one row per tracked link click (POST /clicks); feeds
-- the Clicks tab's by-job / by-contact / by-link rollups.
CREATE TABLE "EmailClickEvent" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "jobId" TEXT,
    "contactId" TEXT,
    "name" TEXT,
    "email" TEXT,
    "url" TEXT NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "EmailClickEvent_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailClickEvent_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE INDEX "EmailClickEvent_organizationId_jobId_idx"
    ON "EmailClickEvent" ("organizationId", "jobId");
CREATE INDEX "EmailClickEvent_organizationId_contactId_idx"
    ON "EmailClickEvent" ("organizationId", "contactId");

-- STATE.auditLog — the Audit Log tab (POST /audit). type today: 'send' |
-- 'open' | 'click' (auditLabel()); TEXT because new event types will grow.
-- "url" is set on clicks; "meta" is headroom.
CREATE TABLE "EmailAuditLog" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "jobId" TEXT,
    "contactId" TEXT,
    "name" TEXT,
    "email" TEXT,
    "templateName" TEXT,
    "url" TEXT,
    "meta" JSONB,
    CONSTRAINT "EmailAuditLog_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailAuditLog_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE INDEX "EmailAuditLog_organizationId_at_idx" ON "EmailAuditLog" ("organizationId", "at");
CREATE INDEX "EmailAuditLog_organizationId_type_idx" ON "EmailAuditLog" ("organizationId", "type");
CREATE INDEX "EmailAuditLog_organizationId_jobId_idx" ON "EmailAuditLog" ("organizationId", "jobId");

-- STATE.notify — "notify me when a contact opens" preferences, resolved
-- most-specific-first: contact row → type row → the single 'all' row
-- (effectiveNotify()). scope 'all' has refId NULL. channel today: 'off' |
-- 'desktop' | 'email' (TEXT — 'sms' is on the roadmap).
-- PUT /notify-prefs upserts; DELETE /notify-prefs/:scope/:id resets to inherit.
CREATE TABLE "NotifyPref" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "scope" TEXT NOT NULL CHECK ("scope" IN ('all', 'type', 'contact')),
    "refId" TEXT,
    "channel" TEXT NOT NULL DEFAULT 'off',
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "NotifyPref_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "NotifyPref_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "NotifyPref_organizationId_scope_refId_key"
    ON "NotifyPref" ("organizationId", "scope", (COALESCE("refId", '')));

-- STATE.notifLog — fired open-notifications (in-app feed). Merge:
-- unified NotificationLog.
CREATE TABLE "EmailNotifLog" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL,
    "at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "contactId" TEXT,
    "channel" TEXT,
    "title" TEXT,
    "body" TEXT,
    CONSTRAINT "EmailNotifLog_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "EmailNotifLog_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);


-- =============================================================================
-- PART 7 — SETTINGS
-- Singleton config documents as key/value rows (mirrors unified OrgSetting —
-- new settings never need a migration). The value is stored EXACTLY as the
-- front-end state holds it, so GET/PUT round-trip verbatim.
--   key 'freqCap'       -> {enabled, maxPerWindow, windowDays, minGapHours}
--   key 'quietHours'    -> {enabled, startHour, endHour}
--   key 'businessHours' -> {enabled, startHour, endHour}
--   key 'footer'        -> {enabled, orgName, logoText, address}
--   key 'unsubPage'     -> {emailSubject, emailBody}
--   key 'stopReply'     -> JSON string (the SMS STOP auto-reply text)
-- PUT /settings/:key replaces the value. At merge these rows move into
-- OrgSetting under clusterEmail.* keys.
-- =============================================================================

CREATE TABLE "Setting" (
    "organizationId" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "value" JSONB NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "Setting_pkey" PRIMARY KEY ("organizationId", "key"),
    CONSTRAINT "Setting_organizationId_fkey" FOREIGN KEY ("organizationId")
        REFERENCES "Organization" ("id") ON DELETE CASCADE
);


-- =============================================================================
-- PART 8 — DUE-WORK VIEW
-- One indexed query for the backend's sender loop: every recipient whose
-- send is due, on a job that is still queued, whose address is not
-- suppressed. Poll it every minute, send, stamp sentAt/sendStatus, and mark
-- the job 'sent' when its last recipient goes out. (Category opt-out
-- filtering already happened at queue time in clusterRecipients(); the
-- suppression re-check here catches addresses suppressed AFTER queueing.)
-- Mirrors the unified schema's vDueAutomationWork due-state pattern.
-- =============================================================================

CREATE VIEW "vDueEmailSends" AS
SELECT r."id"             AS "recipientId",
       r."organizationId",
       r."jobId",
       r."contactId",
       r."email",
       r."subject",
       r."body",
       r."bodyHtml",
       r."listUnsubscribe",
       r."listUnsubscribePost",
       r."sendAt",
       j."tracking",
       j."categoryId",
       j."templateName"
FROM "EmailJobRecipient" r
JOIN "EmailJob" j ON j."id" = r."jobId"
WHERE j."status" = 'queued'
  AND r."sentAt" IS NULL
  AND r."sendAt" <= CURRENT_TIMESTAMP
  AND NOT EXISTS (
        SELECT 1 FROM "EmailSuppression" s
        WHERE s."organizationId" = r."organizationId"
          AND s."email" = LOWER(TRIM(r."email"))
  );
-- =============================================================================
-- SEED — the HTML file's exact first-load state, generated headlessly from the
-- app's own seed functions (makeContacts, seedTriggers, seedDeliverability,
-- seedDemoJobs, seedClickEvents) on 2026-07-15T21:31:31.167Z.
-- Ships ON by default per the Credify seed-data rule. To rerun on a dirty DB:
-- drop + recreate the database, then re-run this whole file.
-- =============================================================================

BEGIN;

INSERT INTO "Organization" ("id", "name") VALUES
  ('org_demo', 'Push It, Inc. d/b/a Credify (demo)');

INSERT INTO "User" ("id", "organizationId", "name", "title") VALUES
  ('r_janet', 'org_demo', 'Janet Dobson', 'Director of Outreach'),
  ('r_paul', 'org_demo', 'Paul Pranav', 'Intake Coordinator'),
  ('r_balaji', 'org_demo', 'Balaji Miller', 'Care Coordinator'),
  ('r_taras', 'org_demo', 'Taras Pavlyk', 'Billing Specialist'),
  ('r_sheri', 'org_demo', 'Sherilynne', 'Care Coordinator');

INSERT INTO "ContactType" ("id", "organizationId", "label", "system", "sortOrder") VALUES
  ('ct_prospective_contact', 'org_demo', 'Prospective Contact', TRUE, 0),
  ('ct_contact', 'org_demo', 'Contact', TRUE, 1),
  ('ct_prospective_client', 'org_demo', 'Prospective Client', TRUE, 2),
  ('ct_client', 'org_demo', 'Client', TRUE, 3),
  ('ct_prospective_patient', 'org_demo', 'Prospective Patient', TRUE, 4),
  ('ct_patient', 'org_demo', 'Patient', TRUE, 5),
  ('ct_prospective_reseller', 'org_demo', 'Prospective Reseller', TRUE, 6),
  ('ct_reseller_partner', 'org_demo', 'Reseller Partner', TRUE, 7),
  ('ct_prospective_referral_source', 'org_demo', 'Prospective Referral Source', TRUE, 8),
  ('ct_referral_source_partner', 'org_demo', 'Referral Source Partner', TRUE, 9),
  ('ct_prospective_vendor', 'org_demo', 'Prospective Vendor', TRUE, 10),
  ('ct_vendor_partner', 'org_demo', 'Vendor Partner', TRUE, 11),
  ('ct_prospective_employee', 'org_demo', 'Prospective Employee', TRUE, 12),
  ('ct_employee', 'org_demo', 'Employee', TRUE, 13),
  ('ct_prospective_provider', 'org_demo', 'Prospective Provider', TRUE, 14),
  ('ct_provider', 'org_demo', 'Provider', TRUE, 15),
  ('ct_prospective_advisor', 'org_demo', 'Prospective Advisor', TRUE, 16),
  ('ct_advisor', 'org_demo', 'Advisor', TRUE, 17),
  ('ct_prospective_strategic_partner', 'org_demo', 'Prospective Strategic Partner', TRUE, 18),
  ('ct_strategic_partner', 'org_demo', 'Strategic Partner', TRUE, 19);

INSERT INTO "ActionType" ("id", "organizationId", "label") VALUES
  ('st_attempt', 'org_demo', 'Attempting Contact'),
  ('st_nurture', 'org_demo', 'Nurturing'),
  ('st_hot', 'org_demo', 'Hot Lead'),
  ('st_booked', 'org_demo', 'Appointment Booked'),
  ('st_noshow', 'org_demo', 'No-Show'),
  ('st_active', 'org_demo', 'Active Client'),
  ('st_hold', 'org_demo', 'On Hold'),
  ('st_won', 'org_demo', 'Closed-Won'),
  ('st_lost', 'org_demo', 'Closed-Lost'),
  ('st_unresp', 'org_demo', 'Unresponsive');

INSERT INTO "PipelineStage" ("id", "organizationId", "label", "sortOrder") VALUES
  ('stg_new', 'org_demo', 'New Lead', 0),
  ('stg_contacted', 'org_demo', 'Contacted', 1),
  ('stg_intake', 'org_demo', 'Intake Scheduled', 2),
  ('stg_treat', 'org_demo', 'In Treatment', 3),
  ('stg_disch', 'org_demo', 'Discharged', 4),
  ('stg_closed', 'org_demo', 'Closed', 5);

INSERT INTO "StageAction" ("id", "organizationId", "label") VALUES
  ('sa_vm', 'org_demo', 'Left Voicemail'),
  ('sa_packet', 'org_demo', 'Sent Intake Packet'),
  ('sa_verify', 'org_demo', 'Insurance Verified'),
  ('sa_booked', 'org_demo', 'Booked Appointment'),
  ('sa_intake', 'org_demo', 'Completed Intake'),
  ('sa_noshow', 'org_demo', 'No-Show Logged'),
  ('sa_dcsum', 'org_demo', 'Discharge Summary Sent');

INSERT INTO "LeadSource" ("id", "organizationId", "label") VALUES
  ('ls_web', 'org_demo', 'Website Form'),
  ('ls_gads', 'org_demo', 'Google Ads'),
  ('ls_pt', 'org_demo', 'Psychology Today'),
  ('ls_phys', 'org_demo', 'Physician Referral'),
  ('ls_ins', 'org_demo', 'Insurance Directory'),
  ('ls_meta', 'org_demo', 'Facebook / Meta'),
  ('ls_alum', 'org_demo', 'Referral — Alumni'),
  ('ls_call', 'org_demo', 'Walk-in / Call-in');

INSERT INTO "LeadType" ("id", "organizationId", "label") VALUES
  ('lt_self', 'org_demo', 'Self-Pay'),
  ('lt_comm', 'org_demo', 'Insurance (Commercial)'),
  ('lt_medi', 'org_demo', 'Medicaid'),
  ('lt_eap', 'org_demo', 'EAP'),
  ('lt_slide', 'org_demo', 'Sliding-Scale'),
  ('lt_grant', 'org_demo', 'Grant-Funded');

INSERT INTO "DistributionList" ("id", "organizationId", "label", "kind") VALUES
  ('bk_unassigned', 'org_demo', 'Unassigned', 'bucket'),
  ('bk_intake', 'org_demo', 'Intake Queue', 'bucket'),
  ('bk_overflow', 'org_demo', 'Overflow', 'bucket'),
  ('bk_vip', 'org_demo', 'VIP / Expedite', 'bucket'),
  ('bk_es', 'org_demo', 'Spanish-Speaking', 'bucket'),
  ('bk_ah', 'org_demo', 'After-Hours', 'bucket'),
  ('bk_reengage', 'org_demo', 'Re-Engagement', 'bucket');

INSERT INTO "DistributionRule" ("id", "organizationId", "label", "kind") VALUES
  ('dr_rr', 'org_demo', 'Round-Robin — Intake Team', 'distribution'),
  ('dr_ca', 'org_demo', 'By State — CA Team', 'distribution'),
  ('dr_paid', 'org_demo', 'By Source — Paid Ads', 'distribution'),
  ('dr_ins', 'org_demo', 'By Lead Type — Insurance', 'distribution'),
  ('dr_geo', 'org_demo', 'Geo — Pacific Time', 'distribution'),
  ('rr_48h', 'org_demo', 'No Contact 48h → Reassign', 'redistribution'),
  ('rr_pto', 'org_demo', 'Rep PTO Coverage', 'redistribution'),
  ('rr_stale', 'org_demo', 'Stale 7-Day Recycle', 'redistribution'),
  ('rr_decline', 'org_demo', 'Declined → Overflow', 'redistribution');

INSERT INTO "TouchRule" ("id", "organizationId", "label", "steps") VALUES
  ('tr_new5', 'org_demo', 'New-Lead 5-Touch', 5),
  ('tr_re3', 'org_demo', 'Re-Engagement 3-Touch', 3),
  ('tr_post', 'org_demo', 'Post-Intake Nurture', 4),
  ('tr_insfu', 'org_demo', 'Insurance Follow-Up', 3),
  ('tr_winback', 'org_demo', 'Win-Back 4-Touch', 4);

INSERT INTO "Form" ("id", "organizationId", "slug", "name", "category", "fields") VALUES
  ('form_demographics', 'org_demo', 'demographics', 'Patient Demographics Intake', 'Demographic', '[{"key":"first_name","label":"First Name","type":"text"},{"key":"mailing_notes","label":"Mailing Notes","type":"textarea"},{"key":"email","label":"Email Address","type":"email"},{"key":"mobile_phone","label":"Mobile Phone","type":"phone"},{"key":"age","label":"Age","type":"number"},{"key":"household_income","label":"Household Income","type":"currency"},{"key":"fpl_percent","label":"Household FPL %","type":"percent"},{"key":"dob","label":"Date of Birth","type":"date"},{"key":"preferred_call_time","label":"Preferred Call Time","type":"time"},{"key":"gender_identity","label":"Gender Identity","type":"select"},{"key":"languages","label":"Languages Spoken","type":"multiselect"},{"key":"marital_status","label":"Marital Status","type":"radio"},{"key":"consent_text","label":"Consent to Text","type":"checkbox"},{"key":"health_literacy","label":"Health Literacy","type":"rating"},{"key":"mobility_level","label":"Mobility Level","type":"scale"},{"key":"signature","label":"Patient Signature","type":"signature"},{"key":"photo_id","label":"Photo ID Upload","type":"file"},{"key":"home_address","label":"Home Address","type":"address"},{"key":"ssn","label":"SSN","type":"ssn"},{"key":"portal_url","label":"Patient Portal Link","type":"url"}]'::jsonb),
  ('form_financial', 'org_demo', 'financial', 'Financial & Billing Profile', 'Financial', '[{"key":"account_holder","label":"Account Holder Name","type":"text"},{"key":"billing_notes","label":"Billing Notes","type":"textarea"},{"key":"billing_email","label":"Billing Email","type":"email"},{"key":"billing_phone","label":"Billing Phone","type":"phone"},{"key":"dependents","label":"Dependents Claimed","type":"number"},{"key":"balance_due","label":"Outstanding Balance","type":"currency"},{"key":"discount_pct","label":"Sliding-Scale Discount","type":"percent"},{"key":"payment_due","label":"Next Payment Due","type":"date"},{"key":"statement_time","label":"Statement Send Time","type":"time"},{"key":"payment_method","label":"Payment Method","type":"select"},{"key":"coverage_types","label":"Coverage Types","type":"multiselect"},{"key":"billing_cycle","label":"Billing Cycle","type":"radio"},{"key":"autopay","label":"Autopay Enrolled","type":"checkbox"},{"key":"pay_reliability","label":"Payment Reliability","type":"rating"},{"key":"hardship_level","label":"Financial Hardship Level","type":"scale"},{"key":"fin_signature","label":"Financial Responsibility Signature","type":"signature"},{"key":"income_doc","label":"Income Verification Doc","type":"file"},{"key":"billing_address","label":"Billing Address","type":"address"},{"key":"tax_id","label":"Tax ID / SSN","type":"ssn"},{"key":"pay_url","label":"Payment Portal Link","type":"url"}]'::jsonb),
  ('form_insurance', 'org_demo', 'insurance', 'Insurance Verification', 'Insurance', '[{"key":"insurer_name","label":"Primary Insurer","type":"text"},{"key":"auth_notes","label":"Authorization Notes","type":"textarea"},{"key":"payer_email","label":"Payer Contact Email","type":"email"},{"key":"payer_phone","label":"Payer Phone","type":"phone"},{"key":"visits_authorized","label":"Visits Authorized","type":"number"},{"key":"copay","label":"Copay Amount","type":"currency"},{"key":"coinsurance_pct","label":"Coinsurance %","type":"percent"},{"key":"coverage_start","label":"Coverage Effective Date","type":"date"},{"key":"verify_time","label":"Verification Call Time","type":"time"},{"key":"plan_type","label":"Plan Type","type":"select"},{"key":"covered_services","label":"Covered Services","type":"multiselect"},{"key":"network_status","label":"Network Status","type":"radio"},{"key":"auth_required","label":"Auth Required","type":"checkbox"},{"key":"verify_confidence","label":"Verification Confidence","type":"rating"},{"key":"deductible_met","label":"Deductible Met","type":"scale"},{"key":"aob_signature","label":"Assignment of Benefits Signature","type":"signature"},{"key":"card_front","label":"Insurance Card (Front)","type":"file"},{"key":"payer_address","label":"Payer Mailing Address","type":"address"},{"key":"subscriber_ssn","label":"Subscriber SSN","type":"ssn"},{"key":"eligibility_url","label":"Eligibility Portal","type":"url"}]'::jsonb),
  ('form_clinical', 'org_demo', 'clinical', 'Clinical Intake & History', 'Clinical', '[{"key":"referring_provider","label":"Referring Provider","type":"text"},{"key":"presenting_concern","label":"Presenting Concern","type":"textarea"},{"key":"provider_email","label":"Provider Email","type":"email"},{"key":"emergency_phone","label":"Emergency Contact Phone","type":"phone"},{"key":"sessions_completed","label":"Sessions Completed","type":"number"},{"key":"self_pay_rate","label":"Self-Pay Rate","type":"currency"},{"key":"adherence_pct","label":"Treatment Adherence","type":"percent"},{"key":"intake_date","label":"Intake Date","type":"date"},{"key":"appt_time","label":"Appointment Time","type":"time"},{"key":"primary_dx","label":"Primary Diagnosis","type":"select"},{"key":"symptoms","label":"Symptoms Reported","type":"multiselect"},{"key":"risk_level","label":"Risk Level","type":"radio"},{"key":"telehealth_consent","label":"Telehealth Consent","type":"checkbox"},{"key":"phq9_severity","label":"PHQ-9 Severity","type":"rating"},{"key":"gad7_score","label":"GAD-7 Score","type":"scale"},{"key":"clinician_sig","label":"Clinician Signature","type":"signature"},{"key":"prior_records","label":"Prior Records Upload","type":"file"},{"key":"emergency_address","label":"Emergency Contact Address","type":"address"},{"key":"patient_ssn","label":"Patient SSN","type":"ssn"},{"key":"care_plan_url","label":"Care Plan Link","type":"url"}]'::jsonb),
  ('form_consent', 'org_demo', 'consent', 'Consent & Authorization', 'Consent', '[{"key":"signer_name","label":"Signer Full Name","type":"text"},{"key":"special_instructions","label":"Special Instructions","type":"textarea"},{"key":"confirm_email","label":"Confirmation Email","type":"email"},{"key":"contact_phone","label":"Contact Phone","type":"phone"},{"key":"auth_term","label":"Authorization Term (months)","type":"number"},{"key":"service_estimate","label":"Service Estimate","type":"currency"},{"key":"deposit_pct","label":"Deposit Required","type":"percent"},{"key":"consent_date","label":"Consent Date","type":"date"},{"key":"reminder_time","label":"Reminder Send Time","type":"time"},{"key":"contact_method","label":"Preferred Contact Method","type":"select"},{"key":"releases","label":"Releases Authorized","type":"multiselect"},{"key":"hipaa_ack","label":"HIPAA Acknowledgment","type":"radio"},{"key":"marketing_optin","label":"Marketing Opt-In","type":"checkbox"},{"key":"onboarding_satisfaction","label":"Onboarding Satisfaction","type":"rating"},{"key":"telehealth_comfort","label":"Comfort With Telehealth","type":"scale"},{"key":"auth_signature","label":"Authorizing Signature","type":"signature"},{"key":"consent_pdf","label":"Signed Consent PDF","type":"file"},{"key":"address_on_file","label":"Address on File","type":"address"},{"key":"ssn_last4","label":"Last 4 of SSN","type":"ssn"},{"key":"vault_url","label":"Document Vault Link","type":"url"}]'::jsonb);

INSERT INTO "EmailPrefCategory" ("id", "organizationId", "label", "kind", "description", "sortOrder") VALUES
  ('cat_appt', 'org_demo', 'Appointment reminders', 'transactional', 'Visit confirmations, reminders, and reschedules.', 0),
  ('cat_billing', 'org_demo', 'Billing & statements', 'transactional', 'Invoices, balances, and payment receipts.', 1),
  ('cat_care', 'org_demo', 'Care & clinical updates', 'transactional', 'Treatment plan, results, and care-team messages.', 2),
  ('cat_marketing', 'org_demo', 'Newsletters & marketing', 'marketing', 'Program news, tips, and promotions.', 3),
  ('cat_surveys', 'org_demo', 'Surveys & feedback', 'marketing', 'Satisfaction surveys and feedback requests.', 4),
  ('cat_events', 'org_demo', 'Events & workshops', 'marketing', 'Invitations to groups, classes, and events.', 5);

INSERT INTO "Contact" ("id", "organizationId", "firstName", "lastName", "name", "email", "phone", "street", "city", "zip", "tz", "lang", "typeId", "leadSourceId", "leadTypeId", "stageId", "statusId", "bucketId", "distributionRuleId", "assignedRepId", "redistributedById", "redistributedAt", "touchRuleId", "touchStep", "nextTouchDueAt", "lastStageActionId", "opens", "sends", "clicks", "openHistory", "peakHour", "softBounces", "bounceStatus", "lastBounceAt", "complainedAt", "formData") VALUES
  ('c1', 'org_demo', 'Maria', 'Alvarez', 'Maria Alvarez', 'malvarez@example.com', '(601) 555-0100', '4821 Texas St', 'San Diego, CA', '92116', 'America/Los_Angeles', 'en', 'ct_prospective_contact', 'ls_web', 'lt_comm', 'stg_new', 'st_booked', 'bk_intake', 'dr_rr', 'r_janet', 'rr_48h', '2026-07-14T21:31:31.151Z', 'tr_new5', 1, '2026-07-12T21:31:31.151Z', 'sa_verify', 45, 50, 1, '[0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,3,0,0]'::jsonb, 9, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Maria","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"malvarez@example.com","demographics.mobile_phone":"(601) 555-0100","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Maria Alvarez (e-signed)","demographics.photo_id":"uploaded_c1.pdf","demographics.home_address":"4821 Texas St, San Diego, CA 92116","demographics.ssn":"•••-••-1234","demographics.portal_url":"https://app.credifyfast.com/r/c1","financial.account_holder":"Maria Alvarez","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"malvarez@example.com","financial.billing_phone":"(601) 555-0100","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Maria Alvarez (e-signed)","financial.income_doc":"uploaded_c1.pdf","financial.billing_address":"4821 Texas St, San Diego, CA 92116","financial.tax_id":"•••-••-1234","financial.pay_url":"https://app.credifyfast.com/r/c1","insurance.insurer_name":"Maria Alvarez","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"malvarez@example.com","insurance.payer_phone":"(601) 555-0100","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Maria Alvarez (e-signed)","insurance.card_front":"uploaded_c1.pdf","insurance.payer_address":"4821 Texas St, San Diego, CA 92116","insurance.subscriber_ssn":"•••-••-1234","insurance.eligibility_url":"https://app.credifyfast.com/r/c1","clinical.referring_provider":"Maria Alvarez","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"malvarez@example.com","clinical.emergency_phone":"(601) 555-0100","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Maria Alvarez (e-signed)","clinical.prior_records":"uploaded_c1.pdf","clinical.emergency_address":"4821 Texas St, San Diego, CA 92116","clinical.patient_ssn":"•••-••-1234","clinical.care_plan_url":"https://app.credifyfast.com/r/c1","consent.signer_name":"Maria Alvarez","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"malvarez@example.com","consent.contact_phone":"(601) 555-0100","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Maria Alvarez (e-signed)","consent.consent_pdf":"uploaded_c1.pdf","consent.address_on_file":"4821 Texas St, San Diego, CA 92116","consent.ssn_last4":"•••-••-1234","consent.vault_url":"https://app.credifyfast.com/r/c1"}'::jsonb),
  ('c2', 'org_demo', 'James', 'Okafor', 'James Okafor', 'jokafor@example.com', '(602) 555-0101', '912 Grand Ave', 'Oakland, CA', '94610', 'America/Los_Angeles', 'es', 'ct_contact', 'ls_gads', 'lt_slide', 'stg_intake', 'st_attempt', 'bk_reengage', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 2, '2026-07-13T21:31:31.152Z', 'sa_vm', 45, 54, 1, '[0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,1,2,0]'::jsonb, 10, 0, 'ok', NULL, NULL, '{"demographics.first_name":"James","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"jokafor@example.com","demographics.mobile_phone":"(602) 555-0101","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"James Okafor (e-signed)","demographics.photo_id":"uploaded_c2.pdf","demographics.home_address":"912 Grand Ave, Oakland, CA 94610","demographics.ssn":"•••-••-1235","demographics.portal_url":"https://app.credifyfast.com/r/c2","financial.account_holder":"James Okafor","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"jokafor@example.com","financial.billing_phone":"(602) 555-0101","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"James Okafor (e-signed)","financial.income_doc":"uploaded_c2.pdf","financial.billing_address":"912 Grand Ave, Oakland, CA 94610","financial.tax_id":"•••-••-1235","financial.pay_url":"https://app.credifyfast.com/r/c2","insurance.insurer_name":"James Okafor","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"jokafor@example.com","insurance.payer_phone":"(602) 555-0101","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"James Okafor (e-signed)","insurance.card_front":"uploaded_c2.pdf","insurance.payer_address":"912 Grand Ave, Oakland, CA 94610","insurance.subscriber_ssn":"•••-••-1235","insurance.eligibility_url":"https://app.credifyfast.com/r/c2","clinical.referring_provider":"James Okafor","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"jokafor@example.com","clinical.emergency_phone":"(602) 555-0101","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"James Okafor (e-signed)","clinical.prior_records":"uploaded_c2.pdf","clinical.emergency_address":"912 Grand Ave, Oakland, CA 94610","clinical.patient_ssn":"•••-••-1235","clinical.care_plan_url":"https://app.credifyfast.com/r/c2","consent.signer_name":"James Okafor","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"jokafor@example.com","consent.contact_phone":"(602) 555-0101","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"James Okafor (e-signed)","consent.consent_pdf":"uploaded_c2.pdf","consent.address_on_file":"912 Grand Ave, Oakland, CA 94610","consent.ssn_last4":"•••-••-1235","consent.vault_url":"https://app.credifyfast.com/r/c2"}'::jsonb),
  ('c3', 'org_demo', 'Priya', 'Nair', 'Priya Nair', 'pnair@example.com', '(603) 555-0102', '330 Pine St', 'Seattle, WA', '98101', 'America/Los_Angeles', 'en', 'ct_prospective_client', 'ls_pt', 'lt_comm', 'stg_disch', 'st_won', 'bk_es', 'dr_paid', 'r_sheri', NULL, NULL, 'tr_insfu', 3, '2026-07-14T21:31:31.152Z', 'sa_noshow', 45, 58, 0, '[0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,1,0,0]'::jsonb, 8, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Priya","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"pnair@example.com","demographics.mobile_phone":"(603) 555-0102","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Priya Nair (e-signed)","demographics.photo_id":"uploaded_c3.pdf","demographics.home_address":"330 Pine St, Seattle, WA 98101","demographics.ssn":"•••-••-1236","demographics.portal_url":"https://app.credifyfast.com/r/c3","financial.account_holder":"Priya Nair","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"pnair@example.com","financial.billing_phone":"(603) 555-0102","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Priya Nair (e-signed)","financial.income_doc":"uploaded_c3.pdf","financial.billing_address":"330 Pine St, Seattle, WA 98101","financial.tax_id":"•••-••-1236","financial.pay_url":"https://app.credifyfast.com/r/c3","insurance.insurer_name":"Priya Nair","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"pnair@example.com","insurance.payer_phone":"(603) 555-0102","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Priya Nair (e-signed)","insurance.card_front":"uploaded_c3.pdf","insurance.payer_address":"330 Pine St, Seattle, WA 98101","insurance.subscriber_ssn":"•••-••-1236","insurance.eligibility_url":"https://app.credifyfast.com/r/c3","clinical.referring_provider":"Priya Nair","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"pnair@example.com","clinical.emergency_phone":"(603) 555-0102","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Priya Nair (e-signed)","clinical.prior_records":"uploaded_c3.pdf","clinical.emergency_address":"330 Pine St, Seattle, WA 98101","clinical.patient_ssn":"•••-••-1236","clinical.care_plan_url":"https://app.credifyfast.com/r/c3","consent.signer_name":"Priya Nair","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"pnair@example.com","consent.contact_phone":"(603) 555-0102","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Priya Nair (e-signed)","consent.consent_pdf":"uploaded_c3.pdf","consent.address_on_file":"330 Pine St, Seattle, WA 98101","consent.ssn_last4":"•••-••-1236","consent.vault_url":"https://app.credifyfast.com/r/c3"}'::jsonb),
  ('c4', 'org_demo', 'Daniel', 'Whitman', 'Daniel Whitman', 'dwhitman@example.com', '(604) 555-0103', '55 W Monroe St', 'Chicago, IL', '60603', 'America/Chicago', 'en', 'ct_client', 'ls_phys', 'lt_slide', 'stg_new', 'st_noshow', 'bk_overflow', 'dr_ins', 'r_paul', NULL, NULL, 'tr_post', 4, '2026-07-15T21:31:31.152Z', 'sa_booked', 44, 61, 0, '[0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0]'::jsonb, 13, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Daniel","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"dwhitman@example.com","demographics.mobile_phone":"(604) 555-0103","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Daniel Whitman (e-signed)","demographics.photo_id":"uploaded_c4.pdf","demographics.home_address":"55 W Monroe St, Chicago, IL 60603","demographics.ssn":"•••-••-1237","demographics.portal_url":"https://app.credifyfast.com/r/c4","financial.account_holder":"Daniel Whitman","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"dwhitman@example.com","financial.billing_phone":"(604) 555-0103","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Daniel Whitman (e-signed)","financial.income_doc":"uploaded_c4.pdf","financial.billing_address":"55 W Monroe St, Chicago, IL 60603","financial.tax_id":"•••-••-1237","financial.pay_url":"https://app.credifyfast.com/r/c4","insurance.insurer_name":"Daniel Whitman","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"dwhitman@example.com","insurance.payer_phone":"(604) 555-0103","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Daniel Whitman (e-signed)","insurance.card_front":"uploaded_c4.pdf","insurance.payer_address":"55 W Monroe St, Chicago, IL 60603","insurance.subscriber_ssn":"•••-••-1237","insurance.eligibility_url":"https://app.credifyfast.com/r/c4","clinical.referring_provider":"Daniel Whitman","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"dwhitman@example.com","clinical.emergency_phone":"(604) 555-0103","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Daniel Whitman (e-signed)","clinical.prior_records":"uploaded_c4.pdf","clinical.emergency_address":"55 W Monroe St, Chicago, IL 60603","clinical.patient_ssn":"•••-••-1237","clinical.care_plan_url":"https://app.credifyfast.com/r/c4","consent.signer_name":"Daniel Whitman","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"dwhitman@example.com","consent.contact_phone":"(604) 555-0103","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Daniel Whitman (e-signed)","consent.consent_pdf":"uploaded_c4.pdf","consent.address_on_file":"55 W Monroe St, Chicago, IL 60603","consent.ssn_last4":"•••-••-1237","consent.vault_url":"https://app.credifyfast.com/r/c4"}'::jsonb),
  ('c5', 'org_demo', 'Sofia', 'Reyes', 'Sofia Reyes', 'sreyes@example.com', '(605) 555-0104', '2100 N Central Ave', 'Phoenix, AZ', '85004', 'America/Phoenix', 'en', 'ct_prospective_patient', 'ls_ins', 'lt_comm', 'stg_intake', 'st_nurture', 'bk_unassigned', 'dr_geo', 'r_taras', 'rr_48h', '2026-07-10T21:31:31.152Z', NULL, 0, NULL, 'sa_packet', 45, 66, 1, '[0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,1,0,0]'::jsonb, 16, 2, 'soft', '2026-07-12T21:31:31.158Z', NULL, '{"demographics.first_name":"Sofia","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"sreyes@example.com","demographics.mobile_phone":"(605) 555-0104","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Sofia Reyes (e-signed)","demographics.photo_id":"uploaded_c5.pdf","demographics.home_address":"2100 N Central Ave, Phoenix, AZ 85004","demographics.ssn":"•••-••-1238","demographics.portal_url":"https://app.credifyfast.com/r/c5","financial.account_holder":"Sofia Reyes","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"sreyes@example.com","financial.billing_phone":"(605) 555-0104","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Sofia Reyes (e-signed)","financial.income_doc":"uploaded_c5.pdf","financial.billing_address":"2100 N Central Ave, Phoenix, AZ 85004","financial.tax_id":"•••-••-1238","financial.pay_url":"https://app.credifyfast.com/r/c5","insurance.insurer_name":"Sofia Reyes","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"sreyes@example.com","insurance.payer_phone":"(605) 555-0104","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Sofia Reyes (e-signed)","insurance.card_front":"uploaded_c5.pdf","insurance.payer_address":"2100 N Central Ave, Phoenix, AZ 85004","insurance.subscriber_ssn":"•••-••-1238","insurance.eligibility_url":"https://app.credifyfast.com/r/c5","clinical.referring_provider":"Sofia Reyes","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"sreyes@example.com","clinical.emergency_phone":"(605) 555-0104","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Sofia Reyes (e-signed)","clinical.prior_records":"uploaded_c5.pdf","clinical.emergency_address":"2100 N Central Ave, Phoenix, AZ 85004","clinical.patient_ssn":"•••-••-1238","clinical.care_plan_url":"https://app.credifyfast.com/r/c5","consent.signer_name":"Sofia Reyes","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"sreyes@example.com","consent.contact_phone":"(605) 555-0104","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Sofia Reyes (e-signed)","consent.consent_pdf":"uploaded_c5.pdf","consent.address_on_file":"2100 N Central Ave, Phoenix, AZ 85004","consent.ssn_last4":"•••-••-1238","consent.vault_url":"https://app.credifyfast.com/r/c5"}'::jsonb),
  ('c6', 'org_demo', 'Aaron', 'Goldstein', 'Aaron Goldstein', 'agoldstein@example.com', '(606) 555-0105', '77 Beacon St', 'Boston, MA', '02108', 'America/New_York', 'es', 'ct_patient', 'ls_meta', 'lt_slide', 'stg_disch', 'st_lost', 'bk_ah', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-17T21:31:31.152Z', NULL, 45, 70, 0, '[0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,1,0,2]'::jsonb, 11, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Aaron","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"agoldstein@example.com","demographics.mobile_phone":"(606) 555-0105","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Aaron Goldstein (e-signed)","demographics.photo_id":"uploaded_c6.pdf","demographics.home_address":"77 Beacon St, Boston, MA 02108","demographics.ssn":"•••-••-1239","demographics.portal_url":"https://app.credifyfast.com/r/c6","financial.account_holder":"Aaron Goldstein","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"agoldstein@example.com","financial.billing_phone":"(606) 555-0105","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Aaron Goldstein (e-signed)","financial.income_doc":"uploaded_c6.pdf","financial.billing_address":"77 Beacon St, Boston, MA 02108","financial.tax_id":"•••-••-1239","financial.pay_url":"https://app.credifyfast.com/r/c6","insurance.insurer_name":"Aaron Goldstein","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"agoldstein@example.com","insurance.payer_phone":"(606) 555-0105","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Aaron Goldstein (e-signed)","insurance.card_front":"uploaded_c6.pdf","insurance.payer_address":"77 Beacon St, Boston, MA 02108","insurance.subscriber_ssn":"•••-••-1239","insurance.eligibility_url":"https://app.credifyfast.com/r/c6","clinical.referring_provider":"Aaron Goldstein","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"agoldstein@example.com","clinical.emergency_phone":"(606) 555-0105","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Aaron Goldstein (e-signed)","clinical.prior_records":"uploaded_c6.pdf","clinical.emergency_address":"77 Beacon St, Boston, MA 02108","clinical.patient_ssn":"•••-••-1239","clinical.care_plan_url":"https://app.credifyfast.com/r/c6","consent.signer_name":"Aaron Goldstein","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"agoldstein@example.com","consent.contact_phone":"(606) 555-0105","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Aaron Goldstein (e-signed)","consent.consent_pdf":"uploaded_c6.pdf","consent.address_on_file":"77 Beacon St, Boston, MA 02108","consent.ssn_last4":"•••-••-1239","consent.vault_url":"https://app.credifyfast.com/r/c6"}'::jsonb),
  ('c7', 'org_demo', 'Lena', 'Park', 'Lena Park', 'lpark@example.com', '(607) 555-0106', '410 Congress Ave', 'Austin, TX', '78701', 'America/Chicago', 'en', 'ct_prospective_reseller', 'ls_alum', 'lt_comm', 'stg_new', 'st_active', 'bk_vip', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 3, '2026-07-18T21:31:31.152Z', 'sa_intake', 44, 49, 0, '[0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0,0,0]'::jsonb, 7, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Lena","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"lpark@example.com","demographics.mobile_phone":"(607) 555-0106","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Lena Park (e-signed)","demographics.photo_id":"uploaded_c7.pdf","demographics.home_address":"410 Congress Ave, Austin, TX 78701","demographics.ssn":"•••-••-1240","demographics.portal_url":"https://app.credifyfast.com/r/c7","financial.account_holder":"Lena Park","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"lpark@example.com","financial.billing_phone":"(607) 555-0106","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Lena Park (e-signed)","financial.income_doc":"uploaded_c7.pdf","financial.billing_address":"410 Congress Ave, Austin, TX 78701","financial.tax_id":"•••-••-1240","financial.pay_url":"https://app.credifyfast.com/r/c7","insurance.insurer_name":"Lena Park","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"lpark@example.com","insurance.payer_phone":"(607) 555-0106","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Lena Park (e-signed)","insurance.card_front":"uploaded_c7.pdf","insurance.payer_address":"410 Congress Ave, Austin, TX 78701","insurance.subscriber_ssn":"•••-••-1240","insurance.eligibility_url":"https://app.credifyfast.com/r/c7","clinical.referring_provider":"Lena Park","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"lpark@example.com","clinical.emergency_phone":"(607) 555-0106","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Lena Park (e-signed)","clinical.prior_records":"uploaded_c7.pdf","clinical.emergency_address":"410 Congress Ave, Austin, TX 78701","clinical.patient_ssn":"•••-••-1240","clinical.care_plan_url":"https://app.credifyfast.com/r/c7","consent.signer_name":"Lena Park","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"lpark@example.com","consent.contact_phone":"(607) 555-0106","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Lena Park (e-signed)","consent.consent_pdf":"uploaded_c7.pdf","consent.address_on_file":"410 Congress Ave, Austin, TX 78701","consent.ssn_last4":"•••-••-1240","consent.vault_url":"https://app.credifyfast.com/r/c7"}'::jsonb),
  ('c8', 'org_demo', 'Marcus', 'Bauer', 'Marcus Bauer', 'mbauer@example.com', '(608) 555-0107', '1600 Glenarm Pl', 'Denver, CO', '80202', 'America/Denver', 'en', 'ct_reseller_partner', 'ls_call', 'lt_slide', 'stg_intake', 'st_hot', 'bk_intake', 'dr_paid', 'r_sheri', NULL, NULL, 'tr_insfu', 2, '2026-07-12T21:31:31.152Z', 'sa_verify', 44, 53, 0, '[0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0]'::jsonb, 14, 0, 'hard', '2026-07-10T21:31:31.158Z', NULL, '{"demographics.first_name":"Marcus","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"mbauer@example.com","demographics.mobile_phone":"(608) 555-0107","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"Marcus Bauer (e-signed)","demographics.photo_id":"uploaded_c8.pdf","demographics.home_address":"1600 Glenarm Pl, Denver, CO 80202","demographics.ssn":"•••-••-1241","demographics.portal_url":"https://app.credifyfast.com/r/c8","financial.account_holder":"Marcus Bauer","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"mbauer@example.com","financial.billing_phone":"(608) 555-0107","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"Marcus Bauer (e-signed)","financial.income_doc":"uploaded_c8.pdf","financial.billing_address":"1600 Glenarm Pl, Denver, CO 80202","financial.tax_id":"•••-••-1241","financial.pay_url":"https://app.credifyfast.com/r/c8","insurance.insurer_name":"Marcus Bauer","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"mbauer@example.com","insurance.payer_phone":"(608) 555-0107","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"Marcus Bauer (e-signed)","insurance.card_front":"uploaded_c8.pdf","insurance.payer_address":"1600 Glenarm Pl, Denver, CO 80202","insurance.subscriber_ssn":"•••-••-1241","insurance.eligibility_url":"https://app.credifyfast.com/r/c8","clinical.referring_provider":"Marcus Bauer","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"mbauer@example.com","clinical.emergency_phone":"(608) 555-0107","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"Marcus Bauer (e-signed)","clinical.prior_records":"uploaded_c8.pdf","clinical.emergency_address":"1600 Glenarm Pl, Denver, CO 80202","clinical.patient_ssn":"•••-••-1241","clinical.care_plan_url":"https://app.credifyfast.com/r/c8","consent.signer_name":"Marcus Bauer","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"mbauer@example.com","consent.contact_phone":"(608) 555-0107","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"Marcus Bauer (e-signed)","consent.consent_pdf":"uploaded_c8.pdf","consent.address_on_file":"1600 Glenarm Pl, Denver, CO 80202","consent.ssn_last4":"•••-••-1241","consent.vault_url":"https://app.credifyfast.com/r/c8"}'::jsonb),
  ('c9', 'org_demo', 'Aisha', 'Khan', 'Aisha Khan', 'akhan@example.com', '(609) 555-0108', '4821 Texas St', 'San Diego, CA', '92116', 'America/Los_Angeles', 'en', 'ct_prospective_referral_source', 'ls_web', 'lt_comm', 'stg_disch', 'st_unresp', 'bk_reengage', 'dr_ins', 'r_paul', 'rr_48h', '2026-07-06T21:31:31.153Z', 'tr_post', 1, '2026-07-13T21:31:31.153Z', 'sa_vm', 44, 57, 0, '[0,0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0]'::jsonb, 18, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Aisha","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"akhan@example.com","demographics.mobile_phone":"(609) 555-0108","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Aisha Khan (e-signed)","demographics.photo_id":"uploaded_c9.pdf","demographics.home_address":"4821 Texas St, San Diego, CA 92116","demographics.ssn":"•••-••-1242","demographics.portal_url":"https://app.credifyfast.com/r/c9","financial.account_holder":"Aisha Khan","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"akhan@example.com","financial.billing_phone":"(609) 555-0108","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Aisha Khan (e-signed)","financial.income_doc":"uploaded_c9.pdf","financial.billing_address":"4821 Texas St, San Diego, CA 92116","financial.tax_id":"•••-••-1242","financial.pay_url":"https://app.credifyfast.com/r/c9","insurance.insurer_name":"Aisha Khan","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"akhan@example.com","insurance.payer_phone":"(609) 555-0108","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Aisha Khan (e-signed)","insurance.card_front":"uploaded_c9.pdf","insurance.payer_address":"4821 Texas St, San Diego, CA 92116","insurance.subscriber_ssn":"•••-••-1242","insurance.eligibility_url":"https://app.credifyfast.com/r/c9","clinical.referring_provider":"Aisha Khan","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"akhan@example.com","clinical.emergency_phone":"(609) 555-0108","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Aisha Khan (e-signed)","clinical.prior_records":"uploaded_c9.pdf","clinical.emergency_address":"4821 Texas St, San Diego, CA 92116","clinical.patient_ssn":"•••-••-1242","clinical.care_plan_url":"https://app.credifyfast.com/r/c9","consent.signer_name":"Aisha Khan","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"akhan@example.com","consent.contact_phone":"(609) 555-0108","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Aisha Khan (e-signed)","consent.consent_pdf":"uploaded_c9.pdf","consent.address_on_file":"4821 Texas St, San Diego, CA 92116","consent.ssn_last4":"•••-••-1242","consent.vault_url":"https://app.credifyfast.com/r/c9"}'::jsonb),
  ('c10', 'org_demo', 'Noah', 'Reed', 'Noah Reed', 'nreed@example.com', '(610) 555-0109', '912 Grand Ave', 'Oakland, CA', '94610', 'America/Los_Angeles', 'es', 'ct_referral_source_partner', 'ls_gads', 'lt_slide', 'stg_new', 'st_hold', 'bk_es', 'dr_geo', 'r_taras', NULL, NULL, NULL, 0, NULL, 'sa_noshow', 44, 61, 0, '[2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0]'::jsonb, 12, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Noah","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"nreed@example.com","demographics.mobile_phone":"(610) 555-0109","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Noah Reed (e-signed)","demographics.photo_id":"uploaded_c10.pdf","demographics.home_address":"912 Grand Ave, Oakland, CA 94610","demographics.ssn":"•••-••-1243","demographics.portal_url":"https://app.credifyfast.com/r/c10","financial.account_holder":"Noah Reed","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"nreed@example.com","financial.billing_phone":"(610) 555-0109","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Noah Reed (e-signed)","financial.income_doc":"uploaded_c10.pdf","financial.billing_address":"912 Grand Ave, Oakland, CA 94610","financial.tax_id":"•••-••-1243","financial.pay_url":"https://app.credifyfast.com/r/c10","insurance.insurer_name":"Noah Reed","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"nreed@example.com","insurance.payer_phone":"(610) 555-0109","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Noah Reed (e-signed)","insurance.card_front":"uploaded_c10.pdf","insurance.payer_address":"912 Grand Ave, Oakland, CA 94610","insurance.subscriber_ssn":"•••-••-1243","insurance.eligibility_url":"https://app.credifyfast.com/r/c10","clinical.referring_provider":"Noah Reed","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"nreed@example.com","clinical.emergency_phone":"(610) 555-0109","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Noah Reed (e-signed)","clinical.prior_records":"uploaded_c10.pdf","clinical.emergency_address":"912 Grand Ave, Oakland, CA 94610","clinical.patient_ssn":"•••-••-1243","clinical.care_plan_url":"https://app.credifyfast.com/r/c10","consent.signer_name":"Noah Reed","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"nreed@example.com","consent.contact_phone":"(610) 555-0109","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Noah Reed (e-signed)","consent.consent_pdf":"uploaded_c10.pdf","consent.address_on_file":"912 Grand Ave, Oakland, CA 94610","consent.ssn_last4":"•••-••-1243","consent.vault_url":"https://app.credifyfast.com/r/c10"}'::jsonb),
  ('c11', 'org_demo', 'Elena', 'Petrova', 'Elena Petrova', 'epetrova@example.com', '(611) 555-0110', '330 Pine St', 'Seattle, WA', '98101', 'America/Los_Angeles', 'en', 'ct_prospective_vendor', 'ls_pt', 'lt_comm', 'stg_intake', 'st_booked', 'bk_overflow', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-15T21:31:31.153Z', 'sa_booked', 44, 65, 0, '[0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0]'::jsonb, 15, 0, 'ok', '2026-07-13T21:31:31.158Z', '2026-07-13T21:31:31.158Z', '{"demographics.first_name":"Elena","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"epetrova@example.com","demographics.mobile_phone":"(611) 555-0110","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Elena Petrova (e-signed)","demographics.photo_id":"uploaded_c11.pdf","demographics.home_address":"330 Pine St, Seattle, WA 98101","demographics.ssn":"•••-••-1244","demographics.portal_url":"https://app.credifyfast.com/r/c11","financial.account_holder":"Elena Petrova","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"epetrova@example.com","financial.billing_phone":"(611) 555-0110","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Elena Petrova (e-signed)","financial.income_doc":"uploaded_c11.pdf","financial.billing_address":"330 Pine St, Seattle, WA 98101","financial.tax_id":"•••-••-1244","financial.pay_url":"https://app.credifyfast.com/r/c11","insurance.insurer_name":"Elena Petrova","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"epetrova@example.com","insurance.payer_phone":"(611) 555-0110","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Elena Petrova (e-signed)","insurance.card_front":"uploaded_c11.pdf","insurance.payer_address":"330 Pine St, Seattle, WA 98101","insurance.subscriber_ssn":"•••-••-1244","insurance.eligibility_url":"https://app.credifyfast.com/r/c11","clinical.referring_provider":"Elena Petrova","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"epetrova@example.com","clinical.emergency_phone":"(611) 555-0110","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Elena Petrova (e-signed)","clinical.prior_records":"uploaded_c11.pdf","clinical.emergency_address":"330 Pine St, Seattle, WA 98101","clinical.patient_ssn":"•••-••-1244","clinical.care_plan_url":"https://app.credifyfast.com/r/c11","consent.signer_name":"Elena Petrova","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"epetrova@example.com","consent.contact_phone":"(611) 555-0110","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Elena Petrova (e-signed)","consent.consent_pdf":"uploaded_c11.pdf","consent.address_on_file":"330 Pine St, Seattle, WA 98101","consent.ssn_last4":"•••-••-1244","consent.vault_url":"https://app.credifyfast.com/r/c11"}'::jsonb),
  ('c12', 'org_demo', 'Tomas', 'Silva', 'Tomas Silva', 'tsilva@example.com', '(612) 555-0111', '55 W Monroe St', 'Chicago, IL', '60603', 'America/Chicago', 'en', 'ct_vendor_partner', 'ls_phys', 'lt_slide', 'stg_disch', 'st_attempt', 'bk_unassigned', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 4, '2026-07-16T21:31:31.153Z', NULL, 44, 69, 0, '[0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0]'::jsonb, 17, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Tomas","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"tsilva@example.com","demographics.mobile_phone":"(612) 555-0111","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Tomas Silva (e-signed)","demographics.photo_id":"uploaded_c12.pdf","demographics.home_address":"55 W Monroe St, Chicago, IL 60603","demographics.ssn":"•••-••-1245","demographics.portal_url":"https://app.credifyfast.com/r/c12","financial.account_holder":"Tomas Silva","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"tsilva@example.com","financial.billing_phone":"(612) 555-0111","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Tomas Silva (e-signed)","financial.income_doc":"uploaded_c12.pdf","financial.billing_address":"55 W Monroe St, Chicago, IL 60603","financial.tax_id":"•••-••-1245","financial.pay_url":"https://app.credifyfast.com/r/c12","insurance.insurer_name":"Tomas Silva","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"tsilva@example.com","insurance.payer_phone":"(612) 555-0111","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Tomas Silva (e-signed)","insurance.card_front":"uploaded_c12.pdf","insurance.payer_address":"55 W Monroe St, Chicago, IL 60603","insurance.subscriber_ssn":"•••-••-1245","insurance.eligibility_url":"https://app.credifyfast.com/r/c12","clinical.referring_provider":"Tomas Silva","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"tsilva@example.com","clinical.emergency_phone":"(612) 555-0111","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Tomas Silva (e-signed)","clinical.prior_records":"uploaded_c12.pdf","clinical.emergency_address":"55 W Monroe St, Chicago, IL 60603","clinical.patient_ssn":"•••-••-1245","clinical.care_plan_url":"https://app.credifyfast.com/r/c12","consent.signer_name":"Tomas Silva","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"tsilva@example.com","consent.contact_phone":"(612) 555-0111","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Tomas Silva (e-signed)","consent.consent_pdf":"uploaded_c12.pdf","consent.address_on_file":"55 W Monroe St, Chicago, IL 60603","consent.ssn_last4":"•••-••-1245","consent.vault_url":"https://app.credifyfast.com/r/c12"}'::jsonb),
  ('c13', 'org_demo', 'Grace', 'Owusu', 'Grace Owusu', 'gowusu@example.com', '(613) 555-0112', '2100 N Central Ave', 'Phoenix, AZ', '85004', 'America/Phoenix', 'en', 'ct_prospective_employee', 'ls_ins', 'lt_comm', 'stg_new', 'st_won', 'bk_ah', 'dr_paid', 'r_sheri', 'rr_48h', '2026-07-11T21:31:31.153Z', 'tr_insfu', 1, '2026-07-17T21:31:31.153Z', 'sa_dcsum', 44, 49, 0, '[0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0]'::jsonb, 9, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Grace","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"gowusu@example.com","demographics.mobile_phone":"(613) 555-0112","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Grace Owusu (e-signed)","demographics.photo_id":"uploaded_c13.pdf","demographics.home_address":"2100 N Central Ave, Phoenix, AZ 85004","demographics.ssn":"•••-••-1246","demographics.portal_url":"https://app.credifyfast.com/r/c13","financial.account_holder":"Grace Owusu","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"gowusu@example.com","financial.billing_phone":"(613) 555-0112","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Grace Owusu (e-signed)","financial.income_doc":"uploaded_c13.pdf","financial.billing_address":"2100 N Central Ave, Phoenix, AZ 85004","financial.tax_id":"•••-••-1246","financial.pay_url":"https://app.credifyfast.com/r/c13","insurance.insurer_name":"Grace Owusu","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"gowusu@example.com","insurance.payer_phone":"(613) 555-0112","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Grace Owusu (e-signed)","insurance.card_front":"uploaded_c13.pdf","insurance.payer_address":"2100 N Central Ave, Phoenix, AZ 85004","insurance.subscriber_ssn":"•••-••-1246","insurance.eligibility_url":"https://app.credifyfast.com/r/c13","clinical.referring_provider":"Grace Owusu","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"gowusu@example.com","clinical.emergency_phone":"(613) 555-0112","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Grace Owusu (e-signed)","clinical.prior_records":"uploaded_c13.pdf","clinical.emergency_address":"2100 N Central Ave, Phoenix, AZ 85004","clinical.patient_ssn":"•••-••-1246","clinical.care_plan_url":"https://app.credifyfast.com/r/c13","consent.signer_name":"Grace Owusu","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"gowusu@example.com","consent.contact_phone":"(613) 555-0112","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Grace Owusu (e-signed)","consent.consent_pdf":"uploaded_c13.pdf","consent.address_on_file":"2100 N Central Ave, Phoenix, AZ 85004","consent.ssn_last4":"•••-••-1246","consent.vault_url":"https://app.credifyfast.com/r/c13"}'::jsonb),
  ('c14', 'org_demo', 'Omar', 'Haddad', 'Omar Haddad', 'ohaddad@example.com', '(614) 555-0113', '77 Beacon St', 'Boston, MA', '02108', 'America/New_York', 'es', 'ct_employee', 'ls_meta', 'lt_slide', 'stg_intake', 'st_noshow', 'bk_vip', 'dr_ins', 'r_paul', NULL, NULL, 'tr_post', 2, '2026-07-18T21:31:31.153Z', 'sa_intake', 44, 53, 0, '[0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0]'::jsonb, 10, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Omar","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"ohaddad@example.com","demographics.mobile_phone":"(614) 555-0113","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"Omar Haddad (e-signed)","demographics.photo_id":"uploaded_c14.pdf","demographics.home_address":"77 Beacon St, Boston, MA 02108","demographics.ssn":"•••-••-1247","demographics.portal_url":"https://app.credifyfast.com/r/c14","financial.account_holder":"Omar Haddad","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"ohaddad@example.com","financial.billing_phone":"(614) 555-0113","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"Omar Haddad (e-signed)","financial.income_doc":"uploaded_c14.pdf","financial.billing_address":"77 Beacon St, Boston, MA 02108","financial.tax_id":"•••-••-1247","financial.pay_url":"https://app.credifyfast.com/r/c14","insurance.insurer_name":"Omar Haddad","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"ohaddad@example.com","insurance.payer_phone":"(614) 555-0113","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"Omar Haddad (e-signed)","insurance.card_front":"uploaded_c14.pdf","insurance.payer_address":"77 Beacon St, Boston, MA 02108","insurance.subscriber_ssn":"•••-••-1247","insurance.eligibility_url":"https://app.credifyfast.com/r/c14","clinical.referring_provider":"Omar Haddad","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"ohaddad@example.com","clinical.emergency_phone":"(614) 555-0113","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"Omar Haddad (e-signed)","clinical.prior_records":"uploaded_c14.pdf","clinical.emergency_address":"77 Beacon St, Boston, MA 02108","clinical.patient_ssn":"•••-••-1247","clinical.care_plan_url":"https://app.credifyfast.com/r/c14","consent.signer_name":"Omar Haddad","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"ohaddad@example.com","consent.contact_phone":"(614) 555-0113","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"Omar Haddad (e-signed)","consent.consent_pdf":"uploaded_c14.pdf","consent.address_on_file":"77 Beacon St, Boston, MA 02108","consent.ssn_last4":"•••-••-1247","consent.vault_url":"https://app.credifyfast.com/r/c14"}'::jsonb),
  ('c15', 'org_demo', 'Hannah', 'Brooks', 'Hannah Brooks', 'hbrooks@example.com', '(615) 555-0114', '410 Congress Ave', 'Austin, TX', '78701', 'America/Chicago', 'en', 'ct_prospective_provider', 'ls_alum', 'lt_comm', 'stg_disch', 'st_nurture', 'bk_intake', 'dr_geo', 'r_taras', NULL, NULL, NULL, 0, NULL, 'sa_verify', 44, 57, 0, '[0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0,0]'::jsonb, 8, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Hannah","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"hbrooks@example.com","demographics.mobile_phone":"(615) 555-0114","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Hannah Brooks (e-signed)","demographics.photo_id":"uploaded_c15.pdf","demographics.home_address":"410 Congress Ave, Austin, TX 78701","demographics.ssn":"•••-••-1248","demographics.portal_url":"https://app.credifyfast.com/r/c15","financial.account_holder":"Hannah Brooks","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"hbrooks@example.com","financial.billing_phone":"(615) 555-0114","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Hannah Brooks (e-signed)","financial.income_doc":"uploaded_c15.pdf","financial.billing_address":"410 Congress Ave, Austin, TX 78701","financial.tax_id":"•••-••-1248","financial.pay_url":"https://app.credifyfast.com/r/c15","insurance.insurer_name":"Hannah Brooks","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"hbrooks@example.com","insurance.payer_phone":"(615) 555-0114","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Hannah Brooks (e-signed)","insurance.card_front":"uploaded_c15.pdf","insurance.payer_address":"410 Congress Ave, Austin, TX 78701","insurance.subscriber_ssn":"•••-••-1248","insurance.eligibility_url":"https://app.credifyfast.com/r/c15","clinical.referring_provider":"Hannah Brooks","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"hbrooks@example.com","clinical.emergency_phone":"(615) 555-0114","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Hannah Brooks (e-signed)","clinical.prior_records":"uploaded_c15.pdf","clinical.emergency_address":"410 Congress Ave, Austin, TX 78701","clinical.patient_ssn":"•••-••-1248","clinical.care_plan_url":"https://app.credifyfast.com/r/c15","consent.signer_name":"Hannah Brooks","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"hbrooks@example.com","consent.contact_phone":"(615) 555-0114","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Hannah Brooks (e-signed)","consent.consent_pdf":"uploaded_c15.pdf","consent.address_on_file":"410 Congress Ave, Austin, TX 78701","consent.ssn_last4":"•••-••-1248","consent.vault_url":"https://app.credifyfast.com/r/c15"}'::jsonb),
  ('c16', 'org_demo', 'Diego', 'Mendez', 'Diego Mendez', 'dmendez@example.com', '(616) 555-0115', '1600 Glenarm Pl', 'Denver, CO', '80202', 'America/Denver', 'en', 'ct_provider', 'ls_call', 'lt_slide', 'stg_new', 'st_lost', 'bk_reengage', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-13T21:31:31.153Z', 'sa_vm', 44, 61, 0, '[0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0]'::jsonb, 13, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Diego","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"dmendez@example.com","demographics.mobile_phone":"(616) 555-0115","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Diego Mendez (e-signed)","demographics.photo_id":"uploaded_c16.pdf","demographics.home_address":"1600 Glenarm Pl, Denver, CO 80202","demographics.ssn":"•••-••-1249","demographics.portal_url":"https://app.credifyfast.com/r/c16","financial.account_holder":"Diego Mendez","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"dmendez@example.com","financial.billing_phone":"(616) 555-0115","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Diego Mendez (e-signed)","financial.income_doc":"uploaded_c16.pdf","financial.billing_address":"1600 Glenarm Pl, Denver, CO 80202","financial.tax_id":"•••-••-1249","financial.pay_url":"https://app.credifyfast.com/r/c16","insurance.insurer_name":"Diego Mendez","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"dmendez@example.com","insurance.payer_phone":"(616) 555-0115","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Diego Mendez (e-signed)","insurance.card_front":"uploaded_c16.pdf","insurance.payer_address":"1600 Glenarm Pl, Denver, CO 80202","insurance.subscriber_ssn":"•••-••-1249","insurance.eligibility_url":"https://app.credifyfast.com/r/c16","clinical.referring_provider":"Diego Mendez","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"dmendez@example.com","clinical.emergency_phone":"(616) 555-0115","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Diego Mendez (e-signed)","clinical.prior_records":"uploaded_c16.pdf","clinical.emergency_address":"1600 Glenarm Pl, Denver, CO 80202","clinical.patient_ssn":"•••-••-1249","clinical.care_plan_url":"https://app.credifyfast.com/r/c16","consent.signer_name":"Diego Mendez","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"dmendez@example.com","consent.contact_phone":"(616) 555-0115","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Diego Mendez (e-signed)","consent.consent_pdf":"uploaded_c16.pdf","consent.address_on_file":"1600 Glenarm Pl, Denver, CO 80202","consent.ssn_last4":"•••-••-1249","consent.vault_url":"https://app.credifyfast.com/r/c16"}'::jsonb),
  ('c17', 'org_demo', 'Yuki', 'Tanaka', 'Yuki Tanaka', 'ytanaka@example.com', '(617) 555-0116', '4821 Texas St', 'San Diego, CA', '92116', 'America/Los_Angeles', 'en', 'ct_prospective_advisor', 'ls_web', 'lt_comm', 'stg_intake', 'st_active', 'bk_es', 'dr_ca', 'r_balaji', 'rr_48h', '2026-07-07T21:31:31.153Z', 'tr_winback', 1, '2026-07-14T21:31:31.153Z', 'sa_noshow', 44, 65, 0, '[0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0]'::jsonb, 16, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Yuki","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"ytanaka@example.com","demographics.mobile_phone":"(617) 555-0116","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Yuki Tanaka (e-signed)","demographics.photo_id":"uploaded_c17.pdf","demographics.home_address":"4821 Texas St, San Diego, CA 92116","demographics.ssn":"•••-••-1250","demographics.portal_url":"https://app.credifyfast.com/r/c17","financial.account_holder":"Yuki Tanaka","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"ytanaka@example.com","financial.billing_phone":"(617) 555-0116","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Yuki Tanaka (e-signed)","financial.income_doc":"uploaded_c17.pdf","financial.billing_address":"4821 Texas St, San Diego, CA 92116","financial.tax_id":"•••-••-1250","financial.pay_url":"https://app.credifyfast.com/r/c17","insurance.insurer_name":"Yuki Tanaka","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"ytanaka@example.com","insurance.payer_phone":"(617) 555-0116","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Yuki Tanaka (e-signed)","insurance.card_front":"uploaded_c17.pdf","insurance.payer_address":"4821 Texas St, San Diego, CA 92116","insurance.subscriber_ssn":"•••-••-1250","insurance.eligibility_url":"https://app.credifyfast.com/r/c17","clinical.referring_provider":"Yuki Tanaka","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"ytanaka@example.com","clinical.emergency_phone":"(617) 555-0116","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Yuki Tanaka (e-signed)","clinical.prior_records":"uploaded_c17.pdf","clinical.emergency_address":"4821 Texas St, San Diego, CA 92116","clinical.patient_ssn":"•••-••-1250","clinical.care_plan_url":"https://app.credifyfast.com/r/c17","consent.signer_name":"Yuki Tanaka","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"ytanaka@example.com","consent.contact_phone":"(617) 555-0116","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Yuki Tanaka (e-signed)","consent.consent_pdf":"uploaded_c17.pdf","consent.address_on_file":"4821 Texas St, San Diego, CA 92116","consent.ssn_last4":"•••-••-1250","consent.vault_url":"https://app.credifyfast.com/r/c17"}'::jsonb),
  ('c18', 'org_demo', 'Ruth', 'Cohen', 'Ruth Cohen', 'rcohen@example.com', '(618) 555-0117', '912 Grand Ave', 'Oakland, CA', '94610', 'America/Los_Angeles', 'es', 'ct_advisor', 'ls_gads', 'lt_slide', 'stg_disch', 'st_hot', 'bk_overflow', 'dr_paid', 'r_sheri', NULL, NULL, 'tr_insfu', 3, '2026-07-15T21:31:31.154Z', NULL, 44, 69, 0, '[0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2]'::jsonb, 11, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Ruth","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"rcohen@example.com","demographics.mobile_phone":"(618) 555-0117","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Ruth Cohen (e-signed)","demographics.photo_id":"uploaded_c18.pdf","demographics.home_address":"912 Grand Ave, Oakland, CA 94610","demographics.ssn":"•••-••-1251","demographics.portal_url":"https://app.credifyfast.com/r/c18","financial.account_holder":"Ruth Cohen","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"rcohen@example.com","financial.billing_phone":"(618) 555-0117","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Ruth Cohen (e-signed)","financial.income_doc":"uploaded_c18.pdf","financial.billing_address":"912 Grand Ave, Oakland, CA 94610","financial.tax_id":"•••-••-1251","financial.pay_url":"https://app.credifyfast.com/r/c18","insurance.insurer_name":"Ruth Cohen","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"rcohen@example.com","insurance.payer_phone":"(618) 555-0117","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Ruth Cohen (e-signed)","insurance.card_front":"uploaded_c18.pdf","insurance.payer_address":"912 Grand Ave, Oakland, CA 94610","insurance.subscriber_ssn":"•••-••-1251","insurance.eligibility_url":"https://app.credifyfast.com/r/c18","clinical.referring_provider":"Ruth Cohen","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"rcohen@example.com","clinical.emergency_phone":"(618) 555-0117","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Ruth Cohen (e-signed)","clinical.prior_records":"uploaded_c18.pdf","clinical.emergency_address":"912 Grand Ave, Oakland, CA 94610","clinical.patient_ssn":"•••-••-1251","clinical.care_plan_url":"https://app.credifyfast.com/r/c18","consent.signer_name":"Ruth Cohen","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"rcohen@example.com","consent.contact_phone":"(618) 555-0117","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Ruth Cohen (e-signed)","consent.consent_pdf":"uploaded_c18.pdf","consent.address_on_file":"912 Grand Ave, Oakland, CA 94610","consent.ssn_last4":"•••-••-1251","consent.vault_url":"https://app.credifyfast.com/r/c18"}'::jsonb),
  ('c19', 'org_demo', 'Caleb', 'Wright', 'Caleb Wright', 'cwright@example.com', '(619) 555-0118', '330 Pine St', 'Seattle, WA', '98101', 'America/Los_Angeles', 'en', 'ct_prospective_strategic_partner', 'ls_pt', 'lt_comm', 'stg_new', 'st_unresp', 'bk_unassigned', 'dr_ins', 'r_paul', NULL, NULL, 'tr_post', 3, '2026-07-16T21:31:31.154Z', 'sa_packet', 44, 49, 0, '[0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0,0,0]'::jsonb, 7, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Caleb","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"cwright@example.com","demographics.mobile_phone":"(619) 555-0118","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Caleb Wright (e-signed)","demographics.photo_id":"uploaded_c19.pdf","demographics.home_address":"330 Pine St, Seattle, WA 98101","demographics.ssn":"•••-••-1252","demographics.portal_url":"https://app.credifyfast.com/r/c19","financial.account_holder":"Caleb Wright","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"cwright@example.com","financial.billing_phone":"(619) 555-0118","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Caleb Wright (e-signed)","financial.income_doc":"uploaded_c19.pdf","financial.billing_address":"330 Pine St, Seattle, WA 98101","financial.tax_id":"•••-••-1252","financial.pay_url":"https://app.credifyfast.com/r/c19","insurance.insurer_name":"Caleb Wright","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"cwright@example.com","insurance.payer_phone":"(619) 555-0118","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Caleb Wright (e-signed)","insurance.card_front":"uploaded_c19.pdf","insurance.payer_address":"330 Pine St, Seattle, WA 98101","insurance.subscriber_ssn":"•••-••-1252","insurance.eligibility_url":"https://app.credifyfast.com/r/c19","clinical.referring_provider":"Caleb Wright","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"cwright@example.com","clinical.emergency_phone":"(619) 555-0118","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Caleb Wright (e-signed)","clinical.prior_records":"uploaded_c19.pdf","clinical.emergency_address":"330 Pine St, Seattle, WA 98101","clinical.patient_ssn":"•••-••-1252","clinical.care_plan_url":"https://app.credifyfast.com/r/c19","consent.signer_name":"Caleb Wright","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"cwright@example.com","consent.contact_phone":"(619) 555-0118","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Caleb Wright (e-signed)","consent.consent_pdf":"uploaded_c19.pdf","consent.address_on_file":"330 Pine St, Seattle, WA 98101","consent.ssn_last4":"•••-••-1252","consent.vault_url":"https://app.credifyfast.com/r/c19"}'::jsonb),
  ('c20', 'org_demo', 'Nadia', 'Salim', 'Nadia Salim', 'nsalim@example.com', '(620) 555-0119', '55 W Monroe St', 'Chicago, IL', '60603', 'America/Chicago', 'en', 'ct_strategic_partner', 'ls_phys', 'lt_slide', 'stg_intake', 'st_hold', 'bk_ah', 'dr_geo', 'r_taras', NULL, NULL, NULL, 0, NULL, 'sa_dcsum', 44, 53, 0, '[0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0]'::jsonb, 14, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Nadia","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"nsalim@example.com","demographics.mobile_phone":"(620) 555-0119","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"Nadia Salim (e-signed)","demographics.photo_id":"uploaded_c20.pdf","demographics.home_address":"55 W Monroe St, Chicago, IL 60603","demographics.ssn":"•••-••-1253","demographics.portal_url":"https://app.credifyfast.com/r/c20","financial.account_holder":"Nadia Salim","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"nsalim@example.com","financial.billing_phone":"(620) 555-0119","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"Nadia Salim (e-signed)","financial.income_doc":"uploaded_c20.pdf","financial.billing_address":"55 W Monroe St, Chicago, IL 60603","financial.tax_id":"•••-••-1253","financial.pay_url":"https://app.credifyfast.com/r/c20","insurance.insurer_name":"Nadia Salim","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"nsalim@example.com","insurance.payer_phone":"(620) 555-0119","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"Nadia Salim (e-signed)","insurance.card_front":"uploaded_c20.pdf","insurance.payer_address":"55 W Monroe St, Chicago, IL 60603","insurance.subscriber_ssn":"•••-••-1253","insurance.eligibility_url":"https://app.credifyfast.com/r/c20","clinical.referring_provider":"Nadia Salim","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"nsalim@example.com","clinical.emergency_phone":"(620) 555-0119","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"Nadia Salim (e-signed)","clinical.prior_records":"uploaded_c20.pdf","clinical.emergency_address":"55 W Monroe St, Chicago, IL 60603","clinical.patient_ssn":"•••-••-1253","clinical.care_plan_url":"https://app.credifyfast.com/r/c20","consent.signer_name":"Nadia Salim","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"nsalim@example.com","consent.contact_phone":"(620) 555-0119","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"Nadia Salim (e-signed)","consent.consent_pdf":"uploaded_c20.pdf","consent.address_on_file":"55 W Monroe St, Chicago, IL 60603","consent.ssn_last4":"•••-••-1253","consent.vault_url":"https://app.credifyfast.com/r/c20"}'::jsonb),
  ('c21', 'org_demo', 'Ivan', 'Volkov', 'Ivan Volkov', 'ivolkov@example.com', '(621) 555-0120', '2100 N Central Ave', 'Phoenix, AZ', '85004', 'America/Phoenix', 'en', 'ct_prospective_contact', 'ls_ins', 'lt_comm', 'stg_disch', 'st_booked', 'bk_vip', 'dr_rr', 'r_janet', 'rr_48h', '2026-07-12T21:31:31.154Z', 'tr_new5', 1, '2026-07-18T21:31:31.154Z', 'sa_intake', 44, 57, 0, '[0,0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0]'::jsonb, 18, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Ivan","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"ivolkov@example.com","demographics.mobile_phone":"(621) 555-0120","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Ivan Volkov (e-signed)","demographics.photo_id":"uploaded_c21.pdf","demographics.home_address":"2100 N Central Ave, Phoenix, AZ 85004","demographics.ssn":"•••-••-1254","demographics.portal_url":"https://app.credifyfast.com/r/c21","financial.account_holder":"Ivan Volkov","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"ivolkov@example.com","financial.billing_phone":"(621) 555-0120","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Ivan Volkov (e-signed)","financial.income_doc":"uploaded_c21.pdf","financial.billing_address":"2100 N Central Ave, Phoenix, AZ 85004","financial.tax_id":"•••-••-1254","financial.pay_url":"https://app.credifyfast.com/r/c21","insurance.insurer_name":"Ivan Volkov","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"ivolkov@example.com","insurance.payer_phone":"(621) 555-0120","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Ivan Volkov (e-signed)","insurance.card_front":"uploaded_c21.pdf","insurance.payer_address":"2100 N Central Ave, Phoenix, AZ 85004","insurance.subscriber_ssn":"•••-••-1254","insurance.eligibility_url":"https://app.credifyfast.com/r/c21","clinical.referring_provider":"Ivan Volkov","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"ivolkov@example.com","clinical.emergency_phone":"(621) 555-0120","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Ivan Volkov (e-signed)","clinical.prior_records":"uploaded_c21.pdf","clinical.emergency_address":"2100 N Central Ave, Phoenix, AZ 85004","clinical.patient_ssn":"•••-••-1254","clinical.care_plan_url":"https://app.credifyfast.com/r/c21","consent.signer_name":"Ivan Volkov","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"ivolkov@example.com","consent.contact_phone":"(621) 555-0120","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Ivan Volkov (e-signed)","consent.consent_pdf":"uploaded_c21.pdf","consent.address_on_file":"2100 N Central Ave, Phoenix, AZ 85004","consent.ssn_last4":"•••-••-1254","consent.vault_url":"https://app.credifyfast.com/r/c21"}'::jsonb),
  ('c22', 'org_demo', 'Bianca', 'Costa', 'Bianca Costa', 'bcosta@example.com', '(622) 555-0121', '77 Beacon St', 'Boston, MA', '02108', 'America/New_York', 'es', 'ct_contact', 'ls_meta', 'lt_slide', 'stg_new', 'st_attempt', 'bk_intake', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 2, '2026-07-12T21:31:31.154Z', 'sa_verify', 44, 61, 0, '[2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0]'::jsonb, 12, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Bianca","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"bcosta@example.com","demographics.mobile_phone":"(622) 555-0121","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Bianca Costa (e-signed)","demographics.photo_id":"uploaded_c22.pdf","demographics.home_address":"77 Beacon St, Boston, MA 02108","demographics.ssn":"•••-••-1255","demographics.portal_url":"https://app.credifyfast.com/r/c22","financial.account_holder":"Bianca Costa","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"bcosta@example.com","financial.billing_phone":"(622) 555-0121","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Bianca Costa (e-signed)","financial.income_doc":"uploaded_c22.pdf","financial.billing_address":"77 Beacon St, Boston, MA 02108","financial.tax_id":"•••-••-1255","financial.pay_url":"https://app.credifyfast.com/r/c22","insurance.insurer_name":"Bianca Costa","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"bcosta@example.com","insurance.payer_phone":"(622) 555-0121","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Bianca Costa (e-signed)","insurance.card_front":"uploaded_c22.pdf","insurance.payer_address":"77 Beacon St, Boston, MA 02108","insurance.subscriber_ssn":"•••-••-1255","insurance.eligibility_url":"https://app.credifyfast.com/r/c22","clinical.referring_provider":"Bianca Costa","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"bcosta@example.com","clinical.emergency_phone":"(622) 555-0121","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Bianca Costa (e-signed)","clinical.prior_records":"uploaded_c22.pdf","clinical.emergency_address":"77 Beacon St, Boston, MA 02108","clinical.patient_ssn":"•••-••-1255","clinical.care_plan_url":"https://app.credifyfast.com/r/c22","consent.signer_name":"Bianca Costa","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"bcosta@example.com","consent.contact_phone":"(622) 555-0121","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Bianca Costa (e-signed)","consent.consent_pdf":"uploaded_c22.pdf","consent.address_on_file":"77 Beacon St, Boston, MA 02108","consent.ssn_last4":"•••-••-1255","consent.vault_url":"https://app.credifyfast.com/r/c22"}'::jsonb),
  ('c23', 'org_demo', 'Theo', 'Lang', 'Theo Lang', 'tlang@example.com', '(623) 555-0122', '410 Congress Ave', 'Austin, TX', '78701', 'America/Chicago', 'en', 'ct_prospective_client', 'ls_alum', 'lt_comm', 'stg_intake', 'st_won', 'bk_reengage', 'dr_paid', 'r_sheri', NULL, NULL, 'tr_insfu', 2, '2026-07-13T21:31:31.154Z', 'sa_vm', 44, 65, 0, '[0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0]'::jsonb, 15, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Theo","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"tlang@example.com","demographics.mobile_phone":"(623) 555-0122","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Theo Lang (e-signed)","demographics.photo_id":"uploaded_c23.pdf","demographics.home_address":"410 Congress Ave, Austin, TX 78701","demographics.ssn":"•••-••-1256","demographics.portal_url":"https://app.credifyfast.com/r/c23","financial.account_holder":"Theo Lang","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"tlang@example.com","financial.billing_phone":"(623) 555-0122","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Theo Lang (e-signed)","financial.income_doc":"uploaded_c23.pdf","financial.billing_address":"410 Congress Ave, Austin, TX 78701","financial.tax_id":"•••-••-1256","financial.pay_url":"https://app.credifyfast.com/r/c23","insurance.insurer_name":"Theo Lang","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"tlang@example.com","insurance.payer_phone":"(623) 555-0122","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Theo Lang (e-signed)","insurance.card_front":"uploaded_c23.pdf","insurance.payer_address":"410 Congress Ave, Austin, TX 78701","insurance.subscriber_ssn":"•••-••-1256","insurance.eligibility_url":"https://app.credifyfast.com/r/c23","clinical.referring_provider":"Theo Lang","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"tlang@example.com","clinical.emergency_phone":"(623) 555-0122","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Theo Lang (e-signed)","clinical.prior_records":"uploaded_c23.pdf","clinical.emergency_address":"410 Congress Ave, Austin, TX 78701","clinical.patient_ssn":"•••-••-1256","clinical.care_plan_url":"https://app.credifyfast.com/r/c23","consent.signer_name":"Theo Lang","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"tlang@example.com","consent.contact_phone":"(623) 555-0122","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Theo Lang (e-signed)","consent.consent_pdf":"uploaded_c23.pdf","consent.address_on_file":"410 Congress Ave, Austin, TX 78701","consent.ssn_last4":"•••-••-1256","consent.vault_url":"https://app.credifyfast.com/r/c23"}'::jsonb),
  ('c24', 'org_demo', 'Mei', 'Chen', 'Mei Chen', 'mchen@example.com', '(624) 555-0123', '1600 Glenarm Pl', 'Denver, CO', '80202', 'America/Denver', 'en', 'ct_client', 'ls_call', 'lt_slide', 'stg_disch', 'st_noshow', 'bk_es', 'dr_ins', 'r_paul', NULL, NULL, 'tr_post', 4, '2026-07-14T21:31:31.154Z', NULL, 44, 69, 0, '[0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0]'::jsonb, 17, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Mei","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"mchen@example.com","demographics.mobile_phone":"(624) 555-0123","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Mei Chen (e-signed)","demographics.photo_id":"uploaded_c24.pdf","demographics.home_address":"1600 Glenarm Pl, Denver, CO 80202","demographics.ssn":"•••-••-1257","demographics.portal_url":"https://app.credifyfast.com/r/c24","financial.account_holder":"Mei Chen","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"mchen@example.com","financial.billing_phone":"(624) 555-0123","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Mei Chen (e-signed)","financial.income_doc":"uploaded_c24.pdf","financial.billing_address":"1600 Glenarm Pl, Denver, CO 80202","financial.tax_id":"•••-••-1257","financial.pay_url":"https://app.credifyfast.com/r/c24","insurance.insurer_name":"Mei Chen","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"mchen@example.com","insurance.payer_phone":"(624) 555-0123","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Mei Chen (e-signed)","insurance.card_front":"uploaded_c24.pdf","insurance.payer_address":"1600 Glenarm Pl, Denver, CO 80202","insurance.subscriber_ssn":"•••-••-1257","insurance.eligibility_url":"https://app.credifyfast.com/r/c24","clinical.referring_provider":"Mei Chen","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"mchen@example.com","clinical.emergency_phone":"(624) 555-0123","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Mei Chen (e-signed)","clinical.prior_records":"uploaded_c24.pdf","clinical.emergency_address":"1600 Glenarm Pl, Denver, CO 80202","clinical.patient_ssn":"•••-••-1257","clinical.care_plan_url":"https://app.credifyfast.com/r/c24","consent.signer_name":"Mei Chen","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"mchen@example.com","consent.contact_phone":"(624) 555-0123","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Mei Chen (e-signed)","consent.consent_pdf":"uploaded_c24.pdf","consent.address_on_file":"1600 Glenarm Pl, Denver, CO 80202","consent.ssn_last4":"•••-••-1257","consent.vault_url":"https://app.credifyfast.com/r/c24"}'::jsonb),
  ('c25', 'org_demo', 'Andre', 'Dubois', 'Andre Dubois', 'adubois@example.com', '(625) 555-0124', '4821 Texas St', 'San Diego, CA', '92116', 'America/Los_Angeles', 'en', 'ct_prospective_patient', 'ls_web', 'lt_comm', 'stg_new', 'st_nurture', 'bk_overflow', 'dr_geo', 'r_taras', 'rr_48h', '2026-07-08T21:31:31.154Z', NULL, 0, NULL, 'sa_booked', 44, 49, 0, '[0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0]'::jsonb, 9, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Andre","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"adubois@example.com","demographics.mobile_phone":"(625) 555-0124","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Andre Dubois (e-signed)","demographics.photo_id":"uploaded_c25.pdf","demographics.home_address":"4821 Texas St, San Diego, CA 92116","demographics.ssn":"•••-••-1258","demographics.portal_url":"https://app.credifyfast.com/r/c25","financial.account_holder":"Andre Dubois","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"adubois@example.com","financial.billing_phone":"(625) 555-0124","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Andre Dubois (e-signed)","financial.income_doc":"uploaded_c25.pdf","financial.billing_address":"4821 Texas St, San Diego, CA 92116","financial.tax_id":"•••-••-1258","financial.pay_url":"https://app.credifyfast.com/r/c25","insurance.insurer_name":"Andre Dubois","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"adubois@example.com","insurance.payer_phone":"(625) 555-0124","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Andre Dubois (e-signed)","insurance.card_front":"uploaded_c25.pdf","insurance.payer_address":"4821 Texas St, San Diego, CA 92116","insurance.subscriber_ssn":"•••-••-1258","insurance.eligibility_url":"https://app.credifyfast.com/r/c25","clinical.referring_provider":"Andre Dubois","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"adubois@example.com","clinical.emergency_phone":"(625) 555-0124","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Andre Dubois (e-signed)","clinical.prior_records":"uploaded_c25.pdf","clinical.emergency_address":"4821 Texas St, San Diego, CA 92116","clinical.patient_ssn":"•••-••-1258","clinical.care_plan_url":"https://app.credifyfast.com/r/c25","consent.signer_name":"Andre Dubois","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"adubois@example.com","consent.contact_phone":"(625) 555-0124","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Andre Dubois (e-signed)","consent.consent_pdf":"uploaded_c25.pdf","consent.address_on_file":"4821 Texas St, San Diego, CA 92116","consent.ssn_last4":"•••-••-1258","consent.vault_url":"https://app.credifyfast.com/r/c25"}'::jsonb),
  ('c26', 'org_demo', 'Sara', 'Kim', 'Sara Kim', 'skim@example.com', '(626) 555-0125', '912 Grand Ave', 'Oakland, CA', '94610', 'America/Los_Angeles', 'es', 'ct_patient', 'ls_gads', 'lt_slide', 'stg_intake', 'st_lost', 'bk_unassigned', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-16T21:31:31.154Z', 'sa_packet', 44, 53, 0, '[0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0]'::jsonb, 10, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Sara","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"skim@example.com","demographics.mobile_phone":"(626) 555-0125","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"Sara Kim (e-signed)","demographics.photo_id":"uploaded_c26.pdf","demographics.home_address":"912 Grand Ave, Oakland, CA 94610","demographics.ssn":"•••-••-1259","demographics.portal_url":"https://app.credifyfast.com/r/c26","financial.account_holder":"Sara Kim","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"skim@example.com","financial.billing_phone":"(626) 555-0125","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"Sara Kim (e-signed)","financial.income_doc":"uploaded_c26.pdf","financial.billing_address":"912 Grand Ave, Oakland, CA 94610","financial.tax_id":"•••-••-1259","financial.pay_url":"https://app.credifyfast.com/r/c26","insurance.insurer_name":"Sara Kim","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"skim@example.com","insurance.payer_phone":"(626) 555-0125","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"Sara Kim (e-signed)","insurance.card_front":"uploaded_c26.pdf","insurance.payer_address":"912 Grand Ave, Oakland, CA 94610","insurance.subscriber_ssn":"•••-••-1259","insurance.eligibility_url":"https://app.credifyfast.com/r/c26","clinical.referring_provider":"Sara Kim","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"skim@example.com","clinical.emergency_phone":"(626) 555-0125","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"Sara Kim (e-signed)","clinical.prior_records":"uploaded_c26.pdf","clinical.emergency_address":"912 Grand Ave, Oakland, CA 94610","clinical.patient_ssn":"•••-••-1259","clinical.care_plan_url":"https://app.credifyfast.com/r/c26","consent.signer_name":"Sara Kim","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"skim@example.com","consent.contact_phone":"(626) 555-0125","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"Sara Kim (e-signed)","consent.consent_pdf":"uploaded_c26.pdf","consent.address_on_file":"912 Grand Ave, Oakland, CA 94610","consent.ssn_last4":"•••-••-1259","consent.vault_url":"https://app.credifyfast.com/r/c26"}'::jsonb),
  ('c27', 'org_demo', 'Luis', 'Romero', 'Luis Romero', 'lromero@example.com', '(627) 555-0126', '330 Pine St', 'Seattle, WA', '98101', 'America/Los_Angeles', 'en', 'ct_prospective_reseller', 'ls_pt', 'lt_comm', 'stg_disch', 'st_active', 'bk_ah', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 3, '2026-07-17T21:31:31.155Z', 'sa_dcsum', 44, 57, 0, '[0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0,0]'::jsonb, 8, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Luis","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"lromero@example.com","demographics.mobile_phone":"(627) 555-0126","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Luis Romero (e-signed)","demographics.photo_id":"uploaded_c27.pdf","demographics.home_address":"330 Pine St, Seattle, WA 98101","demographics.ssn":"•••-••-1260","demographics.portal_url":"https://app.credifyfast.com/r/c27","financial.account_holder":"Luis Romero","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"lromero@example.com","financial.billing_phone":"(627) 555-0126","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Luis Romero (e-signed)","financial.income_doc":"uploaded_c27.pdf","financial.billing_address":"330 Pine St, Seattle, WA 98101","financial.tax_id":"•••-••-1260","financial.pay_url":"https://app.credifyfast.com/r/c27","insurance.insurer_name":"Luis Romero","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"lromero@example.com","insurance.payer_phone":"(627) 555-0126","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Luis Romero (e-signed)","insurance.card_front":"uploaded_c27.pdf","insurance.payer_address":"330 Pine St, Seattle, WA 98101","insurance.subscriber_ssn":"•••-••-1260","insurance.eligibility_url":"https://app.credifyfast.com/r/c27","clinical.referring_provider":"Luis Romero","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"lromero@example.com","clinical.emergency_phone":"(627) 555-0126","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Luis Romero (e-signed)","clinical.prior_records":"uploaded_c27.pdf","clinical.emergency_address":"330 Pine St, Seattle, WA 98101","clinical.patient_ssn":"•••-••-1260","clinical.care_plan_url":"https://app.credifyfast.com/r/c27","consent.signer_name":"Luis Romero","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"lromero@example.com","consent.contact_phone":"(627) 555-0126","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Luis Romero (e-signed)","consent.consent_pdf":"uploaded_c27.pdf","consent.address_on_file":"330 Pine St, Seattle, WA 98101","consent.ssn_last4":"•••-••-1260","consent.vault_url":"https://app.credifyfast.com/r/c27"}'::jsonb),
  ('c28', 'org_demo', 'Farah', 'Aziz', 'Farah Aziz', 'faziz@example.com', '(628) 555-0127', '55 W Monroe St', 'Chicago, IL', '60603', 'America/Chicago', 'en', 'ct_reseller_partner', 'ls_phys', 'lt_slide', 'stg_new', 'st_hot', 'bk_vip', 'dr_paid', 'r_sheri', NULL, NULL, 'tr_insfu', 1, '2026-07-18T21:31:31.155Z', 'sa_intake', 44, 61, 0, '[0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0]'::jsonb, 13, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Farah","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"faziz@example.com","demographics.mobile_phone":"(628) 555-0127","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Farah Aziz (e-signed)","demographics.photo_id":"uploaded_c28.pdf","demographics.home_address":"55 W Monroe St, Chicago, IL 60603","demographics.ssn":"•••-••-1261","demographics.portal_url":"https://app.credifyfast.com/r/c28","financial.account_holder":"Farah Aziz","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"faziz@example.com","financial.billing_phone":"(628) 555-0127","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Farah Aziz (e-signed)","financial.income_doc":"uploaded_c28.pdf","financial.billing_address":"55 W Monroe St, Chicago, IL 60603","financial.tax_id":"•••-••-1261","financial.pay_url":"https://app.credifyfast.com/r/c28","insurance.insurer_name":"Farah Aziz","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"faziz@example.com","insurance.payer_phone":"(628) 555-0127","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Farah Aziz (e-signed)","insurance.card_front":"uploaded_c28.pdf","insurance.payer_address":"55 W Monroe St, Chicago, IL 60603","insurance.subscriber_ssn":"•••-••-1261","insurance.eligibility_url":"https://app.credifyfast.com/r/c28","clinical.referring_provider":"Farah Aziz","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"faziz@example.com","clinical.emergency_phone":"(628) 555-0127","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Farah Aziz (e-signed)","clinical.prior_records":"uploaded_c28.pdf","clinical.emergency_address":"55 W Monroe St, Chicago, IL 60603","clinical.patient_ssn":"•••-••-1261","clinical.care_plan_url":"https://app.credifyfast.com/r/c28","consent.signer_name":"Farah Aziz","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"faziz@example.com","consent.contact_phone":"(628) 555-0127","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Farah Aziz (e-signed)","consent.consent_pdf":"uploaded_c28.pdf","consent.address_on_file":"55 W Monroe St, Chicago, IL 60603","consent.ssn_last4":"•••-••-1261","consent.vault_url":"https://app.credifyfast.com/r/c28"}'::jsonb),
  ('c29', 'org_demo', 'Owen', 'Walsh', 'Owen Walsh', 'owalsh@example.com', '(629) 555-0128', '2100 N Central Ave', 'Phoenix, AZ', '85004', 'America/Phoenix', 'en', 'ct_prospective_referral_source', 'ls_ins', 'lt_comm', 'stg_intake', 'st_unresp', 'bk_intake', 'dr_ins', 'r_paul', 'rr_48h', '2026-07-13T21:31:31.155Z', 'tr_post', 1, '2026-07-12T21:31:31.155Z', 'sa_verify', 44, 65, 0, '[0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0]'::jsonb, 16, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Owen","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"owalsh@example.com","demographics.mobile_phone":"(629) 555-0128","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Owen Walsh (e-signed)","demographics.photo_id":"uploaded_c29.pdf","demographics.home_address":"2100 N Central Ave, Phoenix, AZ 85004","demographics.ssn":"•••-••-1262","demographics.portal_url":"https://app.credifyfast.com/r/c29","financial.account_holder":"Owen Walsh","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"owalsh@example.com","financial.billing_phone":"(629) 555-0128","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Owen Walsh (e-signed)","financial.income_doc":"uploaded_c29.pdf","financial.billing_address":"2100 N Central Ave, Phoenix, AZ 85004","financial.tax_id":"•••-••-1262","financial.pay_url":"https://app.credifyfast.com/r/c29","insurance.insurer_name":"Owen Walsh","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"owalsh@example.com","insurance.payer_phone":"(629) 555-0128","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Owen Walsh (e-signed)","insurance.card_front":"uploaded_c29.pdf","insurance.payer_address":"2100 N Central Ave, Phoenix, AZ 85004","insurance.subscriber_ssn":"•••-••-1262","insurance.eligibility_url":"https://app.credifyfast.com/r/c29","clinical.referring_provider":"Owen Walsh","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"owalsh@example.com","clinical.emergency_phone":"(629) 555-0128","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Owen Walsh (e-signed)","clinical.prior_records":"uploaded_c29.pdf","clinical.emergency_address":"2100 N Central Ave, Phoenix, AZ 85004","clinical.patient_ssn":"•••-••-1262","clinical.care_plan_url":"https://app.credifyfast.com/r/c29","consent.signer_name":"Owen Walsh","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"owalsh@example.com","consent.contact_phone":"(629) 555-0128","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Owen Walsh (e-signed)","consent.consent_pdf":"uploaded_c29.pdf","consent.address_on_file":"2100 N Central Ave, Phoenix, AZ 85004","consent.ssn_last4":"•••-••-1262","consent.vault_url":"https://app.credifyfast.com/r/c29"}'::jsonb),
  ('c30', 'org_demo', 'Tara', 'Singh', 'Tara Singh', 'tsingh@example.com', '(630) 555-0129', '77 Beacon St', 'Boston, MA', '02108', 'America/New_York', 'es', 'ct_referral_source_partner', 'ls_meta', 'lt_slide', 'stg_disch', 'st_hold', 'bk_reengage', 'dr_geo', 'r_taras', NULL, NULL, NULL, 0, NULL, NULL, 44, 69, 0, '[0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2]'::jsonb, 11, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Tara","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"tsingh@example.com","demographics.mobile_phone":"(630) 555-0129","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Tara Singh (e-signed)","demographics.photo_id":"uploaded_c30.pdf","demographics.home_address":"77 Beacon St, Boston, MA 02108","demographics.ssn":"•••-••-1263","demographics.portal_url":"https://app.credifyfast.com/r/c30","financial.account_holder":"Tara Singh","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"tsingh@example.com","financial.billing_phone":"(630) 555-0129","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Tara Singh (e-signed)","financial.income_doc":"uploaded_c30.pdf","financial.billing_address":"77 Beacon St, Boston, MA 02108","financial.tax_id":"•••-••-1263","financial.pay_url":"https://app.credifyfast.com/r/c30","insurance.insurer_name":"Tara Singh","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"tsingh@example.com","insurance.payer_phone":"(630) 555-0129","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Tara Singh (e-signed)","insurance.card_front":"uploaded_c30.pdf","insurance.payer_address":"77 Beacon St, Boston, MA 02108","insurance.subscriber_ssn":"•••-••-1263","insurance.eligibility_url":"https://app.credifyfast.com/r/c30","clinical.referring_provider":"Tara Singh","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"tsingh@example.com","clinical.emergency_phone":"(630) 555-0129","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Tara Singh (e-signed)","clinical.prior_records":"uploaded_c30.pdf","clinical.emergency_address":"77 Beacon St, Boston, MA 02108","clinical.patient_ssn":"•••-••-1263","clinical.care_plan_url":"https://app.credifyfast.com/r/c30","consent.signer_name":"Tara Singh","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"tsingh@example.com","consent.contact_phone":"(630) 555-0129","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Tara Singh (e-signed)","consent.consent_pdf":"uploaded_c30.pdf","consent.address_on_file":"77 Beacon St, Boston, MA 02108","consent.ssn_last4":"•••-••-1263","consent.vault_url":"https://app.credifyfast.com/r/c30"}'::jsonb),
  ('c31', 'org_demo', 'Kofi', 'Mensah', 'Kofi Mensah', 'kmensah@example.com', '(631) 555-0130', '410 Congress Ave', 'Austin, TX', '78701', 'America/Chicago', 'en', 'ct_prospective_vendor', 'ls_alum', 'lt_comm', 'stg_new', 'st_booked', 'bk_es', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-14T21:31:31.156Z', 'sa_noshow', 44, 49, 0, '[0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0,2,0,0,0,0]'::jsonb, 7, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Kofi","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"kmensah@example.com","demographics.mobile_phone":"(631) 555-0130","demographics.age":"42","demographics.household_income":"$48,200","demographics.fpl_percent":"138%","demographics.dob":"03/14/1968","demographics.preferred_call_time":"9:00 AM","demographics.gender_identity":"Female","demographics.languages":"English, Spanish","demographics.marital_status":"Married","demographics.consent_text":"Yes","demographics.health_literacy":"4 / 5","demographics.mobility_level":"7 / 10","demographics.signature":"Kofi Mensah (e-signed)","demographics.photo_id":"uploaded_c31.pdf","demographics.home_address":"410 Congress Ave, Austin, TX 78701","demographics.ssn":"•••-••-1264","demographics.portal_url":"https://app.credifyfast.com/r/c31","financial.account_holder":"Kofi Mensah","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"kmensah@example.com","financial.billing_phone":"(631) 555-0130","financial.dependents":"42","financial.balance_due":"$48,200","financial.discount_pct":"138%","financial.payment_due":"08/01/2026","financial.statement_time":"9:00 AM","financial.payment_method":"Female","financial.coverage_types":"English, Spanish","financial.billing_cycle":"Married","financial.autopay":"Yes","financial.pay_reliability":"4 / 5","financial.hardship_level":"7 / 10","financial.fin_signature":"Kofi Mensah (e-signed)","financial.income_doc":"uploaded_c31.pdf","financial.billing_address":"410 Congress Ave, Austin, TX 78701","financial.tax_id":"•••-••-1264","financial.pay_url":"https://app.credifyfast.com/r/c31","insurance.insurer_name":"Kofi Mensah","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"kmensah@example.com","insurance.payer_phone":"(631) 555-0130","insurance.visits_authorized":"42","insurance.copay":"$48,200","insurance.coinsurance_pct":"138%","insurance.coverage_start":"08/01/2026","insurance.verify_time":"9:00 AM","insurance.plan_type":"Female","insurance.covered_services":"English, Spanish","insurance.network_status":"Married","insurance.auth_required":"Yes","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"7 / 10","insurance.aob_signature":"Kofi Mensah (e-signed)","insurance.card_front":"uploaded_c31.pdf","insurance.payer_address":"410 Congress Ave, Austin, TX 78701","insurance.subscriber_ssn":"•••-••-1264","insurance.eligibility_url":"https://app.credifyfast.com/r/c31","clinical.referring_provider":"Kofi Mensah","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"kmensah@example.com","clinical.emergency_phone":"(631) 555-0130","clinical.sessions_completed":"42","clinical.self_pay_rate":"$48,200","clinical.adherence_pct":"138%","clinical.intake_date":"08/01/2026","clinical.appt_time":"9:00 AM","clinical.primary_dx":"Female","clinical.symptoms":"English, Spanish","clinical.risk_level":"Married","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"7 / 10","clinical.clinician_sig":"Kofi Mensah (e-signed)","clinical.prior_records":"uploaded_c31.pdf","clinical.emergency_address":"410 Congress Ave, Austin, TX 78701","clinical.patient_ssn":"•••-••-1264","clinical.care_plan_url":"https://app.credifyfast.com/r/c31","consent.signer_name":"Kofi Mensah","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"kmensah@example.com","consent.contact_phone":"(631) 555-0130","consent.auth_term":"42","consent.service_estimate":"$48,200","consent.deposit_pct":"138%","consent.consent_date":"08/01/2026","consent.reminder_time":"9:00 AM","consent.contact_method":"Female","consent.releases":"English, Spanish","consent.hipaa_ack":"Married","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"7 / 10","consent.auth_signature":"Kofi Mensah (e-signed)","consent.consent_pdf":"uploaded_c31.pdf","consent.address_on_file":"410 Congress Ave, Austin, TX 78701","consent.ssn_last4":"•••-••-1264","consent.vault_url":"https://app.credifyfast.com/r/c31"}'::jsonb),
  ('c32', 'org_demo', 'Ines', 'Lopez', 'Ines Lopez', 'ilopez@example.com', '(632) 555-0131', '1600 Glenarm Pl', 'Denver, CO', '80202', 'America/Denver', 'en', 'ct_vendor_partner', 'ls_call', 'lt_slide', 'stg_intake', 'st_attempt', 'bk_overflow', 'dr_ca', 'r_balaji', NULL, NULL, 'tr_winback', 4, '2026-07-15T21:31:31.157Z', 'sa_booked', 44, 53, 0, '[0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0]'::jsonb, 14, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Ines","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"ilopez@example.com","demographics.mobile_phone":"(632) 555-0131","demographics.age":"2","demographics.household_income":"$312.50","demographics.fpl_percent":"20%","demographics.dob":"07/02/1973","demographics.preferred_call_time":"1:30 PM","demographics.gender_identity":"Male","demographics.languages":"Medical, Dental","demographics.marital_status":"In-Network","demographics.consent_text":"No","demographics.health_literacy":"5 / 5","demographics.mobility_level":"60%","demographics.signature":"Ines Lopez (e-signed)","demographics.photo_id":"uploaded_c32.pdf","demographics.home_address":"1600 Glenarm Pl, Denver, CO 80202","demographics.ssn":"•••-••-1265","demographics.portal_url":"https://app.credifyfast.com/r/c32","financial.account_holder":"Ines Lopez","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"ilopez@example.com","financial.billing_phone":"(632) 555-0131","financial.dependents":"2","financial.balance_due":"$312.50","financial.discount_pct":"20%","financial.payment_due":"09/15/2026","financial.statement_time":"1:30 PM","financial.payment_method":"Male","financial.coverage_types":"Medical, Dental","financial.billing_cycle":"In-Network","financial.autopay":"No","financial.pay_reliability":"5 / 5","financial.hardship_level":"60%","financial.fin_signature":"Ines Lopez (e-signed)","financial.income_doc":"uploaded_c32.pdf","financial.billing_address":"1600 Glenarm Pl, Denver, CO 80202","financial.tax_id":"•••-••-1265","financial.pay_url":"https://app.credifyfast.com/r/c32","insurance.insurer_name":"Ines Lopez","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"ilopez@example.com","insurance.payer_phone":"(632) 555-0131","insurance.visits_authorized":"2","insurance.copay":"$312.50","insurance.coinsurance_pct":"20%","insurance.coverage_start":"09/15/2026","insurance.verify_time":"1:30 PM","insurance.plan_type":"Male","insurance.covered_services":"Medical, Dental","insurance.network_status":"In-Network","insurance.auth_required":"No","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"60%","insurance.aob_signature":"Ines Lopez (e-signed)","insurance.card_front":"uploaded_c32.pdf","insurance.payer_address":"1600 Glenarm Pl, Denver, CO 80202","insurance.subscriber_ssn":"•••-••-1265","insurance.eligibility_url":"https://app.credifyfast.com/r/c32","clinical.referring_provider":"Ines Lopez","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"ilopez@example.com","clinical.emergency_phone":"(632) 555-0131","clinical.sessions_completed":"2","clinical.self_pay_rate":"$312.50","clinical.adherence_pct":"20%","clinical.intake_date":"09/15/2026","clinical.appt_time":"1:30 PM","clinical.primary_dx":"Male","clinical.symptoms":"Medical, Dental","clinical.risk_level":"In-Network","clinical.telehealth_consent":"No","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"60%","clinical.clinician_sig":"Ines Lopez (e-signed)","clinical.prior_records":"uploaded_c32.pdf","clinical.emergency_address":"1600 Glenarm Pl, Denver, CO 80202","clinical.patient_ssn":"•••-••-1265","clinical.care_plan_url":"https://app.credifyfast.com/r/c32","consent.signer_name":"Ines Lopez","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"ilopez@example.com","consent.contact_phone":"(632) 555-0131","consent.auth_term":"2","consent.service_estimate":"$312.50","consent.deposit_pct":"20%","consent.consent_date":"09/15/2026","consent.reminder_time":"1:30 PM","consent.contact_method":"Male","consent.releases":"Medical, Dental","consent.hipaa_ack":"In-Network","consent.marketing_optin":"No","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"60%","consent.auth_signature":"Ines Lopez (e-signed)","consent.consent_pdf":"uploaded_c32.pdf","consent.address_on_file":"1600 Glenarm Pl, Denver, CO 80202","consent.ssn_last4":"•••-••-1265","consent.vault_url":"https://app.credifyfast.com/r/c32"}'::jsonb),
  ('c33', 'org_demo', 'Sam', 'Carter', 'Sam Carter', 'scarter@example.com', '(633) 555-0132', '4821 Texas St', 'San Diego, CA', '92116', 'America/Los_Angeles', 'en', 'ct_prospective_employee', 'ls_web', 'lt_comm', 'stg_disch', 'st_won', 'bk_unassigned', 'dr_paid', 'r_sheri', 'rr_48h', '2026-07-09T21:31:31.157Z', 'tr_insfu', 3, '2026-07-16T21:31:31.157Z', 'sa_packet', 44, 57, 0, '[0,0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0]'::jsonb, 18, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Sam","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"scarter@example.com","demographics.mobile_phone":"(633) 555-0132","demographics.age":"3","demographics.household_income":"$1,940.00","demographics.fpl_percent":"15%","demographics.dob":"11/28/1978","demographics.preferred_call_time":"11:15 AM","demographics.gender_identity":"PPO","demographics.languages":"Therapy, Med Mgmt","demographics.marital_status":"Monthly","demographics.consent_text":"Yes","demographics.health_literacy":"3 / 5","demographics.mobility_level":"4 / 10","demographics.signature":"Sam Carter (e-signed)","demographics.photo_id":"uploaded_c33.pdf","demographics.home_address":"4821 Texas St, San Diego, CA 92116","demographics.ssn":"•••-••-1266","demographics.portal_url":"https://app.credifyfast.com/r/c33","financial.account_holder":"Sam Carter","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"scarter@example.com","financial.billing_phone":"(633) 555-0132","financial.dependents":"3","financial.balance_due":"$1,940.00","financial.discount_pct":"15%","financial.payment_due":"07/30/2026","financial.statement_time":"11:15 AM","financial.payment_method":"PPO","financial.coverage_types":"Therapy, Med Mgmt","financial.billing_cycle":"Monthly","financial.autopay":"Yes","financial.pay_reliability":"3 / 5","financial.hardship_level":"4 / 10","financial.fin_signature":"Sam Carter (e-signed)","financial.income_doc":"uploaded_c33.pdf","financial.billing_address":"4821 Texas St, San Diego, CA 92116","financial.tax_id":"•••-••-1266","financial.pay_url":"https://app.credifyfast.com/r/c33","insurance.insurer_name":"Sam Carter","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"scarter@example.com","insurance.payer_phone":"(633) 555-0132","insurance.visits_authorized":"3","insurance.copay":"$1,940.00","insurance.coinsurance_pct":"15%","insurance.coverage_start":"07/30/2026","insurance.verify_time":"11:15 AM","insurance.plan_type":"PPO","insurance.covered_services":"Therapy, Med Mgmt","insurance.network_status":"Monthly","insurance.auth_required":"Yes","insurance.verify_confidence":"3 / 5","insurance.deductible_met":"4 / 10","insurance.aob_signature":"Sam Carter (e-signed)","insurance.card_front":"uploaded_c33.pdf","insurance.payer_address":"4821 Texas St, San Diego, CA 92116","insurance.subscriber_ssn":"•••-••-1266","insurance.eligibility_url":"https://app.credifyfast.com/r/c33","clinical.referring_provider":"Sam Carter","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"scarter@example.com","clinical.emergency_phone":"(633) 555-0132","clinical.sessions_completed":"3","clinical.self_pay_rate":"$1,940.00","clinical.adherence_pct":"15%","clinical.intake_date":"07/30/2026","clinical.appt_time":"11:15 AM","clinical.primary_dx":"PPO","clinical.symptoms":"Therapy, Med Mgmt","clinical.risk_level":"Monthly","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"3 / 5","clinical.gad7_score":"4 / 10","clinical.clinician_sig":"Sam Carter (e-signed)","clinical.prior_records":"uploaded_c33.pdf","clinical.emergency_address":"4821 Texas St, San Diego, CA 92116","clinical.patient_ssn":"•••-••-1266","clinical.care_plan_url":"https://app.credifyfast.com/r/c33","consent.signer_name":"Sam Carter","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"scarter@example.com","consent.contact_phone":"(633) 555-0132","consent.auth_term":"3","consent.service_estimate":"$1,940.00","consent.deposit_pct":"15%","consent.consent_date":"07/30/2026","consent.reminder_time":"11:15 AM","consent.contact_method":"PPO","consent.releases":"Therapy, Med Mgmt","consent.hipaa_ack":"Monthly","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"3 / 5","consent.telehealth_comfort":"4 / 10","consent.auth_signature":"Sam Carter (e-signed)","consent.consent_pdf":"uploaded_c33.pdf","consent.address_on_file":"4821 Texas St, San Diego, CA 92116","consent.ssn_last4":"•••-••-1266","consent.vault_url":"https://app.credifyfast.com/r/c33"}'::jsonb),
  ('c34', 'org_demo', 'Rosa', 'Diaz', 'Rosa Diaz', 'rdiaz@example.com', '(634) 555-0133', '912 Grand Ave', 'Oakland, CA', '94610', 'America/Los_Angeles', 'es', 'ct_employee', 'ls_gads', 'lt_slide', 'stg_new', 'st_noshow', 'bk_ah', 'dr_ins', 'r_paul', NULL, NULL, 'tr_post', 2, '2026-07-17T21:31:31.157Z', 'sa_dcsum', 44, 61, 0, '[2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0,0,0,0]'::jsonb, 12, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Rosa","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"rdiaz@example.com","demographics.mobile_phone":"(634) 555-0133","demographics.age":"5","demographics.household_income":"$95.00","demographics.fpl_percent":"0%","demographics.dob":"01/19/1983","demographics.preferred_call_time":"4:45 PM","demographics.gender_identity":"Anxiety (F41.1)","demographics.languages":"Records, Billing","demographics.marital_status":"Moderate","demographics.consent_text":"No","demographics.health_literacy":"4 / 5","demographics.mobility_level":"Met","demographics.signature":"Rosa Diaz (e-signed)","demographics.photo_id":"uploaded_c34.pdf","demographics.home_address":"912 Grand Ave, Oakland, CA 94610","demographics.ssn":"•••-••-1267","demographics.portal_url":"https://app.credifyfast.com/r/c34","financial.account_holder":"Rosa Diaz","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"rdiaz@example.com","financial.billing_phone":"(634) 555-0133","financial.dependents":"5","financial.balance_due":"$95.00","financial.discount_pct":"0%","financial.payment_due":"10/05/2026","financial.statement_time":"4:45 PM","financial.payment_method":"Anxiety (F41.1)","financial.coverage_types":"Records, Billing","financial.billing_cycle":"Moderate","financial.autopay":"No","financial.pay_reliability":"4 / 5","financial.hardship_level":"Met","financial.fin_signature":"Rosa Diaz (e-signed)","financial.income_doc":"uploaded_c34.pdf","financial.billing_address":"912 Grand Ave, Oakland, CA 94610","financial.tax_id":"•••-••-1267","financial.pay_url":"https://app.credifyfast.com/r/c34","insurance.insurer_name":"Rosa Diaz","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"rdiaz@example.com","insurance.payer_phone":"(634) 555-0133","insurance.visits_authorized":"5","insurance.copay":"$95.00","insurance.coinsurance_pct":"0%","insurance.coverage_start":"10/05/2026","insurance.verify_time":"4:45 PM","insurance.plan_type":"Anxiety (F41.1)","insurance.covered_services":"Records, Billing","insurance.network_status":"Moderate","insurance.auth_required":"No","insurance.verify_confidence":"4 / 5","insurance.deductible_met":"Met","insurance.aob_signature":"Rosa Diaz (e-signed)","insurance.card_front":"uploaded_c34.pdf","insurance.payer_address":"912 Grand Ave, Oakland, CA 94610","insurance.subscriber_ssn":"•••-••-1267","insurance.eligibility_url":"https://app.credifyfast.com/r/c34","clinical.referring_provider":"Rosa Diaz","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"rdiaz@example.com","clinical.emergency_phone":"(634) 555-0133","clinical.sessions_completed":"5","clinical.self_pay_rate":"$95.00","clinical.adherence_pct":"0%","clinical.intake_date":"10/05/2026","clinical.appt_time":"4:45 PM","clinical.primary_dx":"Anxiety (F41.1)","clinical.symptoms":"Records, Billing","clinical.risk_level":"Moderate","clinical.telehealth_consent":"No","clinical.phq9_severity":"4 / 5","clinical.gad7_score":"Met","clinical.clinician_sig":"Rosa Diaz (e-signed)","clinical.prior_records":"uploaded_c34.pdf","clinical.emergency_address":"912 Grand Ave, Oakland, CA 94610","clinical.patient_ssn":"•••-••-1267","clinical.care_plan_url":"https://app.credifyfast.com/r/c34","consent.signer_name":"Rosa Diaz","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"rdiaz@example.com","consent.contact_phone":"(634) 555-0133","consent.auth_term":"5","consent.service_estimate":"$95.00","consent.deposit_pct":"0%","consent.consent_date":"10/05/2026","consent.reminder_time":"4:45 PM","consent.contact_method":"Anxiety (F41.1)","consent.releases":"Records, Billing","consent.hipaa_ack":"Moderate","consent.marketing_optin":"No","consent.onboarding_satisfaction":"4 / 5","consent.telehealth_comfort":"Met","consent.auth_signature":"Rosa Diaz (e-signed)","consent.consent_pdf":"uploaded_c34.pdf","consent.address_on_file":"912 Grand Ave, Oakland, CA 94610","consent.ssn_last4":"•••-••-1267","consent.vault_url":"https://app.credifyfast.com/r/c34"}'::jsonb),
  ('c35', 'org_demo', 'Leo', 'Novak', 'Leo Novak', 'lnovak@example.com', '(635) 555-0134', '330 Pine St', 'Seattle, WA', '98101', 'America/Los_Angeles', 'en', 'ct_prospective_provider', 'ls_pt', 'lt_comm', 'stg_intake', 'st_nurture', 'bk_vip', 'dr_geo', 'r_taras', NULL, NULL, NULL, 0, NULL, 'sa_intake', 44, 65, 0, '[0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0,0,0]'::jsonb, 15, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Leo","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"lnovak@example.com","demographics.mobile_phone":"(635) 555-0134","demographics.age":"12","demographics.household_income":"$220.00","demographics.fpl_percent":"40%","demographics.dob":"09/06/1988","demographics.preferred_call_time":"8:30 AM","demographics.gender_identity":"Card on file","demographics.languages":"Sleep, Mood","demographics.marital_status":"Acknowledged","demographics.consent_text":"Yes","demographics.health_literacy":"5 / 5","demographics.mobility_level":"8 / 10","demographics.signature":"Leo Novak (e-signed)","demographics.photo_id":"uploaded_c35.pdf","demographics.home_address":"330 Pine St, Seattle, WA 98101","demographics.ssn":"•••-••-1268","demographics.portal_url":"https://app.credifyfast.com/r/c35","financial.account_holder":"Leo Novak","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"lnovak@example.com","financial.billing_phone":"(635) 555-0134","financial.dependents":"12","financial.balance_due":"$220.00","financial.discount_pct":"40%","financial.payment_due":"06/22/2026","financial.statement_time":"8:30 AM","financial.payment_method":"Card on file","financial.coverage_types":"Sleep, Mood","financial.billing_cycle":"Acknowledged","financial.autopay":"Yes","financial.pay_reliability":"5 / 5","financial.hardship_level":"8 / 10","financial.fin_signature":"Leo Novak (e-signed)","financial.income_doc":"uploaded_c35.pdf","financial.billing_address":"330 Pine St, Seattle, WA 98101","financial.tax_id":"•••-••-1268","financial.pay_url":"https://app.credifyfast.com/r/c35","insurance.insurer_name":"Leo Novak","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"lnovak@example.com","insurance.payer_phone":"(635) 555-0134","insurance.visits_authorized":"12","insurance.copay":"$220.00","insurance.coinsurance_pct":"40%","insurance.coverage_start":"06/22/2026","insurance.verify_time":"8:30 AM","insurance.plan_type":"Card on file","insurance.covered_services":"Sleep, Mood","insurance.network_status":"Acknowledged","insurance.auth_required":"Yes","insurance.verify_confidence":"5 / 5","insurance.deductible_met":"8 / 10","insurance.aob_signature":"Leo Novak (e-signed)","insurance.card_front":"uploaded_c35.pdf","insurance.payer_address":"330 Pine St, Seattle, WA 98101","insurance.subscriber_ssn":"•••-••-1268","insurance.eligibility_url":"https://app.credifyfast.com/r/c35","clinical.referring_provider":"Leo Novak","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"lnovak@example.com","clinical.emergency_phone":"(635) 555-0134","clinical.sessions_completed":"12","clinical.self_pay_rate":"$220.00","clinical.adherence_pct":"40%","clinical.intake_date":"06/22/2026","clinical.appt_time":"8:30 AM","clinical.primary_dx":"Card on file","clinical.symptoms":"Sleep, Mood","clinical.risk_level":"Acknowledged","clinical.telehealth_consent":"Yes","clinical.phq9_severity":"5 / 5","clinical.gad7_score":"8 / 10","clinical.clinician_sig":"Leo Novak (e-signed)","clinical.prior_records":"uploaded_c35.pdf","clinical.emergency_address":"330 Pine St, Seattle, WA 98101","clinical.patient_ssn":"•••-••-1268","clinical.care_plan_url":"https://app.credifyfast.com/r/c35","consent.signer_name":"Leo Novak","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"lnovak@example.com","consent.contact_phone":"(635) 555-0134","consent.auth_term":"12","consent.service_estimate":"$220.00","consent.deposit_pct":"40%","consent.consent_date":"06/22/2026","consent.reminder_time":"8:30 AM","consent.contact_method":"Card on file","consent.releases":"Sleep, Mood","consent.hipaa_ack":"Acknowledged","consent.marketing_optin":"Yes","consent.onboarding_satisfaction":"5 / 5","consent.telehealth_comfort":"8 / 10","consent.auth_signature":"Leo Novak (e-signed)","consent.consent_pdf":"uploaded_c35.pdf","consent.address_on_file":"330 Pine St, Seattle, WA 98101","consent.ssn_last4":"•••-••-1268","consent.vault_url":"https://app.credifyfast.com/r/c35"}'::jsonb),
  ('c36', 'org_demo', 'Dahlia', 'Greene', 'Dahlia Greene', 'dgreene@example.com', '(636) 555-0135', '55 W Monroe St', 'Chicago, IL', '60603', 'America/Chicago', 'en', 'ct_provider', 'ls_phys', 'lt_slide', 'stg_disch', 'st_lost', 'bk_intake', 'dr_rr', 'r_janet', NULL, NULL, 'tr_new5', 1, '2026-07-12T21:31:31.157Z', NULL, 44, 69, 0, '[0,0,0,0,0,2,0,0,0,0,0,0,0,1,3,5,8,9,7,5,3,1,0,0]'::jsonb, 17, 0, 'ok', NULL, NULL, '{"demographics.first_name":"Dahlia","demographics.mailing_notes":"Prefers afternoon contact; mail to address on file.","demographics.email":"dgreene@example.com","demographics.mobile_phone":"(636) 555-0135","demographics.age":"7","demographics.household_income":"$0.00","demographics.fpl_percent":"65%","demographics.dob":"05/23/1993","demographics.preferred_call_time":"2:00 PM","demographics.gender_identity":"Email","demographics.languages":"English","demographics.marital_status":"Single","demographics.consent_text":"No","demographics.health_literacy":"2 / 5","demographics.mobility_level":"3 / 10","demographics.signature":"Dahlia Greene (e-signed)","demographics.photo_id":"uploaded_c36.pdf","demographics.home_address":"55 W Monroe St, Chicago, IL 60603","demographics.ssn":"•••-••-1269","demographics.portal_url":"https://app.credifyfast.com/r/c36","financial.account_holder":"Dahlia Greene","financial.billing_notes":"Prefers afternoon contact; mail to address on file.","financial.billing_email":"dgreene@example.com","financial.billing_phone":"(636) 555-0135","financial.dependents":"7","financial.balance_due":"$0.00","financial.discount_pct":"65%","financial.payment_due":"12/01/2026","financial.statement_time":"2:00 PM","financial.payment_method":"Email","financial.coverage_types":"English","financial.billing_cycle":"Single","financial.autopay":"No","financial.pay_reliability":"2 / 5","financial.hardship_level":"3 / 10","financial.fin_signature":"Dahlia Greene (e-signed)","financial.income_doc":"uploaded_c36.pdf","financial.billing_address":"55 W Monroe St, Chicago, IL 60603","financial.tax_id":"•••-••-1269","financial.pay_url":"https://app.credifyfast.com/r/c36","insurance.insurer_name":"Dahlia Greene","insurance.auth_notes":"Prefers afternoon contact; mail to address on file.","insurance.payer_email":"dgreene@example.com","insurance.payer_phone":"(636) 555-0135","insurance.visits_authorized":"7","insurance.copay":"$0.00","insurance.coinsurance_pct":"65%","insurance.coverage_start":"12/01/2026","insurance.verify_time":"2:00 PM","insurance.plan_type":"Email","insurance.covered_services":"English","insurance.network_status":"Single","insurance.auth_required":"No","insurance.verify_confidence":"2 / 5","insurance.deductible_met":"3 / 10","insurance.aob_signature":"Dahlia Greene (e-signed)","insurance.card_front":"uploaded_c36.pdf","insurance.payer_address":"55 W Monroe St, Chicago, IL 60603","insurance.subscriber_ssn":"•••-••-1269","insurance.eligibility_url":"https://app.credifyfast.com/r/c36","clinical.referring_provider":"Dahlia Greene","clinical.presenting_concern":"Prefers afternoon contact; mail to address on file.","clinical.provider_email":"dgreene@example.com","clinical.emergency_phone":"(636) 555-0135","clinical.sessions_completed":"7","clinical.self_pay_rate":"$0.00","clinical.adherence_pct":"65%","clinical.intake_date":"12/01/2026","clinical.appt_time":"2:00 PM","clinical.primary_dx":"Email","clinical.symptoms":"English","clinical.risk_level":"Single","clinical.telehealth_consent":"No","clinical.phq9_severity":"2 / 5","clinical.gad7_score":"3 / 10","clinical.clinician_sig":"Dahlia Greene (e-signed)","clinical.prior_records":"uploaded_c36.pdf","clinical.emergency_address":"55 W Monroe St, Chicago, IL 60603","clinical.patient_ssn":"•••-••-1269","clinical.care_plan_url":"https://app.credifyfast.com/r/c36","consent.signer_name":"Dahlia Greene","consent.special_instructions":"Prefers afternoon contact; mail to address on file.","consent.confirm_email":"dgreene@example.com","consent.contact_phone":"(636) 555-0135","consent.auth_term":"7","consent.service_estimate":"$0.00","consent.deposit_pct":"65%","consent.consent_date":"12/01/2026","consent.reminder_time":"2:00 PM","consent.contact_method":"Email","consent.releases":"English","consent.hipaa_ack":"Single","consent.marketing_optin":"No","consent.onboarding_satisfaction":"2 / 5","consent.telehealth_comfort":"3 / 10","consent.auth_signature":"Dahlia Greene (e-signed)","consent.consent_pdf":"uploaded_c36.pdf","consent.address_on_file":"55 W Monroe St, Chicago, IL 60603","consent.ssn_last4":"•••-••-1269","consent.vault_url":"https://app.credifyfast.com/r/c36"}'::jsonb);

INSERT INTO "ContactEmailPref" ("id", "organizationId", "contactId", "categoryId", "optedIn") VALUES
  ('cep_c1_cat_appt', 'org_demo', 'c1', 'cat_appt', TRUE),
  ('cep_c1_cat_billing', 'org_demo', 'c1', 'cat_billing', TRUE),
  ('cep_c1_cat_care', 'org_demo', 'c1', 'cat_care', TRUE),
  ('cep_c1_cat_marketing', 'org_demo', 'c1', 'cat_marketing', FALSE),
  ('cep_c1_cat_surveys', 'org_demo', 'c1', 'cat_surveys', FALSE),
  ('cep_c1_cat_events', 'org_demo', 'c1', 'cat_events', FALSE),
  ('cep_c2_cat_appt', 'org_demo', 'c2', 'cat_appt', TRUE),
  ('cep_c2_cat_billing', 'org_demo', 'c2', 'cat_billing', TRUE),
  ('cep_c2_cat_care', 'org_demo', 'c2', 'cat_care', TRUE),
  ('cep_c2_cat_marketing', 'org_demo', 'c2', 'cat_marketing', TRUE),
  ('cep_c2_cat_surveys', 'org_demo', 'c2', 'cat_surveys', TRUE),
  ('cep_c2_cat_events', 'org_demo', 'c2', 'cat_events', TRUE),
  ('cep_c3_cat_appt', 'org_demo', 'c3', 'cat_appt', TRUE),
  ('cep_c3_cat_billing', 'org_demo', 'c3', 'cat_billing', TRUE),
  ('cep_c3_cat_care', 'org_demo', 'c3', 'cat_care', TRUE),
  ('cep_c3_cat_marketing', 'org_demo', 'c3', 'cat_marketing', TRUE),
  ('cep_c3_cat_surveys', 'org_demo', 'c3', 'cat_surveys', TRUE),
  ('cep_c3_cat_events', 'org_demo', 'c3', 'cat_events', TRUE),
  ('cep_c4_cat_appt', 'org_demo', 'c4', 'cat_appt', TRUE),
  ('cep_c4_cat_billing', 'org_demo', 'c4', 'cat_billing', TRUE),
  ('cep_c4_cat_care', 'org_demo', 'c4', 'cat_care', TRUE),
  ('cep_c4_cat_marketing', 'org_demo', 'c4', 'cat_marketing', TRUE),
  ('cep_c4_cat_surveys', 'org_demo', 'c4', 'cat_surveys', TRUE),
  ('cep_c4_cat_events', 'org_demo', 'c4', 'cat_events', TRUE),
  ('cep_c5_cat_appt', 'org_demo', 'c5', 'cat_appt', TRUE),
  ('cep_c5_cat_billing', 'org_demo', 'c5', 'cat_billing', TRUE),
  ('cep_c5_cat_care', 'org_demo', 'c5', 'cat_care', TRUE),
  ('cep_c5_cat_marketing', 'org_demo', 'c5', 'cat_marketing', FALSE),
  ('cep_c5_cat_surveys', 'org_demo', 'c5', 'cat_surveys', TRUE),
  ('cep_c5_cat_events', 'org_demo', 'c5', 'cat_events', TRUE),
  ('cep_c6_cat_appt', 'org_demo', 'c6', 'cat_appt', TRUE),
  ('cep_c6_cat_billing', 'org_demo', 'c6', 'cat_billing', TRUE),
  ('cep_c6_cat_care', 'org_demo', 'c6', 'cat_care', TRUE),
  ('cep_c6_cat_marketing', 'org_demo', 'c6', 'cat_marketing', TRUE),
  ('cep_c6_cat_surveys', 'org_demo', 'c6', 'cat_surveys', TRUE),
  ('cep_c6_cat_events', 'org_demo', 'c6', 'cat_events', FALSE),
  ('cep_c7_cat_appt', 'org_demo', 'c7', 'cat_appt', TRUE),
  ('cep_c7_cat_billing', 'org_demo', 'c7', 'cat_billing', TRUE),
  ('cep_c7_cat_care', 'org_demo', 'c7', 'cat_care', TRUE),
  ('cep_c7_cat_marketing', 'org_demo', 'c7', 'cat_marketing', TRUE),
  ('cep_c7_cat_surveys', 'org_demo', 'c7', 'cat_surveys', TRUE),
  ('cep_c7_cat_events', 'org_demo', 'c7', 'cat_events', TRUE),
  ('cep_c8_cat_appt', 'org_demo', 'c8', 'cat_appt', TRUE),
  ('cep_c8_cat_billing', 'org_demo', 'c8', 'cat_billing', TRUE),
  ('cep_c8_cat_care', 'org_demo', 'c8', 'cat_care', TRUE),
  ('cep_c8_cat_marketing', 'org_demo', 'c8', 'cat_marketing', TRUE),
  ('cep_c8_cat_surveys', 'org_demo', 'c8', 'cat_surveys', FALSE),
  ('cep_c8_cat_events', 'org_demo', 'c8', 'cat_events', TRUE),
  ('cep_c9_cat_appt', 'org_demo', 'c9', 'cat_appt', TRUE),
  ('cep_c9_cat_billing', 'org_demo', 'c9', 'cat_billing', TRUE),
  ('cep_c9_cat_care', 'org_demo', 'c9', 'cat_care', TRUE),
  ('cep_c9_cat_marketing', 'org_demo', 'c9', 'cat_marketing', FALSE),
  ('cep_c9_cat_surveys', 'org_demo', 'c9', 'cat_surveys', TRUE),
  ('cep_c9_cat_events', 'org_demo', 'c9', 'cat_events', TRUE),
  ('cep_c10_cat_appt', 'org_demo', 'c10', 'cat_appt', TRUE),
  ('cep_c10_cat_billing', 'org_demo', 'c10', 'cat_billing', TRUE),
  ('cep_c10_cat_care', 'org_demo', 'c10', 'cat_care', TRUE),
  ('cep_c10_cat_marketing', 'org_demo', 'c10', 'cat_marketing', TRUE),
  ('cep_c10_cat_surveys', 'org_demo', 'c10', 'cat_surveys', TRUE),
  ('cep_c10_cat_events', 'org_demo', 'c10', 'cat_events', TRUE),
  ('cep_c11_cat_appt', 'org_demo', 'c11', 'cat_appt', TRUE),
  ('cep_c11_cat_billing', 'org_demo', 'c11', 'cat_billing', TRUE),
  ('cep_c11_cat_care', 'org_demo', 'c11', 'cat_care', TRUE),
  ('cep_c11_cat_marketing', 'org_demo', 'c11', 'cat_marketing', FALSE),
  ('cep_c11_cat_surveys', 'org_demo', 'c11', 'cat_surveys', FALSE),
  ('cep_c11_cat_events', 'org_demo', 'c11', 'cat_events', FALSE),
  ('cep_c12_cat_appt', 'org_demo', 'c12', 'cat_appt', TRUE),
  ('cep_c12_cat_billing', 'org_demo', 'c12', 'cat_billing', TRUE),
  ('cep_c12_cat_care', 'org_demo', 'c12', 'cat_care', TRUE),
  ('cep_c12_cat_marketing', 'org_demo', 'c12', 'cat_marketing', TRUE),
  ('cep_c12_cat_surveys', 'org_demo', 'c12', 'cat_surveys', TRUE),
  ('cep_c12_cat_events', 'org_demo', 'c12', 'cat_events', TRUE),
  ('cep_c13_cat_appt', 'org_demo', 'c13', 'cat_appt', TRUE),
  ('cep_c13_cat_billing', 'org_demo', 'c13', 'cat_billing', TRUE),
  ('cep_c13_cat_care', 'org_demo', 'c13', 'cat_care', TRUE),
  ('cep_c13_cat_marketing', 'org_demo', 'c13', 'cat_marketing', FALSE),
  ('cep_c13_cat_surveys', 'org_demo', 'c13', 'cat_surveys', TRUE),
  ('cep_c13_cat_events', 'org_demo', 'c13', 'cat_events', TRUE),
  ('cep_c14_cat_appt', 'org_demo', 'c14', 'cat_appt', TRUE),
  ('cep_c14_cat_billing', 'org_demo', 'c14', 'cat_billing', TRUE),
  ('cep_c14_cat_care', 'org_demo', 'c14', 'cat_care', TRUE),
  ('cep_c14_cat_marketing', 'org_demo', 'c14', 'cat_marketing', TRUE),
  ('cep_c14_cat_surveys', 'org_demo', 'c14', 'cat_surveys', TRUE),
  ('cep_c14_cat_events', 'org_demo', 'c14', 'cat_events', TRUE),
  ('cep_c15_cat_appt', 'org_demo', 'c15', 'cat_appt', TRUE),
  ('cep_c15_cat_billing', 'org_demo', 'c15', 'cat_billing', TRUE),
  ('cep_c15_cat_care', 'org_demo', 'c15', 'cat_care', TRUE),
  ('cep_c15_cat_marketing', 'org_demo', 'c15', 'cat_marketing', TRUE),
  ('cep_c15_cat_surveys', 'org_demo', 'c15', 'cat_surveys', FALSE),
  ('cep_c15_cat_events', 'org_demo', 'c15', 'cat_events', TRUE),
  ('cep_c16_cat_appt', 'org_demo', 'c16', 'cat_appt', TRUE),
  ('cep_c16_cat_billing', 'org_demo', 'c16', 'cat_billing', TRUE),
  ('cep_c16_cat_care', 'org_demo', 'c16', 'cat_care', TRUE),
  ('cep_c16_cat_marketing', 'org_demo', 'c16', 'cat_marketing', TRUE),
  ('cep_c16_cat_surveys', 'org_demo', 'c16', 'cat_surveys', TRUE),
  ('cep_c16_cat_events', 'org_demo', 'c16', 'cat_events', FALSE),
  ('cep_c17_cat_appt', 'org_demo', 'c17', 'cat_appt', TRUE),
  ('cep_c17_cat_billing', 'org_demo', 'c17', 'cat_billing', TRUE),
  ('cep_c17_cat_care', 'org_demo', 'c17', 'cat_care', TRUE),
  ('cep_c17_cat_marketing', 'org_demo', 'c17', 'cat_marketing', FALSE),
  ('cep_c17_cat_surveys', 'org_demo', 'c17', 'cat_surveys', TRUE),
  ('cep_c17_cat_events', 'org_demo', 'c17', 'cat_events', TRUE),
  ('cep_c18_cat_appt', 'org_demo', 'c18', 'cat_appt', TRUE),
  ('cep_c18_cat_billing', 'org_demo', 'c18', 'cat_billing', TRUE),
  ('cep_c18_cat_care', 'org_demo', 'c18', 'cat_care', TRUE),
  ('cep_c18_cat_marketing', 'org_demo', 'c18', 'cat_marketing', TRUE),
  ('cep_c18_cat_surveys', 'org_demo', 'c18', 'cat_surveys', TRUE),
  ('cep_c18_cat_events', 'org_demo', 'c18', 'cat_events', TRUE),
  ('cep_c19_cat_appt', 'org_demo', 'c19', 'cat_appt', TRUE),
  ('cep_c19_cat_billing', 'org_demo', 'c19', 'cat_billing', TRUE),
  ('cep_c19_cat_care', 'org_demo', 'c19', 'cat_care', TRUE),
  ('cep_c19_cat_marketing', 'org_demo', 'c19', 'cat_marketing', TRUE),
  ('cep_c19_cat_surveys', 'org_demo', 'c19', 'cat_surveys', TRUE),
  ('cep_c19_cat_events', 'org_demo', 'c19', 'cat_events', TRUE),
  ('cep_c20_cat_appt', 'org_demo', 'c20', 'cat_appt', TRUE),
  ('cep_c20_cat_billing', 'org_demo', 'c20', 'cat_billing', TRUE),
  ('cep_c20_cat_care', 'org_demo', 'c20', 'cat_care', TRUE),
  ('cep_c20_cat_marketing', 'org_demo', 'c20', 'cat_marketing', TRUE),
  ('cep_c20_cat_surveys', 'org_demo', 'c20', 'cat_surveys', TRUE),
  ('cep_c20_cat_events', 'org_demo', 'c20', 'cat_events', TRUE),
  ('cep_c21_cat_appt', 'org_demo', 'c21', 'cat_appt', TRUE),
  ('cep_c21_cat_billing', 'org_demo', 'c21', 'cat_billing', TRUE),
  ('cep_c21_cat_care', 'org_demo', 'c21', 'cat_care', TRUE),
  ('cep_c21_cat_marketing', 'org_demo', 'c21', 'cat_marketing', FALSE),
  ('cep_c21_cat_surveys', 'org_demo', 'c21', 'cat_surveys', TRUE),
  ('cep_c21_cat_events', 'org_demo', 'c21', 'cat_events', FALSE),
  ('cep_c22_cat_appt', 'org_demo', 'c22', 'cat_appt', TRUE),
  ('cep_c22_cat_billing', 'org_demo', 'c22', 'cat_billing', TRUE),
  ('cep_c22_cat_care', 'org_demo', 'c22', 'cat_care', TRUE),
  ('cep_c22_cat_marketing', 'org_demo', 'c22', 'cat_marketing', TRUE),
  ('cep_c22_cat_surveys', 'org_demo', 'c22', 'cat_surveys', FALSE),
  ('cep_c22_cat_events', 'org_demo', 'c22', 'cat_events', TRUE),
  ('cep_c23_cat_appt', 'org_demo', 'c23', 'cat_appt', TRUE),
  ('cep_c23_cat_billing', 'org_demo', 'c23', 'cat_billing', TRUE),
  ('cep_c23_cat_care', 'org_demo', 'c23', 'cat_care', TRUE),
  ('cep_c23_cat_marketing', 'org_demo', 'c23', 'cat_marketing', TRUE),
  ('cep_c23_cat_surveys', 'org_demo', 'c23', 'cat_surveys', TRUE),
  ('cep_c23_cat_events', 'org_demo', 'c23', 'cat_events', TRUE),
  ('cep_c24_cat_appt', 'org_demo', 'c24', 'cat_appt', TRUE),
  ('cep_c24_cat_billing', 'org_demo', 'c24', 'cat_billing', TRUE),
  ('cep_c24_cat_care', 'org_demo', 'c24', 'cat_care', TRUE),
  ('cep_c24_cat_marketing', 'org_demo', 'c24', 'cat_marketing', TRUE),
  ('cep_c24_cat_surveys', 'org_demo', 'c24', 'cat_surveys', TRUE),
  ('cep_c24_cat_events', 'org_demo', 'c24', 'cat_events', TRUE),
  ('cep_c25_cat_appt', 'org_demo', 'c25', 'cat_appt', TRUE),
  ('cep_c25_cat_billing', 'org_demo', 'c25', 'cat_billing', TRUE),
  ('cep_c25_cat_care', 'org_demo', 'c25', 'cat_care', TRUE),
  ('cep_c25_cat_marketing', 'org_demo', 'c25', 'cat_marketing', FALSE),
  ('cep_c25_cat_surveys', 'org_demo', 'c25', 'cat_surveys', TRUE),
  ('cep_c25_cat_events', 'org_demo', 'c25', 'cat_events', TRUE),
  ('cep_c26_cat_appt', 'org_demo', 'c26', 'cat_appt', TRUE),
  ('cep_c26_cat_billing', 'org_demo', 'c26', 'cat_billing', TRUE),
  ('cep_c26_cat_care', 'org_demo', 'c26', 'cat_care', TRUE),
  ('cep_c26_cat_marketing', 'org_demo', 'c26', 'cat_marketing', TRUE),
  ('cep_c26_cat_surveys', 'org_demo', 'c26', 'cat_surveys', TRUE),
  ('cep_c26_cat_events', 'org_demo', 'c26', 'cat_events', FALSE),
  ('cep_c27_cat_appt', 'org_demo', 'c27', 'cat_appt', TRUE),
  ('cep_c27_cat_billing', 'org_demo', 'c27', 'cat_billing', TRUE),
  ('cep_c27_cat_care', 'org_demo', 'c27', 'cat_care', TRUE),
  ('cep_c27_cat_marketing', 'org_demo', 'c27', 'cat_marketing', TRUE),
  ('cep_c27_cat_surveys', 'org_demo', 'c27', 'cat_surveys', TRUE),
  ('cep_c27_cat_events', 'org_demo', 'c27', 'cat_events', TRUE),
  ('cep_c28_cat_appt', 'org_demo', 'c28', 'cat_appt', TRUE),
  ('cep_c28_cat_billing', 'org_demo', 'c28', 'cat_billing', TRUE),
  ('cep_c28_cat_care', 'org_demo', 'c28', 'cat_care', TRUE),
  ('cep_c28_cat_marketing', 'org_demo', 'c28', 'cat_marketing', TRUE),
  ('cep_c28_cat_surveys', 'org_demo', 'c28', 'cat_surveys', TRUE),
  ('cep_c28_cat_events', 'org_demo', 'c28', 'cat_events', TRUE),
  ('cep_c29_cat_appt', 'org_demo', 'c29', 'cat_appt', TRUE),
  ('cep_c29_cat_billing', 'org_demo', 'c29', 'cat_billing', TRUE),
  ('cep_c29_cat_care', 'org_demo', 'c29', 'cat_care', TRUE),
  ('cep_c29_cat_marketing', 'org_demo', 'c29', 'cat_marketing', FALSE),
  ('cep_c29_cat_surveys', 'org_demo', 'c29', 'cat_surveys', FALSE),
  ('cep_c29_cat_events', 'org_demo', 'c29', 'cat_events', TRUE),
  ('cep_c30_cat_appt', 'org_demo', 'c30', 'cat_appt', TRUE),
  ('cep_c30_cat_billing', 'org_demo', 'c30', 'cat_billing', TRUE),
  ('cep_c30_cat_care', 'org_demo', 'c30', 'cat_care', TRUE),
  ('cep_c30_cat_marketing', 'org_demo', 'c30', 'cat_marketing', TRUE),
  ('cep_c30_cat_surveys', 'org_demo', 'c30', 'cat_surveys', TRUE),
  ('cep_c30_cat_events', 'org_demo', 'c30', 'cat_events', TRUE),
  ('cep_c31_cat_appt', 'org_demo', 'c31', 'cat_appt', TRUE),
  ('cep_c31_cat_billing', 'org_demo', 'c31', 'cat_billing', TRUE),
  ('cep_c31_cat_care', 'org_demo', 'c31', 'cat_care', TRUE),
  ('cep_c31_cat_marketing', 'org_demo', 'c31', 'cat_marketing', TRUE),
  ('cep_c31_cat_surveys', 'org_demo', 'c31', 'cat_surveys', TRUE),
  ('cep_c31_cat_events', 'org_demo', 'c31', 'cat_events', FALSE),
  ('cep_c32_cat_appt', 'org_demo', 'c32', 'cat_appt', TRUE),
  ('cep_c32_cat_billing', 'org_demo', 'c32', 'cat_billing', TRUE),
  ('cep_c32_cat_care', 'org_demo', 'c32', 'cat_care', TRUE),
  ('cep_c32_cat_marketing', 'org_demo', 'c32', 'cat_marketing', TRUE),
  ('cep_c32_cat_surveys', 'org_demo', 'c32', 'cat_surveys', TRUE),
  ('cep_c32_cat_events', 'org_demo', 'c32', 'cat_events', TRUE),
  ('cep_c33_cat_appt', 'org_demo', 'c33', 'cat_appt', TRUE),
  ('cep_c33_cat_billing', 'org_demo', 'c33', 'cat_billing', TRUE),
  ('cep_c33_cat_care', 'org_demo', 'c33', 'cat_care', TRUE),
  ('cep_c33_cat_marketing', 'org_demo', 'c33', 'cat_marketing', FALSE),
  ('cep_c33_cat_surveys', 'org_demo', 'c33', 'cat_surveys', TRUE),
  ('cep_c33_cat_events', 'org_demo', 'c33', 'cat_events', TRUE),
  ('cep_c34_cat_appt', 'org_demo', 'c34', 'cat_appt', TRUE),
  ('cep_c34_cat_billing', 'org_demo', 'c34', 'cat_billing', TRUE),
  ('cep_c34_cat_care', 'org_demo', 'c34', 'cat_care', TRUE),
  ('cep_c34_cat_marketing', 'org_demo', 'c34', 'cat_marketing', TRUE),
  ('cep_c34_cat_surveys', 'org_demo', 'c34', 'cat_surveys', TRUE),
  ('cep_c34_cat_events', 'org_demo', 'c34', 'cat_events', TRUE),
  ('cep_c35_cat_appt', 'org_demo', 'c35', 'cat_appt', TRUE),
  ('cep_c35_cat_billing', 'org_demo', 'c35', 'cat_billing', TRUE),
  ('cep_c35_cat_care', 'org_demo', 'c35', 'cat_care', TRUE),
  ('cep_c35_cat_marketing', 'org_demo', 'c35', 'cat_marketing', TRUE),
  ('cep_c35_cat_surveys', 'org_demo', 'c35', 'cat_surveys', TRUE),
  ('cep_c35_cat_events', 'org_demo', 'c35', 'cat_events', TRUE),
  ('cep_c36_cat_appt', 'org_demo', 'c36', 'cat_appt', TRUE),
  ('cep_c36_cat_billing', 'org_demo', 'c36', 'cat_billing', TRUE),
  ('cep_c36_cat_care', 'org_demo', 'c36', 'cat_care', TRUE),
  ('cep_c36_cat_marketing', 'org_demo', 'c36', 'cat_marketing', TRUE),
  ('cep_c36_cat_surveys', 'org_demo', 'c36', 'cat_surveys', FALSE),
  ('cep_c36_cat_events', 'org_demo', 'c36', 'cat_events', FALSE);

INSERT INTO "ContactCrmEvent" ("id", "organizationId", "contactId", "type", "at", "meta") VALUES
  ('cce_c1_1', 'org_demo', 'c1', 'form_submitted', '2026-07-14T21:31:31.151Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c2_1', 'org_demo', 'c2', 'stage_action_logged', '2026-07-13T21:31:31.152Z', '{"stageActionId":"sa_intake"}'::jsonb),
  ('cce_c3_1', 'org_demo', 'c3', 'tag_applied', '2026-07-14T21:31:31.152Z', '{"tag":"vip"}'::jsonb),
  ('cce_c4_1', 'org_demo', 'c4', 'inbound_deliverability', '2026-07-12T21:31:31.152Z', '{"delivType":"soft_bounce"}'::jsonb),
  ('cce_c7_1', 'org_demo', 'c7', 'form_submitted', '2026-07-14T21:31:31.152Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c9_1', 'org_demo', 'c9', 'stage_action_logged', '2026-07-13T21:31:31.153Z', '{"stageActionId":"sa_intake"}'::jsonb),
  ('cce_c11_1', 'org_demo', 'c11', 'tag_applied', '2026-07-14T21:31:31.153Z', '{"tag":"vip"}'::jsonb),
  ('cce_c13_1', 'org_demo', 'c13', 'form_submitted', '2026-07-14T21:31:31.153Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c13_2', 'org_demo', 'c13', 'inbound_deliverability', '2026-07-12T21:31:31.153Z', '{"delivType":"soft_bounce"}'::jsonb),
  ('cce_c16_1', 'org_demo', 'c16', 'stage_action_logged', '2026-07-13T21:31:31.153Z', '{"stageActionId":"sa_intake"}'::jsonb),
  ('cce_c19_1', 'org_demo', 'c19', 'form_submitted', '2026-07-14T21:31:31.154Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c19_2', 'org_demo', 'c19', 'tag_applied', '2026-07-14T21:31:31.154Z', '{"tag":"vip"}'::jsonb),
  ('cce_c22_1', 'org_demo', 'c22', 'inbound_deliverability', '2026-07-12T21:31:31.154Z', '{"delivType":"soft_bounce"}'::jsonb),
  ('cce_c23_1', 'org_demo', 'c23', 'stage_action_logged', '2026-07-13T21:31:31.154Z', '{"stageActionId":"sa_intake"}'::jsonb),
  ('cce_c25_1', 'org_demo', 'c25', 'form_submitted', '2026-07-14T21:31:31.154Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c27_1', 'org_demo', 'c27', 'tag_applied', '2026-07-14T21:31:31.155Z', '{"tag":"vip"}'::jsonb),
  ('cce_c30_1', 'org_demo', 'c30', 'stage_action_logged', '2026-07-13T21:31:31.155Z', '{"stageActionId":"sa_intake"}'::jsonb),
  ('cce_c31_1', 'org_demo', 'c31', 'form_submitted', '2026-07-14T21:31:31.156Z', '{"formSlug":"phq9"}'::jsonb),
  ('cce_c31_2', 'org_demo', 'c31', 'inbound_deliverability', '2026-07-12T21:31:31.156Z', '{"delivType":"soft_bounce"}'::jsonb),
  ('cce_c35_1', 'org_demo', 'c35', 'tag_applied', '2026-07-14T21:31:31.157Z', '{"tag":"vip"}'::jsonb);

INSERT INTO "EmailTemplate" ("id", "organizationId", "name", "categoryId", "kind", "bilingual", "subject", "body", "blocks", "es", "attachment") VALUES
  ('t1', 'org_demo', 'Intro / Welcome', 'cat_marketing', 'text', FALSE, 'Hello {{demographics.first_name}} — welcome from Credify', 'Hi {{demographics.first_name}},

Thanks for connecting with us. We have your email as {{demographics.email}} and your preferred call time as {{demographics.preferred_call_time}}.

Reply anytime — we''re glad you''re here.

Warmly,
The Credify Team', NULL, NULL, NULL),
  ('t2', 'org_demo', 'Balance Reminder', 'cat_billing', 'text', FALSE, 'A quick note about your account, {{financial.account_holder}}', 'Hello {{financial.account_holder}},

Our records show a balance of {{financial.balance_due}}, due {{financial.payment_due}}. With your {{financial.discount_pct}} discount applied, you can pay here: {{financial.pay_url}}

Questions? Call {{financial.billing_phone}}.

Thank you,
Billing', NULL, NULL, NULL),
  ('t3', 'org_demo', 'Partner Check-In', 'cat_marketing', 'text', FALSE, 'Checking in — next steps', 'Hi {{demographics.first_name}},

Wanted to touch base on our partnership. Your point of contact is reachable at {{demographics.mobile_phone}}.

Let''s find time this week.

Best,
Partnerships', NULL, NULL, NULL),
  ('t4', 'org_demo', 'Welcome (HTML)', 'cat_marketing', 'html', TRUE, 'Welcome to Credify, {{demographics.first_name}}', '', '[{"id":"t4b1","type":"heading","text":"Welcome, {{demographics.first_name}}","align":"left"},{"id":"t4b2","type":"text","text":"We''re glad you''re here. Your care team is ready to help you get started — no waiting rooms, no runaround.","align":"left"},{"id":"t4b3","type":"text","text":"As an insurance member, your benefits verification is already underway — we''ll be in touch shortly.","align":"left","cond":{"kind":"crm","field":"leadTypeId","op":"is","value":"lt_comm"}},{"id":"t4b4","type":"button","label":"Visit your portal","url":"https://portal.credifyfast.com","align":"left"},{"id":"t4b5","type":"divider"},{"id":"t4b6","type":"text","text":"Questions? Just reply to this email and a real person will get back to you.","align":"left"}]'::jsonb, '{"subject":"Bienvenido a Credify, {{demographics.first_name}}","body":"","blocks":[{"id":"t4e1","type":"heading","text":"Bienvenido, {{demographics.first_name}}","align":"left"},{"id":"t4e2","type":"text","text":"Nos alegra tenerle aquí. Su equipo de atención está listo para ayudarle a comenzar — sin salas de espera ni complicaciones.","align":"left"},{"id":"t4e3","type":"button","label":"Acceda a su portal","url":"https://portal.credifyfast.com","align":"left"},{"id":"t4e4","type":"divider"},{"id":"t4e5","type":"text","text":"¿Preguntas? Responda a este correo y una persona real le contestará.","align":"left"}]}'::jsonb, NULL);

INSERT INTO "SmsTemplate" ("id", "organizationId", "name", "categoryId", "body", "createdAt") VALUES
  ('sms1', 'org_demo', 'Appointment Reminder', 'cat_appt', 'Hi {{demographics.first_name}}, this is a reminder of your appointment tomorrow. Reply STOP to opt out. — Credify', '2026-07-01T09:00:00.000Z'),
  ('sms2', 'org_demo', 'Balance Due Nudge', 'cat_billing', 'Hi {{demographics.first_name}}, you have a balance of {{financial.balance_due}} due {{financial.payment_due}}. Pay here: {{financial.pay_url}} Reply STOP to opt out.', '2026-07-02T10:00:00.000Z'),
  ('sms3', 'org_demo', 'Welcome Text', 'cat_marketing', 'Welcome to Credify, {{demographics.first_name}}! Your care team is ready. Questions? Just reply to this message. Reply STOP to opt out.', '2026-07-03T11:00:00.000Z');

INSERT INTO "EmailSignature" ("id", "organizationId", "name", "title", "phone", "email", "org", "body") VALUES
  ('sig1', 'org_demo', 'Janet Dobson', 'Director of Outreach', '(619) 555-0101', 'janet@credifyfast.com', 'Push It, Inc. d/b/a Credify', 'Janet Dobson
Director of Outreach
Push It, Inc. d/b/a Credify
Phone: (619) 555-0101  |  janet@credifyfast.com
https://credifyfast.com'),
  ('sig2', 'org_demo', 'Sherilynne', 'Care Coordinator', '(619) 555-0102', 'sheri@credifyfast.com', 'Push It, Inc. d/b/a Credify', 'Sherilynne
Care Coordinator
Push It, Inc. d/b/a Credify
Phone: (619) 555-0102  |  sheri@credifyfast.com
https://credifyfast.com');

INSERT INTO "EmailTrigger" ("id", "organizationId", "name", "enabled", "entry", "segmentId", "tracking", "goals", "freqCapOverride", "quietHoursOverride", "branch") VALUES
  ('trg_demo1', 'org_demo', 'New Web Lead → 3-step nurture', TRUE, '{"field":"statusId","op":"is","value":"st_attempt"}'::jsonb, NULL, TRUE, '[{"kind":"status","value":"st_booked"}]'::jsonb, FALSE, FALSE, '{"enabled":false}'::jsonb),
  ('trg_demo2', 'org_demo', 'PHQ-9 Submitted → Follow-up drip', TRUE, '{"field":"__event","eventType":"form_submitted","formSlug":"phq9"}'::jsonb, NULL, TRUE, '[{"kind":"stage","value":"stg_treat"}]'::jsonb, FALSE, FALSE, '{"enabled":false}'::jsonb),
  ('trg_demo3', 'org_demo', 'Intake Action Logged → Appointment reminder', TRUE, '{"field":"__event","eventType":"stage_action_logged","stageActionId":"sa_intake"}'::jsonb, NULL, TRUE, '[]'::jsonb, FALSE, FALSE, '{"enabled":false}'::jsonb),
  ('trg_demo4', 'org_demo', 'Soft bounce → Re-engagement 2-step', TRUE, '{"field":"__event","eventType":"inbound_deliverability","delivType":"soft_bounce"}'::jsonb, NULL, FALSE, '[]'::jsonb, FALSE, FALSE, '{"enabled":false}'::jsonb);

INSERT INTO "EmailTriggerStep" ("id", "organizationId", "triggerId", "stepKey", "sortOrder", "templateId", "delayN", "delayUnit") VALUES
  ('ets_trg_demo1_s1', 'org_demo', 'trg_demo1', 's1', 0, 't1', 0, 'days'),
  ('ets_trg_demo1_s2', 'org_demo', 'trg_demo1', 's2', 1, 't2', 3, 'days'),
  ('ets_trg_demo1_s3', 'org_demo', 'trg_demo1', 's3', 2, 't3', 7, 'days'),
  ('ets_trg_demo2_s1', 'org_demo', 'trg_demo2', 's1', 0, 't1', 0, 'hours'),
  ('ets_trg_demo2_s2', 'org_demo', 'trg_demo2', 's2', 1, 't2', 2, 'days'),
  ('ets_trg_demo3_s1', 'org_demo', 'trg_demo3', 's1', 0, 't1', 1, 'days'),
  ('ets_trg_demo4_s1', 'org_demo', 'trg_demo4', 's1', 0, 't2', 3, 'days'),
  ('ets_trg_demo4_s2', 'org_demo', 'trg_demo4', 's2', 1, 't3', 14, 'days');

INSERT INTO "EmailJob" ("id", "organizationId", "createdAt", "templateId", "templateName", "categoryId", "kind", "bilingual", "typeIds", "mode", "scheduledAt", "tracking", "status", "source", "triggerId", "note", "footer", "portalNotice", "sentBy") VALUES
  ('job_seed1', 'org_demo', '2026-07-13T21:31:31.159Z', 't1', 'Intro / Welcome', 'cat_marketing', 'text', FALSE, '[]'::jsonb, 'immediate', NULL, TRUE, 'sent', 'cluster', NULL, 'Demo send · Week 1', '{"enabled":true,"orgName":"Push It, Inc. d/b/a Credify","logoText":"Credify","address":"600 B Street, Suite 300\nSan Diego, CA 92101"}'::jsonb, FALSE, 'Janet Dobson'),
  ('job_seed2', 'org_demo', '2026-07-14T21:31:31.159Z', 't2', 'Balance Reminder', 'cat_billing', 'text', FALSE, '[]'::jsonb, 'immediate', NULL, TRUE, 'sent', 'cluster', NULL, 'Demo send · Week 2', '{"enabled":true,"orgName":"Push It, Inc. d/b/a Credify","logoText":"Credify","address":"600 B Street, Suite 300\nSan Diego, CA 92101"}'::jsonb, FALSE, 'Sherilynne');

INSERT INTO "EmailJobRecipient" ("id", "organizationId", "jobId", "contactId", "name", "email", "typeId", "lang", "sendAt", "trackId", "opened", "openedAt", "clicked", "clickedUrl", "clickedAt", "subject", "body", "bodyHtml", "unsubToken", "unsubUrl", "listUnsubscribe", "listUnsubscribePost", "providerMessageId", "sendStatus", "sentAt") VALUES
  ('ejr_job_seed1_c1', 'org_demo', 'job_seed1', 'c1', 'Maria Alvarez', 'malvarez@example.com', 'ct_prospective_contact', 'en', '2026-07-13T21:31:31.159Z', 'trk_job_seed1_c1', TRUE, '2026-07-14T21:31:31.159Z', TRUE, 'https://credifyfast.com/intake', '2026-07-15T21:31:31.161Z', 'Hello Maria — welcome from Credify', 'Hi Maria,

Thanks for connecting with us. We have your email as malvarez@example.com and your preferred call time as 9:00 AM.

Reply anytime — we''re glad you''re here.

Warmly,
The Credify Team', NULL, 'u_c1_malvar', 'https://app.credifyfast.com/preferences/u_c1_malvar', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c1_malvar>, <https://app.credifyfast.com/preferences/u_c1_malvar>', 'List-Unsubscribe=One-Click', 'sim_job_seed1_c1', 'sent', '2026-07-13T21:31:31.159Z'),
  ('ejr_job_seed1_c2', 'org_demo', 'job_seed1', 'c2', 'James Okafor', 'jokafor@example.com', 'ct_contact', 'en', '2026-07-13T21:31:31.159Z', 'trk_job_seed1_c2', TRUE, '2026-07-14T21:31:31.159Z', TRUE, 'https://credifyfast.com/intake', '2026-07-15T21:31:31.161Z', 'Hello James — welcome from Credify', 'Hi James,

Thanks for connecting with us. We have your email as jokafor@example.com and your preferred call time as 1:30 PM.

Reply anytime — we''re glad you''re here.

Warmly,
The Credify Team', NULL, 'u_c2_jokafo', 'https://app.credifyfast.com/preferences/u_c2_jokafo', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c2_jokafo>, <https://app.credifyfast.com/preferences/u_c2_jokafo>', 'List-Unsubscribe=One-Click', 'sim_job_seed1_c2', 'sent', '2026-07-13T21:31:31.159Z'),
  ('ejr_job_seed1_c3', 'org_demo', 'job_seed1', 'c3', 'Priya Nair', 'pnair@example.com', 'ct_prospective_client', 'en', '2026-07-13T21:31:31.159Z', 'trk_job_seed1_c3', TRUE, '2026-07-14T21:31:31.159Z', FALSE, NULL, NULL, 'Hello Priya — welcome from Credify', 'Hi Priya,

Thanks for connecting with us. We have your email as pnair@example.com and your preferred call time as 11:15 AM.

Reply anytime — we''re glad you''re here.

Warmly,
The Credify Team', NULL, 'u_c3_pnaire', 'https://app.credifyfast.com/preferences/u_c3_pnaire', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c3_pnaire>, <https://app.credifyfast.com/preferences/u_c3_pnaire>', 'List-Unsubscribe=One-Click', 'sim_job_seed1_c3', 'sent', '2026-07-13T21:31:31.159Z'),
  ('ejr_job_seed1_c4', 'org_demo', 'job_seed1', 'c4', 'Daniel Whitman', 'dwhitman@example.com', 'ct_client', 'en', '2026-07-13T21:31:31.159Z', 'trk_job_seed1_c4', FALSE, NULL, FALSE, NULL, NULL, 'Hello Daniel — welcome from Credify', 'Hi Daniel,

Thanks for connecting with us. We have your email as dwhitman@example.com and your preferred call time as 4:45 PM.

Reply anytime — we''re glad you''re here.

Warmly,
The Credify Team', NULL, 'u_c4_dwhitm', 'https://app.credifyfast.com/preferences/u_c4_dwhitm', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c4_dwhitm>, <https://app.credifyfast.com/preferences/u_c4_dwhitm>', 'List-Unsubscribe=One-Click', 'sim_job_seed1_c4', 'sent', '2026-07-13T21:31:31.159Z'),
  ('ejr_job_seed2_c5', 'org_demo', 'job_seed2', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'ct_prospective_patient', 'en', '2026-07-14T21:31:31.159Z', 'trk_job_seed2_c5', TRUE, '2026-07-15T09:31:31.159Z', TRUE, 'https://credifyfast.com/portal', '2026-07-15T21:31:31.161Z', 'A quick note about your account, Sofia Reyes', 'Hello Sofia Reyes,

Our records show a balance of $220.00, due 06/22/2026. With your 40% discount applied, you can pay here: https://app.credifyfast.com/r/c5

Questions? Call (605) 555-0104.

Thank you,
Billing', NULL, 'u_c5_sreyes', 'https://app.credifyfast.com/preferences/u_c5_sreyes', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c5_sreyes>, <https://app.credifyfast.com/preferences/u_c5_sreyes>', 'List-Unsubscribe=One-Click', 'sim_job_seed2_c5', 'sent', '2026-07-14T21:31:31.159Z'),
  ('ejr_job_seed2_c6', 'org_demo', 'job_seed2', 'c6', 'Aaron Goldstein', 'agoldstein@example.com', 'ct_patient', 'en', '2026-07-14T21:31:31.159Z', 'trk_job_seed2_c6', TRUE, '2026-07-15T09:31:31.159Z', FALSE, NULL, NULL, 'A quick note about your account, Aaron Goldstein', 'Hello Aaron Goldstein,

Our records show a balance of $0.00, due 12/01/2026. With your 65% discount applied, you can pay here: https://app.credifyfast.com/r/c6

Questions? Call (606) 555-0105.

Thank you,
Billing', NULL, 'u_c6_agolds', 'https://app.credifyfast.com/preferences/u_c6_agolds', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c6_agolds>, <https://app.credifyfast.com/preferences/u_c6_agolds>', 'List-Unsubscribe=One-Click', 'sim_job_seed2_c6', 'sent', '2026-07-14T21:31:31.159Z'),
  ('ejr_job_seed2_c7', 'org_demo', 'job_seed2', 'c7', 'Lena Park', 'lpark@example.com', 'ct_prospective_reseller', 'en', '2026-07-14T21:31:31.159Z', 'trk_job_seed2_c7', FALSE, NULL, FALSE, NULL, NULL, 'A quick note about your account, Lena Park', 'Hello Lena Park,

Our records show a balance of $48,200, due 08/01/2026. With your 138% discount applied, you can pay here: https://app.credifyfast.com/r/c7

Questions? Call (607) 555-0106.

Thank you,
Billing', NULL, 'u_c7_lparke', 'https://app.credifyfast.com/preferences/u_c7_lparke', '<mailto:unsubscribe@credifyfast.com?subject=unsub%20u_c7_lparke>, <https://app.credifyfast.com/preferences/u_c7_lparke>', 'List-Unsubscribe=One-Click', 'sim_job_seed2_c7', 'sent', '2026-07-14T21:31:31.159Z');

INSERT INTO "DeliverabilityEvent" ("id", "organizationId", "contactId", "name", "email", "type", "at", "action", "suppressed") VALUES
  ('de1', 'org_demo', 'c8', 'Marcus Bauer', 'mbauer@example.com', 'hard_bounce', '2026-07-10T21:31:31.158Z', 'Hard bounce → permanently suppressed (all email)', TRUE),
  ('de2', 'org_demo', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'soft_bounce', '2026-07-09T21:31:31.158Z', 'Soft bounce 1/3 — will retry', FALSE),
  ('de3', 'org_demo', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'soft_bounce', '2026-07-12T21:31:31.158Z', 'Soft bounce 2/3 — will retry', FALSE),
  ('de4', 'org_demo', 'c11', 'Elena Petrova', 'epetrova@example.com', 'complaint', '2026-07-13T21:31:31.158Z', 'Spam complaint → unsubscribed from marketing (transactional still allowed)', FALSE);

INSERT INTO "EmailClickEvent" ("id", "organizationId", "jobId", "contactId", "name", "email", "url", "at") VALUES
  ('ce1', 'org_demo', 'job_seed1', 'c1', 'Maria Alvarez', 'malvarez@example.com', 'https://credifyfast.com/intake', '2026-07-15T21:31:31.161Z'),
  ('ce2', 'org_demo', 'job_seed1', 'c2', 'James Okafor', 'jokafor@example.com', 'https://credifyfast.com/intake', '2026-07-15T21:31:31.161Z'),
  ('ce3', 'org_demo', 'job_seed2', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'https://credifyfast.com/portal', '2026-07-15T21:31:31.161Z');

INSERT INTO "EmailAuditLog" ("id", "organizationId", "type", "at", "jobId", "contactId", "name", "email", "templateName", "url") VALUES
  ('al1', 'org_demo', 'send', '2026-07-13T21:31:31.159Z', 'job_seed1', NULL, 'Maria Alvarez', 'malvarez@example.com', 'Intro / Welcome', NULL),
  ('al2', 'org_demo', 'send', '2026-07-13T21:31:31.159Z', 'job_seed1', NULL, 'James Okafor', 'jokafor@example.com', 'Intro / Welcome', NULL),
  ('al3', 'org_demo', 'send', '2026-07-13T21:31:31.159Z', 'job_seed1', NULL, 'Priya Nair', 'pnair@example.com', 'Intro / Welcome', NULL),
  ('al4', 'org_demo', 'send', '2026-07-13T21:31:31.159Z', 'job_seed1', NULL, 'Daniel Whitman', 'dwhitman@example.com', 'Intro / Welcome', NULL),
  ('al5', 'org_demo', 'send', '2026-07-14T21:31:31.159Z', 'job_seed2', NULL, 'Sofia Reyes', 'sreyes@example.com', 'Balance Reminder', NULL),
  ('al6', 'org_demo', 'send', '2026-07-14T21:31:31.159Z', 'job_seed2', NULL, 'Aaron Goldstein', 'agoldstein@example.com', 'Balance Reminder', NULL),
  ('al7', 'org_demo', 'send', '2026-07-14T21:31:31.159Z', 'job_seed2', NULL, 'Lena Park', 'lpark@example.com', 'Balance Reminder', NULL),
  ('al8', 'org_demo', 'open', '2026-07-14T21:31:31.159Z', 'job_seed1', 'c1', 'Maria Alvarez', 'malvarez@example.com', 'Intro / Welcome', NULL),
  ('al9', 'org_demo', 'open', '2026-07-14T21:31:31.159Z', 'job_seed1', 'c2', 'James Okafor', 'jokafor@example.com', 'Intro / Welcome', NULL),
  ('al10', 'org_demo', 'open', '2026-07-14T21:31:31.159Z', 'job_seed1', 'c3', 'Priya Nair', 'pnair@example.com', 'Intro / Welcome', NULL),
  ('al11', 'org_demo', 'open', '2026-07-15T09:31:31.159Z', 'job_seed2', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'Balance Reminder', NULL),
  ('al12', 'org_demo', 'open', '2026-07-15T09:31:31.159Z', 'job_seed2', 'c6', 'Aaron Goldstein', 'agoldstein@example.com', 'Balance Reminder', NULL),
  ('al13', 'org_demo', 'click', '2026-07-15T21:31:31.161Z', 'job_seed1', 'c1', 'Maria Alvarez', 'malvarez@example.com', 'Intro / Welcome', 'https://credifyfast.com/intake'),
  ('al14', 'org_demo', 'click', '2026-07-15T21:31:31.161Z', 'job_seed1', 'c2', 'James Okafor', 'jokafor@example.com', 'Intro / Welcome', 'https://credifyfast.com/intake'),
  ('al15', 'org_demo', 'click', '2026-07-15T21:31:31.161Z', 'job_seed2', 'c5', 'Sofia Reyes', 'sreyes@example.com', 'Balance Reminder', 'https://credifyfast.com/portal');

INSERT INTO "EmailSuppression" ("id", "organizationId", "email", "reason", "at") VALUES
  ('sup_seed1', 'org_demo', 'mbauer@example.com', 'hard_bounce', '2026-07-10T21:31:31.158Z');

INSERT INTO "NotifyPref" ("id", "organizationId", "scope", "refId", "channel") VALUES
  ('np_all', 'org_demo', 'all', NULL, 'off');

INSERT INTO "Setting" ("organizationId", "key", "value") VALUES
  ('org_demo', 'freqCap', '{"enabled":true,"maxPerWindow":3,"windowDays":7,"minGapHours":24}'::jsonb),
  ('org_demo', 'quietHours', '{"enabled":false,"startHour":21,"endHour":8}'::jsonb),
  ('org_demo', 'businessHours', '{"enabled":false,"startHour":8,"endHour":18}'::jsonb),
  ('org_demo', 'footer', '{"enabled":true,"orgName":"Push It, Inc. d/b/a Credify","logoText":"Credify","address":"600 B Street, Suite 300\nSan Diego, CA 92101"}'::jsonb),
  ('org_demo', 'unsubPage', '{"emailSubject":"You have been unsubscribed","emailBody":"Hi {{demographics.first_name}},\n\nYou have been successfully unsubscribed from [ORG NAME] email communications.\n\nIf this was a mistake, you can re-subscribe at any time using the link below:\n[RE-SUBSCRIBE LINK]\n\nThank you,\n[ORG NAME]\n[PHYSICAL ADDRESS]"}'::jsonb),
  ('org_demo', 'stopReply', '"You have been unsubscribed from [ORG NAME] text messages. Reply START at any time to opt back in. For help, reply HELP. — Push It, Inc. d/b/a Credify, (619) 555-0100"'::jsonb);

COMMIT;
