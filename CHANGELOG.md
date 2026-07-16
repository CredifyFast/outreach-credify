# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet use semantic versioning — **nothing has been released**, and
there is no deployed artifact to version. Versioning starts at the first pilot
([roadmap M5](docs/roadmap.md#milestones)).

Entries before 2026-07-16 are reconstructed from `git log` and the FILE LINEAGE header in
`index.html`. Dates are commit dates; the pre-2026-07-16 grouping is approximate because
the early history has no changelog and the lineage block caps at 10 entries.

## [Unreleased]

### Added

- **2026-07-16** — [docs/database-cluster-email.md](docs/database-cluster-email.md):
  Cluster Email isolated database guide, **ret by Taras** — 33 tables + 1 view, verified
  on PostgreSQL 16.14, built to merge into `credify_unified_schema.sql`. Added verbatim
  with a provenance header and a reviewer's reconciliation appendix.
- **2026-07-16** — [ADR-0008](docs/adr/0008-align-with-unified-credify-schema.md): adopt
  the unified Credify schema's stack and conventions (Next.js + Prisma, quoted CamelCase,
  TEXT cuid PKs minted app-side, `TIMESTAMP(3)`, `organizationId` + RLS).

### Fixed

- **2026-07-16** — **Route inventory corrections** in
  [api-design.md](docs/api-design.md). The extraction regex captured only the first
  string literal of each path, truncating every concatenated route. Corrected against
  Taras's endpoint map and re-verified:
  - `PUT /contacts/{id}/prefs` → **`/contacts/{id}/preferences`**
  - `DELETE /suppressions/{id}` → **`/suppressions/{url-encoded email}`**
  - `DELETE /notify-prefs/{id}` → **`/notify-prefs/{scope}/{id}`**
  - Added missing `POST /contacts/{id}/unsubscribe` and `POST /triggers/{id}/activate`
  - **Retracted a false finding:** `POST /triggers/{id}` was called a design bug that
    "should be `PUT`". No such route exists — it is `/triggers/{id}/activate`, a
    legitimate action route.
- **2026-07-16** — [data-model.md](docs/data-model.md): seed counts corrected — **4**
  email templates (was 3); added triggers (4, 8 steps), contacts (36), and the
  **3 transactional / 3 marketing** category split.
- **2026-07-16** — [project-status.md](docs/project-status.md): exec summary said 36 REST
  routes; actual is 41. Database status ⬜ → 🟡 (designed, not delivered). Stack table
  corrected to Next.js + Prisma.

### Changed

- **2026-07-16** — [ADR-0002](docs/adr/0002-node-express-postgres-backend.md) marked
  **partially superseded** by ADR-0008. Left intact per
  [ADR-0001](docs/adr/0001-record-architecture-decisions.md) (accepted ADRs are
  immutable). PostgreSQL and the guard-chain argument survive; Express, plain-SQL
  migrations, `snake_case`, and `uuid` PKs do not — the repo never mentioned that a
  105-table unified schema already existed.
- **2026-07-16** — [data-model.md](docs/data-model.md) demoted to a design sketch;
  schema of record is now `database-cluster-email.md`. Its PHI classification
  (`is_phi` / `mergeable`) remains the only such design and is carried into ADR-0008 as
  a merge condition.

### Known issues (new)

- **⛔ `credify_cluster_email_isolated.sql` has not been delivered.** Taras's guide
  documents it throughout; the file is not in OneDrive or anywhere on this machine.
  Nothing in its §1 quick start can run. Backlog #2b.
- **⚠ Category `kind` split discrepancy.** The guide's §7 states "2 transactional, 4
  marketing"; `index.html` seeds **3 and 3**. That field decides whether opt-outs are
  honored — if a marketing category is seeded `transactional`, opted-out contacts receive
  marketing mail (fail-open, P1). Verify against the SQL when it arrives. See
  [C-1](docs/database-cluster-email.md#c-1--category-kind-split-is-33-not-24-material).
- **⚠ `state.trigExcluded` holds `Set` objects and is in `PERSIST_KEYS`.**
  `JSON.stringify(new Set())` → `{}`, so trigger exclusions are lost on reload and
  `.has()` throws after hydration. Latent — masked because "+ New Trigger" is disabled.
- **No endpoint feeds `EmailTriggerExclusion`.** The guide lists
  `POST /triggers/:id/exclusions`; that route does not exist in the HTML (0 occurrences).

### Added (earlier)

- **2026-07-16** — Full project documentation set: [README](README.md) hub,
  [docs/](docs/) (status, product overview, architecture, data model, API design,
  security & compliance, roadmap, project structure, engineering standards, operations
  runbook, deployment), seven [ADRs](docs/adr/), this changelog,
  [CONTRIBUTING.md](CONTRIBUTING.md), and [.env.example](.env.example).
  Documents the prototype as it actually is — **no backend, `api()` is a stub, nothing
  deployed** — and records the Node/Express + PostgreSQL decision, the HIPAA posture, and
  a lead-time-ordered backlog.
- **2026-07-15** — Landing page (`home.html`, 329 lines). Design system lifted from the
  Cluster Email mockup: Sora + Instrument Serif, green/mint palette, card/button/badge
  components. Sections: sticky topbar, hero with product preview card, trust strip,
  features grid, workflow steps, stats band, CTA, footer.
- **2026-07-15** — `index.html` added as the directory entry point (commit `2aff472`).

### Known issues

Carried from [project-status.md](docs/project-status.md#risks). Listed here because they
are pre-existing defects, not planned work.

- **`index.html` duplicates the mockup byte-for-byte** (md5 `7c02a77a371fad28e57335a2532e5b85`).
  Two files, one content, no canonical marker. Editing either diverges them silently.
  ([R-1](docs/project-status.md#risks))
- **`home.html` lineage header is wrong** — line 3 reads `FILE: index.html`.
- **`test.v1` is committed** — 4 lines of scratch text from commits `f1254f0`, `94141b7`.
- **No `.gitignore`, no `package.json`, no tests, no CI.**
- **Segments UI is unreachable** — `view-segments` exists with no corresponding nav tab.
- **All send guards are client-side only** and bypassable via devtools.
  ([ADR-0004](docs/adr/0004-server-side-enforcement-of-send-guards.md))
- **Audit log lives in `localStorage`** — not durable, user-clearable, fails HIPAA audit
  controls. ([ADR-0006](docs/adr/0006-localstorage-persistence-is-prototype-only.md))

---

## Prototype history

Reconstructed from `git log` and the `index.html` FILE LINEAGE block. Prototype only —
none of this shipped anywhere.

### 2026-07-12

- Calendar mockup (`CALENDAR_07-12-26_…`, 3,193 lines) added, then deleted
  (`b041689` → `4139c5b`).

### 2026-07-10

Cluster Email mockup reaching current form (`2c32f8f`, 4,598 lines):

- Summary card: "X unsubscribed" links to Suppression tab; "X opted out" links to
  Preferences. Implemented via a `data-action` dispatcher to avoid template-literal quote
  nesting.
- All emoji removed; functional emoji replaced with text equivalents.
- Audience panel rebuilt as a 4-row accordion (Status, Assigned Rep, Contact Type,
  Exclude Contacts) with live match count, preview modal, and AND connectors.
  `clusterRecipients()` chain: status → rep (include/exclude) → type → exclude.
- Audit Log filters rebuilt: Credify date inputs with MM/DD/YYYY mask, searchable
  multi-select dropdowns, Select All / Clear All.
- Unsubscribe tab: Add New / Saved toggle, plus an Unsubscribe Templates view.
- Template editor: sticky footer, PHI warning surfacing, format + language toggles merged,
  separate "Attach file" (10MB) and "Image" (2MB) inputs.
- Send-to-Cluster: "Clear" resets the whole audience panel; empty-type-selection now
  toasts instead of silently no-op'ing.
- Triggers: "+ New Trigger" deliberately disabled — dispatcher case commented out rather
  than deleted so it can be restored.

### 2026-07-08 and earlier

- Email / SMS template toggle; `state.smsTemplates` with seed data.
- "By User" toggle on Open Rates; `sentBy` added to `buildJob()`.
- Searchable multi-select component (`.ms-panel`).
- Initial commit (`08bbfcf`) — README only.

---

## Conventions for this file

- **Update in the same PR as the change.** A changelog written later is a changelog
  written wrong.
- Group under `Added` · `Changed` · `Deprecated` · `Removed` · `Fixed` · `Security`.
- Write for someone who wasn't there. "Fixed the thing" helps nobody.
- **`Security` entries are mandatory** for anything touching guards, PHI, auth, or audit —
  even when the change is small, and especially when it weakens a control.
- Link the ADR when a change implements a decision.
