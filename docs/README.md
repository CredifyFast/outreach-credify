# Documentation index

> **Audience:** anyone working on outreach-credify. **Purpose:** point you at the right
> doc in the right order.

## Read in order

If you're new, read these top to bottom. It takes about an hour and you'll know more
than anyone but the maintainer.

1. **[project-status.md](project-status.md)** — the honest state. What's real, what's
   fiction, what's next, what's dangerous. **Nothing else makes sense without this.**
2. [product-overview.md](product-overview.md) — the problem, the users, the vocabulary.
   Read the glossary; this domain has words that mean specific things.
3. [architecture.md](architecture.md) — how the prototype is shaped and where the
   backend will attach.
4. **[database-cluster-email.md](database-cluster-email.md)** — **the schema of record**
   (33 tables + 1 view, **ret by Taras**), plus a reviewer's appendix reconciling it
   against this doc set. Read it before `data-model.md`.
5. [data-model.md](data-model.md) — the entities (verified), and a proposed schema now
   **superseded in convention** by the above. Still the only place PHI classification is
   designed.
6. [api-design.md](api-design.md) — the 41 routes the stub already names, and the
   validation gate every one of them must pass through.
7. [security-compliance.md](security-compliance.md) — the threat model and the go-live
   checklist. **Required reading before you touch sending, PHI, or the audit log.**
8. [roadmap.md](roadmap.md) — phases and their exit criteria.

Then, as needed:

- [project-structure.md](project-structure.md) — layout, dependency rules, naming
- [engineering-standards.md](engineering-standards.md) — style, tests, Git flow, CI
- [deployment.md](deployment.md) — infra, config, isolation
- [operations-runbook.md](operations-runbook.md) — deploys, incidents, DR
- [adr/](adr/) — decisions, alternatives, consequences

## The one thing to know

There is no backend. `api()` at `index.html:1898` is a stub that writes to
`localStorage`. Several docs here describe systems that **do not exist yet** — each one
says so in a banner at the top. Trust the banners.

## ADR index

| ADR | Title | Status |
| --- | --- | --- |
| [0001](adr/0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](adr/0002-node-express-postgres-backend.md) | Node/Express + PostgreSQL for the backend | Accepted |
| [0003](adr/0003-single-file-html-prototype.md) | Single-file HTML prototype | Accepted |
| [0004](adr/0004-server-side-enforcement-of-send-guards.md) | Send guards enforced server-side | Accepted |
| [0005](adr/0005-phi-minimization-in-outreach.md) | PHI minimization in outbound messages | Proposed |
| [0006](adr/0006-localstorage-persistence-is-prototype-only.md) | localStorage is prototype-only | Accepted |
| [0007](adr/0007-baa-gated-vendor-selection.md) | BAA-gated vendor selection | Accepted |
| [0008](adr/0008-align-with-unified-credify-schema.md) | Align with the unified Credify schema (Prisma / Next.js) | Accepted — **supersedes 0002's stack choice** |

New decisions get a new file. Accepted ADRs are immutable — supersede, don't edit. See
[ADR-0001](adr/0001-record-architecture-decisions.md).

## Conventions in these docs

- ✅ verified · 🟡 in progress · ⬜ not started · ⛔ blocked
- ✅ means someone ran something and watched it pass. Not "the code looks right."
- Every doc opens with an audience + purpose line.
- Tables for facts, prose for reasoning.
- Anything describing a system that doesn't exist says so **at the top, in a banner**.

## Keeping these honest

A doc that quietly goes stale is worse than no doc, because it spends trust it hasn't
earned. Two rules:

1. **Update docs in the same PR as the code.** Not the next one.
2. **When you mark something ✅, put the command in the PR body.** If you can't name the
   command, it isn't ✅.

Most claims here cite a file and line (e.g. `index.html:1898`). Line numbers drift — if
one is wrong, fix it in the same PR that moved the code.
