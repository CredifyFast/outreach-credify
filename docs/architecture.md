# Architecture

> **Audience:** engineers building or reviewing this system. **Purpose:** how it's shaped
> today, how it must be shaped to ship, and why.

> ## ⚠ Half of this document describes a system that does not exist.
>
> "Today" sections describe verified, running code. "Target" sections describe a design
> decision with **zero lines written**. Every section says which it is.

## Principles

Four rules, derived from what the prototype already does well and what will kill it.

1. **The server is the authority; the client is a convenience.** Today every rule lives
   in the browser. That's fine for a prototype and fatal in production. Every guard gets
   re-implemented server-side, and the client copy exists only so users get fast feedback.
   ([ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md))
2. **Safe by default, unsafe by signature.** Never silently block, never silently allow.
   Surface the risk, name it precisely, require an explicit acknowledgment tied to the
   exact audience. The prototype's `dischargeAckSig` does this well — the ack is keyed to
   a hash of the recipient IDs, so changing the audience invalidates it. Keep that.
3. **Pure domain logic, no DOM.** Guards, scanners, and audience filters must be
   importable by Node with no `window`. Today they aren't, and that's why they can't be
   tested or reused. ([ADR-0003](adr/0003-single-file-html-prototype.md))
4. **PHI is a liability, not an asset.** Don't store it if you don't need it, don't send
   it if you can link to it, don't log it ever.
   ([ADR-0005](adr/0005-phi-minimization-in-outreach.md))

## System diagram — today (verified)

Everything inside the browser. There is no other box.

```
┌────────────────────────── BROWSER ───────────────────────────┐
│                                                              │
│  index.html  (4,598 lines · 1 <script> · 1 <style>)          │
│                                                              │
│   ┌─────────────┐   render()    ┌──────────────────┐         │
│   │  state      │──────────────▶│  DOM (12 tabs)   │         │
│   │  (line 1907)│◀──────────────│  data-action     │         │
│   └──────┬──────┘   dispatcher  └──────────────────┘         │
│          │                                                   │
│          │ persistState()                                    │
│          ▼                                                   │
│   ┌──────────────────────────────┐                           │
│   │ localStorage                 │                           │
│   │ "credify_cluster_email_v1"   │                           │
│   └──────────────────────────────┘                           │
│          ▲                                                   │
│          │                                                   │
│   ┌──────┴───────────────────────────────────┐               │
│   │ api(method, path, body)   ← line 1898    │               │
│   │   console.debug("[api stub]", …)         │               │
│   │   persistState()                         │               │
│   │   return {ok:true}      ← NO NETWORK     │               │
│   └──────────────────────────────────────────┘               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
         │
         │ the only outbound request in the entire app:
         ▼
   fonts.googleapis.com  (Sora, Instrument Serif)
```

**That font request is the only network traffic this application generates.** Verified:
`grep -c "fetch(\|XMLHttpRequest" index.html` → 0.

## System diagram — target (not built)

```
┌── BROWSER ────────────────┐
│  index.html               │
│  state + render           │
│  client guards (advisory) │
│  api() ── HTTP ──────────────┐
└───────────────────────────┘  │
                               ▼
                    ┌──────────────────────────────┐
                    │  Express app                 │
                    │                              │
                    │  session auth ──────────┐    │
                    │  ┌──────────────────────▼─┐  │
                    │  │ THE GATE               │  │
                    │  │  authn → authz →       │  │
                    │  │  validate → guards     │  │
                    │  └──────────┬─────────────┘  │
                    │             ▼                │
                    │  routes → domain (pure)      │
                    │             │                │
                    │  ┌──────────┴────────────┐   │
                    │  │ audit (append-only)   │   │
                    │  └──────────┬────────────┘   │
                    └─────────────┼────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
       ┌────────────┐     ┌──────────────┐    ┌──────────────┐
       │ PostgreSQL │     │ ESP (BAA)    │    │ SMS (BAA)    │
       │ encrypted  │     │ send+webhook │    │ send+STOP    │
       └────────────┘     └──────────────┘    └──────────────┘
```

> ⚠ **Diagram superseded 2026-07-16.** "Express app" should read **Next.js + Prisma**
> — this module merges into the existing 105-table `credify_unified_schema.sql` rather
> than standing up its own server. The *shape* (gate → routes → pure domain → audit) is
> unchanged and still correct. See
> [ADR-0008](adr/0008-align-with-unified-credify-schema.md) and the schema of record,
> [database-cluster-email.md](database-cluster-email.md) (ret by Taras).

