# ADR-0002 · Node/Express + PostgreSQL for the backend

**Status:** **Partially superseded by [ADR-0008](0008-align-with-unified-credify-schema.md)** (2026-07-16)
**Date:** 2026-07-16

> **Superseded, and left intact on purpose.** Per
> [ADR-0001](0001-record-architecture-decisions.md), accepted ADRs are immutable — the
> wrong reasoning is as valuable as the right reasoning, because it records what the
> author knew at the time.
>
> **What survives:** PostgreSQL, and the core argument that the guard chain is JavaScript
> and should be *moved* rather than hand-ported.
>
> **What was wrong:** Express, plain-SQL migrations, `snake_case`, and `uuid` PKs. This
> ADR was written from the repository alone, and the repository never mentions that
> `credify_unified_schema.sql` already exists — **105 tables, Next.js + Prisma, quoted
> CamelCase, TEXT cuid PKs minted app-side.** The decision recorded below had already
> been made elsewhere, months earlier.
>
> The lesson worth keeping: *the repo is not the whole world.* Every fact here was
> verified against the code and still reached a wrong conclusion, because the scope of
> verification was too narrow. See [ADR-0008](0008-align-with-unified-credify-schema.md).

## Context

The prototype has no backend. `api()` at `index.html:1898` is a stub that writes to
`localStorage`; there are zero network calls in the codebase. A backend must be built,
and nothing about the stack has been written down.

Two conflicting signals existed:

1. **The repo lives in `C:\xampp\htdocs\`** — XAMPP is Apache + MySQL + PHP. A reasonable
   person reading the filesystem would conclude this is a PHP project.
2. **The project's HTML-editing conventions state these files "get wired into an
   Express / Node.js backend"** and instruct that core logic stay free of browser globals
   "so they can be lifted into Node."

Signal 1 is an artifact of how the maintainer previews HTML locally. Signal 2 is the
actual intent, and the code follows it — the domain logic is deliberately written to be
liftable.

The constraint that dominates everything: **the guard chain in `doQueueSend()` is the
most security-critical code in the project.** Nine sequential checks — PHI
acknowledgment, discharge acknowledgment, frequency caps, suppression — standing between
an operator and a HIPAA breach. It must run server-side
([ADR-0004](0004-server-side-enforcement-of-send-guards.md)).

That code exists, works, and is written in JavaScript.

## Decision

**Node.js + Express for the application server. PostgreSQL for the database.**

XAMPP is a local preview convenience and is not part of this project. It will not be used
in any deployed environment.

The deciding factor is the guard chain. Choosing Node means **moving** those functions
into `src/domain/` — a mechanical extraction, verifiable by running the same tests
against the same code. Choosing any other runtime means **hand-porting** them: a
line-by-line rewrite in a different language, of the exact code where a subtle
transcription error is a compliance incident rather than a bug.

The PHI scanner's five regexes must behave identically. `dischargeAckSig()`'s hash must
produce identical signatures. The AND-chained audience filter must resolve identically.
Every one of those is a chance to introduce a difference that no test catches because the
tests would also be rewritten.

PostgreSQL because the data is relational and because suppression correctness is a
uniqueness problem — `UNIQUE (channel, address)` is what makes "we never send to a
suppressed address" a database invariant rather than a hope. It also has a mature
encryption and row-level-security story, both of which matter under HIPAA.

## Consequences

**Positive**

- The guard chain moves rather than gets rewritten. Highest-risk code, lowest-risk port.
- One language across the stack. Validation logic is shared between client and server
  instead of duplicated and drifting.
- The `api()` stub's signature (`method, path, body`) maps directly onto Express routing.
  The seam was built for this.
- Postgres constraints enforce compliance invariants at the database level, where they
  can't be forgotten by a new code path.
- Large ecosystem for the boring necessities: sessions, validation, queues, ESP SDKs.

**Negative**

- **Nobody on this project has built a HIPAA-compliant Node backend before.** The stack
  is right; the experience gap is real and is a schedule risk the estimates don't fully
  price.
- Node's dependency tree is a supply-chain surface. Every package is a potential CVE in a
  system holding PHI. Mitigation: minimal dependencies, `npm audit` in CI, weekly scans.
- Requires a real host with a BAA. XAMPP-on-a-box would have been cheaper — and
  disqualifying for other reasons anyway.
- Two runtimes on the maintainer's machine (XAMPP for other projects, Node for this).
  Minor, and a source of exactly the confusion that motivated this ADR.
- Postgres is operationally heavier than SQLite or MySQL-on-XAMPP. Backups, PITR, and
  connection management become real work. Worth it for the constraints and encryption.

## Alternatives considered

**PHP + MySQL on XAMPP.** The host the repo already sits on; zero new infrastructure to
learn. Rejected on one point that outweighs everything else: **the guard chain would be
hand-ported to PHP.** Nine security-critical checks, five regexes, a signature hash, and
an audience filter, all transcribed by hand into a different language — where a subtle
difference in regex semantics or string comparison produces a guard that passes its tests
and fails in production. Secondary: XAMPP's shared document root
([deployment.md](../deployment.md#-isolation-rules-for-the-xampp-host--these-apply-today))
is a poor fit for PHI, and the Windows/Apache/XAMPP combination is not a production
posture any hosting provider will sign a BAA against.

**Serverless (Lambda / Cloud Functions) + managed Postgres.** Attractive: no servers to
patch, scales to zero, cheap at this volume. Rejected: scheduled sends and long-running
outbound jobs fit poorly — the app must reliably fire a job at 9am Thursday and process
thousands of recipients at the ESP's pace, which means either a durable queue plus
orchestration (most of the complexity back, plus a distributed system) or fighting
timeout limits. Cold starts also hurt the audience-filtering path, which is interactive.
Revisit if the deployment model changes.

**Node + MySQL.** Perfectly workable. Rejected for lack of a reason to prefer it: Postgres
has the stronger story on row-level security (relevant if multi-tenancy ever arrives),
partitioning (relevant for `audit_log`), and `citext` (relevant because email
case-insensitivity is a *correctness* requirement for the suppression list, not a nicety).
No MySQL advantage offsets those.

**Node + MongoDB.** Rejected: this data is aggressively relational — contacts to types to
statuses to stages to jobs to recipients to events. The suppression uniqueness constraint
and the audit log's append-only guarantee both want a database that enforces things.
Document stores make those application concerns, which is exactly where compliance
invariants go to die.

**Keep it client-only, ship the prototype.** Named because it's the implicit status quo
and someone will propose it under deadline pressure. Rejected absolutely: every guard is
bypassable with devtools, the audit log lives in `localStorage` where any user can clear
it, and there is no authentication. Deploying this against real contacts is a HIPAA
violation with a nice interface. See [ADR-0006](0006-localstorage-persistence-is-prototype-only.md).
