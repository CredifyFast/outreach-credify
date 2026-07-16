# ADR-0008 · Align with the unified Credify schema (Prisma / Next.js)

**Status:** Accepted
**Date:** 2026-07-16
**Supersedes:** the stack and convention portions of
[ADR-0002](0002-node-express-postgres-backend.md). ADR-0002's *reasoning* about the guard
chain still holds; its *conclusions* about Express, ids, and naming do not.

## Context

[ADR-0002](0002-node-express-postgres-backend.md) chose Node/Express + PostgreSQL and
specified plain-SQL migrations, `snake_case` tables, and `uuid` PKs generated server-side
with `gen_random_uuid()`.

**It was written from this repository alone, and this repository does not mention that a
unified Credify schema already exists.** It does:

| Artifact | Location | Reality |
| --- | --- | --- |
| `credify_unified_schema.sql` | `OneDrive/Documents/CredifyFast/` | **105 tables, 319 indexes, 100 RLS policies.** Verified on PostgreSQL 16.14, 0 errors |
| `SCHEMA_GUIDE.md` | same | Target: **Next.js + Prisma** API at `chrome.credifyfast.com/api` |
| `schema.prisma` | same | Prisma is the schema authority |
| `CLUSTER_EMAIL_DB_README.md` | same — **ret by Taras** | An isolated Cluster Email DB (33 tables + 1 view) built to merge into the unified schema |

The unified schema's actual conventions, verified by reading it:

- **Quoted CamelCase** identifiers — `"Organization"`, `"EmailJobRecipient"`
- **TEXT cuid primary keys, minted app-side** — `gen_random_uuid` appears **zero** times
- **`TIMESTAMP(3)`**, not `timestamptz`
- **Multi-tenant**: `organizationId` on every CRM table (312 occurrences) plus Postgres
  RLS keyed on the `app.current_org` session setting
- **AES-256-GCM envelopes** for sensitive columns (`*Enc BYTEA` + `*Iv` + `*Tag`)
- `Contact`, `ContactType`, `EmailTemplate`, `AuditEvent`, `NotifTemplate`, `OrgSetting`
  already exist as tables

ADR-0002 was not wrong on the merits. It was wrong on the facts, and it made a decision
that was already made. Its own logic — *"the guard chain is JavaScript; choose the
runtime that lets you move it rather than rewrite it"* — argues **more** strongly for
Next.js/Prisma than for a fresh Express app, because that's where the rest of Credify
already runs.

## Decision

**This module adopts the unified schema's stack and conventions. It does not invent its
own.**

1. **Prisma owns the schema.** Not hand-written SQL migrations. ADR-0002's "no ORM
   auto-migration" is withdrawn.
2. **The API is Next.js** at `chrome.credifyfast.com/api`, not a standalone Express app.
   ADR-0002's Express conclusion is withdrawn; its **PostgreSQL** conclusion stands and
   is confirmed.
3. **Conventions follow the unified schema, not this doc set:**
   - Quoted CamelCase tables and columns
   - TEXT cuid PKs, **minted app-side** — the front end already mints its own ids
     (`"t"+Date.now()`, `c1`, `job_…`) and sends them up. **Accept client ids; do not
     generate new ones.**
   - `TIMESTAMP(3)`
   - `organizationId` on every table
4. **[data-model.md](../data-model.md)'s proposed schema is demoted to a design sketch.**
   [database-cluster-email.md](../database-cluster-email.md) — Taras's isolated DB — is
   the schema of record for this module.
5. **Build against the isolated DB, merge later** via its MERGE MAP header, restoring the
   two conventions it relaxes on purpose: **RLS/org-scoping policies** and Prisma-owned
   `updatedAt`.
6. **The PHI classification is still required** and does not exist in either schema. It
   is carried forward from [ADR-0005](0005-phi-minimization-in-outreach.md) as a
   condition of merge, not dropped because the unified schema is silent on it.

## Consequences

**Positive**

- The module merges instead of being rewritten. Taras's stated goal — *"the names and
  conventions already match, so the merge is mostly a lift"* — only holds if we adopt
  them, and it is worth a great deal.
- Encryption at rest arrives free: the AES-256-GCM envelope pattern already exists and is
  smoke-tested. [security-compliance.md](../security-compliance.md) listed this as ⬜ and
  was wrong to.
- RLS + `organizationId` is a genuinely stronger isolation story than the
  "single-tenant per deployment" I proposed — two fences instead of one, enforced by the
  database rather than by developer discipline.
- One stack across Credify. No second deployment target, no second set of habits.
- Client-minted ids remove a whole class of bug: the front end already assumes the id it
  minted is the id that persists, and there are 54 `api()` call sites relying on that.

**Negative**

- **Prisma weakens the audit-log guarantee I argued for.** ADR-0002 wanted `REVOKE
  UPDATE, DELETE` at the grant level precisely so no ORM could rewrite history. Prisma
  owning the schema makes that a convention rather than a database-enforced invariant.
  **Mitigation: keep the REVOKE.** Prisma may own the tables; it must not own the audit
  grants. Verify this survives the merge.
- CamelCase + quoted identifiers means every raw SQL string needs quoting, forever. Miss
  one and Postgres folds it to lowercase and the error is confusing. Cost of consistency.
- Client-minted ids mean the server must **validate** them — uniqueness, format, and no
  id-collision attacks. A client that picks its own PKs can pick someone else's. This
  needs an explicit check that a fresh `uuid` default would have made unnecessary.
- `TIMESTAMP(3)` without a zone pushes timezone correctness into the application, where
  it is easy to get wrong. This module has four timezone-sensitive features (quiet hours,
  business hours, scheduled sends, frequency caps) and Taras's guide already notes
  `sendAt` is computed in the *contact's* time zone. Test the matrix.
- Next.js as the API host is heavier than Express for what is mostly JSON routes.
  Irrelevant next to merge cost.

**Neutral**

- Nothing about [ADR-0004](0004-server-side-enforcement-of-send-guards.md) changes. The
  guard chain still has to be enforced server-side, and Taras's §5 covers only three of
  the nine guards.

## Alternatives considered

**Keep ADR-0002 as written — build a standalone Express app with `snake_case`/`uuid`.**
Rejected. It would produce a module that cannot merge without a rename-everything
migration, and it would fork Credify's stack for one module's convenience. The only
argument for it is that it's what I already wrote down, which is not an argument.

**Skip the isolated DB; build straight against the unified schema.** Tempting — one fewer
artifact and no merge step. Rejected for the reason Taras built it: the unified schema is
105 tables serving two products, and a junior dev learning this module should not have to
load all of it, nor risk breaking the CRM while iterating on outreach. The isolated DB is
a deliberate blast radius, and the MERGE MAP is the path back.

**Adopt the conventions but keep plain SQL migrations alongside Prisma.** Rejected: two
schema authorities is worse than either alone. Whichever one loses drifts silently.

**Wait for the risk assessment before deciding.** Rejected: the conventions question is
independent of compliance scope, and deferring it means writing more code in the wrong
shape.

## Implementation

- [database-cluster-email.md](../database-cluster-email.md) — the schema of record and
  its reviewer's appendix
- [data-model.md](../data-model.md) — demoted to a sketch; banner added
- [project-status.md](../project-status.md) — stack tables corrected
- **Blocking:** obtain `credify_cluster_email_isolated.sql` from Taras. The schema of
  record is currently a README describing a file we do not have.
