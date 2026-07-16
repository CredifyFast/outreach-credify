# Project Status — outreach-credify

> **Audience:** anyone joining or funding this project. **Purpose:** the honest current
> state, what's next, and what will hurt if ignored. Read this before any other doc.

**Last updated:** 2026-07-16 · **Branch:** `main` · **Repo:** [github.com/CredifyFast/outreach-credify](https://github.com/CredifyFast/outreach-credify)

---

## Executive summary

`outreach-credify` is the email/SMS outreach module for credifyfast.com, intended for
small behavioral health agencies. **Today it is a clickable front-end prototype and
nothing more.** One 4,598-line HTML file contains a complete, genuinely sophisticated
UI for twelve outreach surfaces — audience building, templating, scheduling,
suppression, deliverability, audit — all running against seeded fake data in the
browser.

The single most important fact about this repo: **there is no backend, and the code
knows it.** The `api()` function at `index.html:1898` is a stub. It logs to the console,
writes to `localStorage`, and returns `{ok:true}`. There are zero `fetch` or
`XMLHttpRequest` calls in the entire codebase. The 41 REST routes the UI "calls" are a
design sketch that no server implements.

That is not a criticism. Prototyping the UI first was a defensible way to discover the
domain, and the result encodes real, hard-won thinking — the PHI scanner and the send
guard chain are the work of someone who understands the compliance problem. But it means
**every estimate of "how far along are we" that counts the UI as progress is wrong.**
The UI is perhaps the cheapest third of this system. The backend, the HIPAA posture, and
the deliverability infrastructure are the other two thirds, and none of them exist.

**Nothing is deployed. No PHI has ever touched this code. There is no BAA in place.**
Those three facts are what make the current state safe, and they must stay true until
the security work in [security-compliance.md](security-compliance.md) is done.

---

## Delivery checklist

Legend: ✅ verified · 🟡 in progress · ⬜ not started · ⛔ blocked

### Front-end prototype

| Item | Status | Evidence |
| --- | --- | --- |
| Cluster Email UI, 12 tabs | ✅ | `grep -o 'data-tab="[a-z-]*"' index.html \| sort -u` → 12 |
| Client-side state model | ✅ | `index.html:1907`, single `state` object |
| localStorage persistence | ✅ | `index.html:1879` `PERSIST_KEY="credify_cluster_email_v1"` |
| PHI scanner (patterns + merge tags) | ✅ | `index.html:1441-1452`, 5 regex + 13 tag keys |
| Send guard chain | ✅ | `index.html` `doQueueSend()`, 9 sequential guards |
| Seed/demo data | ✅ | 18 `SEED_*` constants |
| Landing page | ✅ | `home.html`, 329 lines |
| Segments UI | ⛔ | `view-segments` exists, **no nav tab** — unreachable dead code |

### Backend

| Item | Status | Notes |
| --- | --- | --- |
| Any server code | ⬜ | Zero files |
| `package.json` / dependency manifest | ⬜ | Does not exist |
| Database — **schema designed** | 🟡 | **Isolated 33-table Cluster Email DB, ret by Taras** — [database-cluster-email.md](database-cluster-email.md). Verified on PG 16.14. **⛔ the `.sql` file itself has not been delivered** |
| Database — running instance | ⬜ | Nothing provisioned |
| Auth / sessions | ⬜ | `state.currentUserId` is a dropdown, not identity |
| Real `api()` transport | ⬜ | Stub at `index.html:1898` |
| Server-side re-validation of send guards | ⬜ | **Security-critical.** See [ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md) |

### Compliance (PHI in scope)

| Item | Status | Notes |
| --- | --- | --- |
| Signed BAA with ESP | ⬜ | **Longest lead time in the project.** Start now |
| Signed BAA with SMS vendor | ⬜ | Same |
| HIPAA risk assessment | ⬜ | Required before any real client data |
| Encryption at rest | ⬜ | No datastore to encrypt yet |
| Audit log persistence | ⬜ | `state.auditLog` is in-memory; wiped on `localStorage.removeItem` |
| Access controls / RBAC | ⬜ | No authn or authz of any kind |

### Engineering hygiene

| Item | Status | Evidence |
| --- | --- | --- |
| Tests | ⬜ | No test files, no runner |
| CI | ⬜ | No `.github/`, no pipeline |
| `.gitignore` | ⬜ | Does not exist |
| Build/tooling pinned | ⬜ | No manifest. Local: Node v24.16.0, npm 11.13.0 (unpinned) |
| `index.html` is a duplicate | 🟡 | md5-identical to the mockup — see [Risk R-1](#risks) |
| `test.v1` scratch file committed | 🟡 | 4 lines of "test", 2 commits (`f1254f0`, `94141b7`) |
| `home.html` lineage header wrong | 🟡 | Line 3 reads `FILE: index.html` |

---

## Project flow

How a send is *supposed* to work. Solid lines exist today; `[STUB]` marks where the
flow currently dead-ends into `localStorage`.

```
  Operator (Director of Outreach / Intake Coordinator)
        │
        ▼
  ┌───────────────┐   status → rep → type → exclude, AND-chained
  │ 1. Audience   │   clusterRecipients()
  └───────┬───────┘
          ▼
  ┌───────────────┐   merge tags {{form.field}} resolved per recipient
  │ 2. Template   │   templatePhiFindings() scans body + subject
  └───────┬───────┘
          ▼
  ┌───────────────┐   immediate | scheduled ; quiet hours ; business hours
  │ 3. Delivery   │
  └───────┬───────┘
          ▼
  ┌─────────────────────────────────────────────┐
  │ 4. GUARD CHAIN — doQueueSend()              │
  │    recipients > 0                           │
  │    template selected                        │
  │    scheduled date set & not in the past     │
  │    phiAckValid()        ← PHI warning ack   │
  │    dischargeAckValid()  ← discharged ack    │
  │    capAckValid()        ← freq-cap ack      │
  │    willSend > 0 after suppression           │
  │    sender identity selected                 │
  └───────┬─────────────────────────────────────┘
          ▼
  ┌───────────────┐
  │ 5. Confirm    │   openSendConfirm() → explicit modal
  └───────┬───────┘
          ▼
  ┌───────────────┐
  │ 6. Queue job  │  api("POST","/sends",job)  ──▶ [STUB] console.debug + localStorage
  └───────┬───────┘                                 ▲
          ▼                                         │ no network call exists
  ┌───────────────┐                                 │
  │ 7. Track      │  opens / clicks / bounces  ─────┘ [STUB] simulated locally
  └───────────────┘
```

**Read the guard chain carefully.** It is the most valuable logic in the repo, and it is
100% client-side. Every guard is currently advisory — a user with devtools can bypass
all nine in about fifteen seconds. When the backend lands, this chain must be
re-implemented server-side as the authority, with the client copy demoted to a UX
nicety. That is [ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md) and it is
non-negotiable.

---

## Timeframe

**Estimated, not committed.** No deadline was given. These are engineering estimates for
one full-time developer, and they assume the BAA track starts immediately and in
parallel — because it is calendar-bound, not effort-bound.

| Phase | Estimate | Gate to exit |
| --- | --- | --- |
| 0 · Repo hygiene | 1–2 days | Manifest, `.gitignore`, junk removed, CI green |
| 1 · Backend skeleton | 2–3 weeks | Next.js + Prisma + Postgres, auth, `api()` speaks HTTP |
| 2 · Domain + guards server-side | 3–4 weeks | Guard chain enforced server-side, tested |
| 3 · Compliance hardening | 3–4 weeks | Risk assessment done, BAAs signed, audit log durable |
| 4 · Deliverability | 2–3 weeks | Real ESP, SPF/DKIM/DMARC, bounce/complaint handling |
| 5 · Pilot | 2 weeks | One agency, non-PHI outreach only |

**Realistic first-PHI-send: 12–16 weeks from a standing start**, gated on the BAA, not on
code. If the BAA track starts late, this whole schedule slips by exactly however long it
was delayed — see the [backlog](#prioritized-backlog).

---

## Database architecture & schema

**Status: 🟡 designed, not delivered, not running.**

A real schema now exists on paper: an **isolated 33-table + 1-view Cluster Email
database, ret by Taras** — [database-cluster-email.md](database-cluster-email.md) —
built against this exact HTML and verified end-to-end on PostgreSQL 16.14. It is designed
to merge into `credify_unified_schema.sql` (105 tables, 319 indexes, 100 RLS policies)
via a MERGE MAP header.

**Two caveats before anyone calls this done:**

1. **⛔ The `credify_cluster_email_isolated.sql` file has not been delivered.** It is
   referenced throughout Taras's guide but is not in OneDrive or anywhere on this
   machine. Until it arrives, the schema of record is a README describing a file we do
   not have. This is [backlog #2b](#prioritized-backlog).
2. **No instance is provisioned.** Nothing is running.

The reviewer's appendix in that doc records what was verified (Taras's seed claims hold,
including a non-trivial 18-contact opt-out count) and three corrections — one material:
**§7's "2 transactional, 4 marketing" is wrong; the app seeds 3 and 3**, and that field
decides whether opt-outs are honored.

What follows is the *implied* model reverse-engineered from the client. It predates the
discovery of Taras's schema and is now a **design sketch, superseded in convention** by
[ADR-0008](adr/0008-align-with-unified-credify-schema.md).

Current persistence, in full:

```
localStorage["credify_cluster_email_v1"] = JSON.stringify(snapshot)
```

One browser key. One user. No concurrency, no server, no backup, no encryption. Clearing
site data destroys everything, including the audit log — which is itself a compliance
finding, since HIPAA audit trails must survive the user who wants them gone.

The implied entity graph:

```
   contact_types ──┐
   (20 system)     │
                   ▼
   contacts ───────────────┬──────────────┬─────────────┐
   │  stage_id             │              │             │
   │  status_id            ▼              ▼             ▼
   │  assigned_rep     form_data     suppressions   notify_prefs
   │  lead_source_id   (5 forms,     (email + SMS)  (per category)
   │  lead_type_id      20 field
   │                    types)
   ▼
   jobs ──────► job_recipients ──────► delivery_events
   │  template_id                      (open/click/bounce)
   │  sent_by
   │  scheduled_at
   ▼
   audit_log  (append-only, must outlive everything)
```

Full field-level treatment in [data-model.md](data-model.md).

---

## Tech stack

**The distinction between these two tables is the most load-bearing thing in this doc.**

### In use today (verified)

| Layer | Technology | Evidence |
| --- | --- | --- |
| Markup/logic | Vanilla HTML + CSS + JS, single file | `index.html`, 1 `<script>`, 1 `<style>` |
| Fonts | Google Fonts (Sora, Instrument Serif) | `<link>` to `fonts.googleapis.com` |
| Persistence | Browser `localStorage` | `index.html:1879` |
| Framework | **None** | No manifest, no imports, no bundler |
| Build | **None** | Open the file in a browser |
| Tests | **None** | No runner, no test files |
| Hosting | **None** (local XAMPP `htdocs` for preview only) | Not deployed |

### Planned (decided, not built)

| Layer | Technology | Decision |
| --- | --- | --- |
| Runtime | **Next.js + Prisma** (API at `chrome.credifyfast.com/api`) | [ADR-0008](adr/0008-align-with-unified-credify-schema.md) — supersedes ADR-0002's Express choice |
| Database | PostgreSQL 16 — **schema of record: [database-cluster-email.md](database-cluster-email.md)**, ret by Taras | [ADR-0008](adr/0008-align-with-unified-credify-schema.md) |
| Conventions | Quoted CamelCase · TEXT cuid PKs **minted app-side** · `TIMESTAMP(3)` · `organizationId` + RLS | [ADR-0008](adr/0008-align-with-unified-credify-schema.md) |
| Email delivery | HIPAA-eligible ESP, BAA required | [ADR-0007](adr/0007-baa-gated-vendor-selection.md) |
| SMS delivery | HIPAA-eligible vendor, BAA required | [ADR-0007](adr/0007-baa-gated-vendor-selection.md) |
| Auth | Session-based, server-side | [ADR-0002](adr/0002-node-express-postgres-backend.md) |

Nothing in the "planned" table has a line of code. Do not report it as progress.

---

## Prioritized backlog

**Ranked by what blocks what and by lead time — not by size.** The first item is
trivial to *do* and takes months to *finish*; that asymmetry is exactly why it's first.

| # | Item | Why here | Effort | Owner |
| --- | --- | --- | --- | --- |
| **1** | **Start ESP/SMS vendor BAA procurement** | **Calendar-bound, 4–10 weeks of someone else's legal review. It gates every real send. Every day this waits, the launch date moves a day. Nothing else on this list has that property.** | ~4h of forms | Jay / counsel |
| **2** | HIPAA risk assessment | Legally required before PHI. Its findings change the schema and infra, so doing it after the build means rework. Long tail — start early. | 1–2 wks | Jay / counsel |
| **2b** | **Get `credify_cluster_email_isolated.sql` from Taras** + confirm `EmailPrefCategory.kind` is 3/3 | **Trivial ask, blocks everything downstream.** The schema of record is currently a README describing a file nobody has. Also confirm the [C-1](database-cluster-email.md#c-1--category-kind-split-is-33-not-24-material) split — if a marketing category is seeded `transactional`, opt-outs are silently ignored | 10 min to ask | Jay → Taras |
| 3 | Decide PHI-in-outreach boundary | Blocks data model *and* vendor scope. The code already hints at "no PHI in email body" ([ADR-0005](adr/0005-phi-minimization-in-outreach.md)) — ratify or reject it. | 2–3 days | Tech lead + counsel |
| 4 | Repo hygiene: `.gitignore`, remove `test.v1`, fix duplicate `index.html` | Cheap, and every later commit inherits the mess. Ships together with #5. | 2h | Any dev |
| 5 | `package.json` + toolchain pin | Nothing can be tested, linted, or CI'd without it. Blocks #6, #7, #8. Ship with #4 as one "repo is real now" PR. | 4h | Any dev |
| 6 | Extract domain logic from `index.html` | The guard chain and PHI scanner must run server-side. They currently live inside a DOM-coupled file and can't be imported. Blocks #7. | 1 wk | Any dev |
| 7 | Next.js API skeleton + Postgres + Prisma migrations ([ADR-0008](adr/0008-align-with-unified-credify-schema.md)) | The backend. Everything downstream depends on it. Can't start before #5, shouldn't start before #3 (schema depends on the PHI boundary). | 2–3 wks | Backend dev |
| 8 | Server-side guard chain + tests | The security fix. Meaningless without #7; dangerous to launch without. | 2 wks | Backend dev |
| 9 | Real audit log (append-only, durable) | Compliance requirement. Depends on #7. | 1 wk | Backend dev |
| 10 | Wire `api()` to HTTP | The one-line-per-route swap the stub was designed for. Trivial once #7 exists. | 2 days | Any dev |
| 11 | Deliverability: SPF/DKIM/DMARC, bounce handling | Real sending. The UI tab exists and is entirely simulated. | 2 wks | Backend dev |
| 12 | Fix or delete orphaned segments UI | Dead code misleads. Decide: wire it up or cut it. | 1 day | Any dev |

**Items that must ship together:**

- **#4 + #5** — one PR. A `.gitignore` without a manifest is half a repo, and reviewers
  shouldn't see two rounds of housekeeping noise.
- **#7 + #8 + #9** — do not merge a backend that accepts sends without the guard chain
  and audit log. A server that sends email with client-trusted validation is strictly
  more dangerous than the current prototype, because it looks trustworthy. If you ship
  #7 alone, put the send route behind a feature flag that is off in every environment.
- **#1 + #2 + #3** — one workstream, one owner, started this week. They interlock: the
  risk assessment scopes the BAA, and the PHI boundary scopes both.

---

## Risks

| ID | Risk | Impact | Likelihood | Mitigation |
| --- | --- | --- | --- | --- |
| **R-1** | `index.html` is a byte-identical copy of the mockup (md5 `7c02a77a…`). Two files, one truth. | Edits land in one and silently diverge from the other. Reviewers can't tell which is canonical. | **Certain** — already true | Pick one. Delete or `.gitignore` the other. Track in #4 |
| **R-2** | Client-side-only guard chain | A bypassed PHI guard on a real send = HIPAA breach, notification duty, fines | High once live | [ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md); backlog #8 |
| **R-3** | BAA lead time underestimated | Launch slips by months with no code to blame | Medium-high | Backlog #1, started now |
| **R-4** | Audit log in `localStorage` | Not durable, user-clearable, fails HIPAA audit-trail requirements | Certain if shipped as-is | Backlog #9 |
| **R-5** | All logic in one 4,598-line file | Can't unit test, can't reuse server-side, merge conflicts are brutal | Certain | Backlog #6 |
| **R-6** | 20 field types include `ssn`, `signature`, `file`, `address` | The form engine can capture the most sensitive PHI there is. Merge tags can put it in an email body. | High | [ADR-0005](adr/0005-phi-minimization-in-outreach.md) |
| **R-7** | No tests anywhere | Every refactor is a leap of faith. Blocks safe extraction (#6) | Certain | Backlog #5 then #6 |
| **R-8** | Single developer, no bus factor | Domain knowledge is undocumented and in one head | Medium | This doc set is the first mitigation |

---

## Definition of Done

A change is done when **all** hold:

1. Behavior matches the spec, verified by running it — not by reading it.
2. Tests cover the new logic and pass. (⬜ blocked until backlog #5.)
3. No secrets, no real PHI, no real credentials in the diff or in fixtures.
4. Docs updated in the same PR — especially this file's checklist and
   [CHANGELOG.md](../CHANGELOG.md).
5. If a status moved to ✅, the PR body states the command that verified it.
6. If it touches sending, PHI, or audit: server-side enforcement exists and is tested.
   No exceptions, no "we'll add it after the pilot."

---

## Related docs

- [Product overview](product-overview.md) — what this is and who it's for
- [Architecture](architecture.md) — how it's built and why
- [Data model](data-model.md) — the implied schema
- [API design](api-design.md) — the 41 implied routes and the validation gate
- [Security & compliance](security-compliance.md) — threat model and go-live checklist
- [Roadmap](roadmap.md) — phases and exit criteria
- [ADRs](adr/) — the decisions and their alternatives
