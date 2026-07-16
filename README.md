# outreach-credify

Email / SMS outreach module for [credifyfast.com](https://credifyfast.com) — built for
small behavioral health agencies to reach referral partners, providers, and clients
without violating the rules that govern how you may contact them.

> ## ⚠ Current state: front-end prototype. No backend exists.
>
> This repo contains a clickable UI running on **seeded fake data in the browser**. The
> `api()` function at `index.html:1898` is a **stub** — it logs to the console and writes
> to `localStorage`. There are **zero network calls** in the codebase. Nothing is
> deployed. No real client data has ever passed through it, and none may until the work
> in [docs/security-compliance.md](docs/security-compliance.md) is complete.
>
> **→ Read [docs/project-status.md](docs/project-status.md) first.** It is the entry point.

---

## What it is

A behavioral health agency has a list of people it needs to email: referral sources,
providers, clients, prospective clients. Every one of those messages is governed by
something — HIPAA, consent, opt-out, contact frequency. Get it wrong and the penalty is
not a bounced email, it's a breach notification.

This module is the tooling for that: build an audience from a filtered contact list,
merge a template against per-contact fields, run it through a chain of safety guards,
and send — with the suppression list, opt-out preferences, quiet hours, and frequency
caps enforced rather than remembered.

The prototype's real contribution is the **guard chain** (`doQueueSend()`): nine
sequential checks that stand between an operator and a send they'd regret. See the
[project flow](docs/project-status.md#project-flow).

## Doc map

| Doc | Read it for |
| --- | --- |
| **[docs/project-status.md](docs/project-status.md)** | **Start here.** Real state, backlog, risks, DoD |
| [docs/README.md](docs/README.md) | Doc index with a read-in-order list |
| [docs/product-overview.md](docs/product-overview.md) | Vision, personas, glossary, feature inventory, non-goals |
| [docs/architecture.md](docs/architecture.md) | System shape, tech rationale, request lifecycle |
| **[docs/database-cluster-email.md](docs/database-cluster-email.md)** | **The schema of record** (33 tables + 1 view) — *ret by Taras* — plus a reviewer's reconciliation |
| [docs/data-model.md](docs/data-model.md) | Verified entities; proposed schema (superseded in convention), PHI classification |
| [docs/api-design.md](docs/api-design.md) | The 41 implied routes, the mandatory validation gate |
| [docs/security-compliance.md](docs/security-compliance.md) | Threat model, HIPAA posture, go-live checklist |
| [docs/roadmap.md](docs/roadmap.md) | Phases with exit criteria |
| [docs/project-structure.md](docs/project-structure.md) | Layout, dependency rules, naming |
| [docs/engineering-standards.md](docs/engineering-standards.md) | Style, testing, Git flow, CI/CD |
| [docs/operations-runbook.md](docs/operations-runbook.md) | Deploys, rollback, incidents, DR |
| [docs/deployment.md](docs/deployment.md) | Infra, ports, config, isolation rules |
| [docs/adr/](docs/adr/) | Why decisions were made, and what lost |
| [CHANGELOG.md](CHANGELOG.md) | What changed when |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Day-to-day workflow, PR checklist |

## Stack at a glance

| | In use today | Planned |
| --- | --- | --- |
| Front-end | Vanilla HTML/CSS/JS, single file, no build | unchanged for now |
| Persistence | `localStorage` (one key) | PostgreSQL 16 — schema designed, **`.sql` not yet delivered** |
| Backend | **none** | **Next.js + Prisma** (`chrome.credifyfast.com/api`) |
| Email/SMS | **none** (simulated) | HIPAA-eligible ESP + SMS vendor, BAA required |
| Tests / CI | **none** | Node test runner + GitHub Actions |

Rationale in [ADR-0008](docs/adr/0008-align-with-unified-credify-schema.md), which
supersedes [ADR-0002](docs/adr/0002-node-express-postgres-backend.md)'s Express choice —
this module merges into an existing 105-table Credify schema rather than inventing its
own stack. Everything in "Planned" is a decision, not an implementation.

## Quick start

No build, no dependencies, no server. Clone and open the file:

```bash
git clone https://github.com/CredifyFast/outreach-credify.git
cd outreach-credify
```

Then open `index.html` in any modern browser — double-click it, or:

```bash
start index.html      # Windows
open index.html       # macOS
xdg-open index.html   # Linux
```

The app seeds itself with demo data on first load. State persists to `localStorage`
under `credify_cluster_email_v1`.

**To reset to a clean state:** use the in-app reset (it calls
`localStorage.removeItem` then reloads), or clear site data for the origin.

**Note:** the repo sits in a XAMPP `htdocs` directory on the maintainer's machine. That
is a local preview convenience only — Apache/PHP/MySQL are **not** part of this project
and never were. See [ADR-0002](docs/adr/0002-node-express-postgres-backend.md).

## Scripts

**None.** There is no `package.json`. This is tracked as backlog item #5 in
[project-status.md](docs/project-status.md#prioritized-backlog) and blocks all testing
and CI work.

For reference, the maintainer's local toolchain is Node v24.16.0 / npm 11.13.0 —
unpinned and not required to run the prototype.

## Repo layout

```
outreach-credify/
├─ index.html      4,598 lines — the Cluster Email app (⚠ see note)
├─ home.html         329 lines — marketing landing page
├─ CLUSTER_EMAIL_07-10-26_...html   4,598 lines — mockup; md5-identical to index.html
├─ test.v1            4 lines — scratch file, should be deleted
├─ README.md        this file
└─ docs/            the doc set
```

> ⚠ **`index.html` and the `CLUSTER_EMAIL_…` mockup are byte-identical** (md5
> `7c02a77a371fad28e57335a2532e5b85`). Two files, one source of truth, no marker saying
> which wins. Fix this before editing either — see
> [Risk R-1](docs/project-status.md#risks).

Full treatment in [project-structure.md](docs/project-structure.md).

## Roadmap summary

| Phase | Focus | Estimate |
| --- | --- | --- |
| 0 | Repo hygiene — manifest, `.gitignore`, remove junk | 1–2 days |
| 1 | Backend skeleton — Next.js + Prisma, Postgres, auth | 2–3 wks |
| 2 | Domain logic + guard chain server-side | 3–4 wks |
| 3 | Compliance hardening — BAA, audit log, encryption | 3–4 wks |
| 4 | Deliverability — real ESP, SPF/DKIM/DMARC | 2–3 wks |
| 5 | Pilot — one agency, non-PHI only | 2 wks |

**~12–16 weeks to a first compliant send**, gated on BAA procurement rather than on
code. Exit criteria per phase in [roadmap.md](docs/roadmap.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: branch off `main`, keep the
diff surgical, never regenerate `index.html` wholesale, and never commit real client
data — the seed data exists so you never need to.

## License

No license file. **All rights reserved, Push It, Inc.** — this is a private commercial
repo. If that's wrong, add a `LICENSE` file; until then the absence of one means default
copyright, not permission.