Note what the gate is: **not middleware you can forget to apply.** See
[api-design.md](api-design.md#the-gate).

## Tech choices and rationale

### Today (verified)

| Choice | Why it was right | What it costs now |
| --- | --- | --- |
| Single-file HTML | Zero setup; the whole app is one artifact you can email. For discovering a domain nobody had modeled, that speed was worth real money | Can't test, can't reuse server-side, 4,598-line merge conflicts. [ADR-0003](adr/0003-single-file-html-prototype.md) |
| No framework | No build step, no dependency churn, no supply-chain surface. The `state` + `render()` + dispatcher pattern is coherent and hand-rolled | Manual re-render; no component isolation |
| `localStorage` | Instant persistence with no server | Not durable, not shared, not encrypted, user-clearable. Fatal for audit. [ADR-0006](adr/0006-localstorage-persistence-is-prototype-only.md) |
| `api()` stub | **The best decision in the repo.** It made the client write real route names against a real signature, so the eventual backend has a specification instead of a guess | Zero enforcement — every rule is bypassable |

The `api()` stub deserves emphasis. Whoever wrote `async function api(method,path,body)`
and then called it from 54 sites with real REST semantics was deliberately building a seam.
The 41 routes in [api-design.md](api-design.md) were extracted mechanically from those
calls — the client already told us what the server must do.

### Target (decided, unbuilt)

| Choice | Why | Alternatives rejected |
| --- | --- | --- |
| **Next.js + Prisma** (~~Express~~) | The domain logic is already JavaScript, so extraction is a move rather than a rewrite — and the rest of Credify already runs this stack. [ADR-0002](adr/0002-node-express-postgres-backend.md) chose Express **before we knew a unified schema existed**; [ADR-0008](adr/0008-align-with-unified-credify-schema.md) supersedes it | PHP/XAMPP (rejected: hand-porting the guards), Serverless (rejected: scheduled sends fit poorly), standalone Express (rejected: forks the stack, cannot merge) |
| PostgreSQL | Relational, mature encryption story, real constraints. Suppression correctness is a uniqueness problem and belongs in the DB | MySQL (fine, but no reason to prefer), Mongo (rejected: this is relational). [ADR-0002](adr/0002-node-express-postgres-backend.md) |
| Session auth, server-side | Simpler than JWT for a single-tenant app; instant revocation matters when someone is fired | JWT (rejected: revocation) |
| BAA-gated ESP | Non-negotiable for PHI | [ADR-0007](adr/0007-baa-gated-vendor-selection.md) |

## Request lifecycle — target

A `POST /sends`, end to end. Compare against the client-side chain in
[project-status.md](project-status.md#project-flow) — **the steps are deliberately the
same**, because the server is re-running the client's work rather than trusting it.

```
POST /sends  {templateId, audience, mode, scheduledAt, tracking}
  │
  ├─ 1. authn        session valid?                    → 401
  ├─ 2. authz        may this user send?               → 403
  ├─ 3. schema       shape/types valid?                → 422
  ├─ 4. idempotency  Idempotency-Key seen?             → replay stored response
  │
  ├─ 5. RECOMPUTE AUDIENCE SERVER-SIDE
  │      Never trust a client recipient list. Re-run the filter chain
  │      from the DB. The client sends *filter criteria*, not IDs.
  │
  ├─ 6. GUARD CHAIN (server is authority)
  │      recipients > 0                                → 422
  │      template exists                               → 404
  │      not scheduled in the past                     → 422
  │      PHI findings acknowledged                     → 422 + findings
  │      discharged acknowledged (sig matches audience)→ 422 + ids
  │      frequency cap acknowledged                    → 422 + capped
  │      suppression/opt-out applied, willSend > 0     → 422
  │      sender identity resolved                      → 422
  │
  ├─ 7. persist job + recipients   (transaction)
  ├─ 8. append audit entry         (same transaction — atomic or it didn't happen)
  ├─ 9. enqueue for delivery
  └─ 201 {jobId, willSend, skipped}
```

**Step 5 is the one people get wrong.** If the client posts a list of recipient IDs and
the server sends to them, then every filter, every suppression check, and every opt-out
is client-side security — which is to say, none at all. The client must post the
*criteria*; the server resolves them against the database. This is the difference between
a system that enforces consent and one that merely displays it.

**Step 8 shares the transaction with step 7** deliberately. An audit log that can be
missing entries because a write failed after the job was created is not an audit log.

## Data flow — PHI

Where PHI can move, and where it must not. This is the map behind
[ADR-0005](adr/0005-phi-minimization-in-outreach.md).

```
  EHR / intake  ──▶  contacts.form_data     (demographics, financial,
                     (5 forms, 20 field      insurance, clinical, consent)
                      types incl. ssn,
                      signature, file)
                          │
                          │  merge tags {{slug.key}}
                          ▼
                     template render
                          │
              ┌───────────┴────────────┐
              │  PHI SCAN              │
              │  5 regex patterns      │  ssn / mrn / dob / member_id / dx
              │  13 tag keys           │  ssn, tax_id, dob, primary_dx,
              │  slug "clinical"       │  phq9_severity, risk_level, …
              └───────────┬────────────┘
                          │
              ┌───────────┴────────────┐
              ▼                        ▼
        findings = 0             findings > 0
              │                        │
              ▼                        ▼
           send                 require ack ──▶ [ADR-0005 target: BLOCK]
                                       │
                                       ▼
                              ┌─────────────────┐
                              │ outbound email  │  ← PHI must not reach here
                              └─────────────────┘
                                       │
                                       ▼
                              portal notice pattern:
                              "You have a secure message" + link
```

**Never in logs.** `console.debug("[api stub]", method, path, body)` at `index.html:1898`
prints full request bodies to the console — including, today, seeded fake SSNs. It's
harmless now because the data is fake and there's no server. It is a template for a
catastrophe: the same line in a Node process writes PHI into your log aggregator, which
almost certainly has no BAA. **Delete that line when the stub is replaced.** See
[security-compliance.md](security-compliance.md#logging).

## Scalability

Honest answer: **irrelevant today, and probably irrelevant at launch.** A behavioral
health agency has hundreds to low thousands of contacts. Ten agencies is tens of
thousands. Postgres on a single modest instance handles this without trying.

Do not build for scale you don't have. The real constraints are different:

| Constraint | Why it actually binds | Response |
| --- | --- | --- |
| **ESP rate limits** | Vendors throttle. A 2,000-recipient job is the vendor's pace, not yours | Queue with backoff. Job status must reflect partial progress |
| **Scheduled sends** | Someone schedules 9am Thursday; the box must be up and the job must fire exactly once | Durable queue + idempotency. Not a scaling problem — a correctness problem |
| **Audit log growth** | Append-only, never deleted, retained for years | Partition by month. Plan storage, not throughput |
| **Webhook bursts** | Opens/clicks arrive faster than sends | Accept fast, process async. Never block on webhook handling |

The thing that will fall over first is not the database — it's exactly-once scheduled
delivery. Design for that.

## Risks and mitigations

| Risk | Impact | Mitigation | Tracked |
| --- | --- | --- | --- |
| Guards are client-side only | HIPAA breach | Server-side re-implementation | [ADR-0004](adr/0004-server-side-enforcement-of-send-guards.md), backlog #8 |
| Domain logic entangled with DOM | Can't test or reuse; guard port becomes a rewrite | Extract to pure modules **before** the backend | backlog #6 |
| Audit log in `localStorage` | Fails HIPAA audit requirements | Durable append-only table | backlog #9 |
| `api()` logs full bodies | PHI in logs | Delete the debug line at swap time | [security-compliance.md](security-compliance.md#logging) |
| Client posts recipient IDs | Consent enforcement bypassed | Server recomputes audience from criteria | Step 5 above |
| Two identical `index.html`/mockup files | Divergence, ambiguous source of truth | Pick one, delete the other | [Risk R-1](project-status.md#risks) |
| Google Fonts dependency | External request from a PHI-adjacent app; referrer leakage; availability | Self-host the fonts before launch | backlog (add during Phase 3) |

## Related

- [api-design.md](api-design.md) — the routes and the gate
- [data-model.md](data-model.md) — the schema
- [security-compliance.md](security-compliance.md) — threat model
- [ADR index](README.md#adr-index)
