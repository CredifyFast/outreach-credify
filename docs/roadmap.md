# Roadmap

> **Audience:** anyone planning or funding the work. **Purpose:** phases, exit criteria,
> and what actually determines the date.

> **Estimates, not commitments.** No deadline was given for this project. These are
> engineering estimates for **one full-time developer**. They assume the BAA track starts
> immediately and runs in parallel — because it is calendar-bound, not effort-bound.

## The shape of the problem

The instinct is to sequence this as: build the backend, then wire up email, then do the
compliance paperwork before launch. That ordering adds months, because the paperwork has
a multi-week external dependency and the risk assessment's findings change the schema you
already built.

**The BAA and the risk assessment start in week 1, in parallel with everything.** They
are the long pole. Phase 0 costs two days and unblocks everything else; the legal track
costs four hours of forms and then weeks of waiting on somebody else's counsel.

```
 Week   1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
        │
 Legal  ████████████████████████████████████░░░░░░  BAA + risk assessment (external wait)
        │                                    ▲
        │                                    └─ gates the first real send, not the code
 Code   ██ P0
           ████████████ P1 backend
                        ████████████████ P2 guards
                                         ████████████████ P3 compliance
                                                          ████████████ P4 deliverability
                                                                       ████████ P5 pilot
```

If the legal track starts in week 6 instead of week 1, the launch moves to week 21. No
amount of engineering recovers that. **That is the single most important scheduling fact
in this document.**

---

## Phase 0 · Repo hygiene

**Estimate:** 1–2 days · **Blocks:** everything

The repo can't be tested, linted, or CI'd because it has no manifest. Every later phase
inherits whatever mess we leave here.

| Work | Detail |
| --- | --- |
| `.gitignore` | Doesn't exist. `node_modules`, `.env`, `qa/`, OS cruft |
| Remove `test.v1` | 4 lines of "test" from commits `f1254f0`, `94141b7` |
| Resolve duplicate `index.html` | md5-identical to the mockup. Pick one source of truth ([R-1](project-status.md#risks)) |
| Fix `home.html` lineage header | Line 3 says `FILE: index.html` |
| `package.json` | Pin Node (local is v24.16.0), add scripts, test runner |
| CI | Lint + syntax check on every PR |

**Exit criteria**

- [ ] `npm test` runs and passes (even with one trivial test)
- [ ] CI green on a PR
- [ ] Exactly one canonical app HTML file; no byte-identical duplicates
- [ ] `git status` clean on a fresh clone; no junk tracked

---

## Phase 1 · Backend skeleton

**Estimate:** 2–3 weeks · **Depends on:** Phase 0, and the PHI boundary decision
([ADR-0005](adr/0005-phi-minimization-in-outreach.md))

Next.js + Prisma + Postgres + auth ([ADR-0008](adr/0008-align-with-unified-credify-schema.md)).
No sending yet — the send route stays behind a flag that is
**off in every environment**.

| Work | Detail |
| --- | --- |
| Next.js API + the [gate](api-design.md#the-gate) | Mounted above the router, not per-route |
| Postgres + Prisma migrations | Schema of record: [database-cluster-email.md](database-cluster-email.md) (ret by Taras). **Blocked until the `.sql` is delivered** |
| Authn + sessions | Server-side, revocable |
| RBAC | Deny by default, incl. Compliance Officer read-only |
| **Extract domain logic** | Guards, PHI scanner, audience filter → pure modules, no DOM |
| Wire `api()` to HTTP | The one-line swap; **delete the `console.debug`** |
| **Kill switch** | Halt all outbound. Build it now, before you need it |

**Extract before you port.** The guard chain currently lives inside a DOM-coupled 4,598-
line file. Lift it to pure functions *with tests* first, then call it from the API. Trying
to do both at once means rewriting the most security-critical code in the project without
a safety net.

**Exit criteria**

- [ ] `api()` makes real HTTP calls; zero behavior regressions in the UI
- [ ] No route reachable without passing the gate — proven by a test that adds an
      unprotected route and watches CI fail
- [ ] Guards run as pure Node modules with unit tests
- [ ] `console.debug` of request bodies is gone; a test proves logs carry no PHI
- [ ] Send route exists but is flag-disabled everywhere
- [ ] Kill switch tested

---

## Phase 2 · Guards server-side

**Estimate:** 3–4 weeks · **Depends on:** Phase 1

The security phase. All 9 guards enforced server-side, with the client demoted to
advisory.

| Work | Detail |
| --- | --- |
| Server-side audience resolution | **From criteria, never from client IDs** |
| All 9 guards | Mirroring `doQueueSend()`; see [api-design.md](api-design.md#post-sends--the-guard-chain) |
| Discharge ack signature | Port `dischargeAckSig()` exactly; verify server-side |
| Suppression in the send transaction | Absolute; no override path exists |
| Idempotency on `POST /sends` | |
| Durable append-only audit log | Same transaction as the mutation; `UPDATE`/`DELETE` revoked at grant level |
| **Bypass tests** | Adversarial: forge recipient lists, skip acks, replay keys, race the cap |

**Exit criteria**

- [ ] Every guard has a test that **tries to bypass it and fails**
- [ ] A forged recipient list in the request body is rejected by schema validation
- [ ] A test proves no code path can send to a suppressed address
- [ ] Audit entries are atomic with their action — killing the process mid-write leaves
      both or neither
- [ ] Double-clicking Send produces one job, proven by test

---

## Phase 3 · Compliance hardening

**Estimate:** 3–4 weeks · **Depends on:** Phase 2 · **Gated by:** the legal track

Where the legal track and the code track meet. If the BAA started in week 1, this is
where it pays off; if it didn't, this is where the project stops and waits.

| Work | Detail |
| --- | --- |
| Encryption at rest | Volume + column for `is_phi` values |
| KMS | Keys out of env vars |
| MFA | For PHI-capable roles |
| Retention + purge | Audit 6 years; delivery events 1 year |
| Log scrubbing verified | By test, under realistic payloads |
| Self-host fonts | Removes a third-party request from a PHI app |
| Backup + **restore rehearsal** | An untested backup is a rumor |
| Risk-assessment findings | Addressed |

**Exit criteria**

- [ ] Every item in the [go-live checklist](security-compliance.md#go-live-checklist)
      technical section is ✅
- [ ] BAAs signed: ESP, SMS, hosting, **and every log/APM/error vendor**
- [ ] Risk assessment closed
- [ ] Restore performed end to end, from a real backup, timed
- [ ] Encryption verified by inspecting the disk, not the config

---

## Phase 4 · Deliverability

**Estimate:** 2–3 weeks · **Depends on:** Phase 3 (**BAA must be signed** — no PHI-capable
vendor before the paperwork)

Real email. The Deliverability tab currently fabricates every verdict it displays; this
phase makes it honest.

| Work | Detail |
| --- | --- |
| ESP integration | Behind an interface — vendors get replaced |
| SPF / DKIM / DMARC | Actually configured, actually verified |
| Bounce/complaint webhooks | Signature-verified; auto-suppress on hard bounce + complaint |
| Unsubscribe endpoint | Public, one-click, unauthenticated, **permanent contract** |
| SMS + STOP handling | Auto-suppress on STOP |
| Scheduled send execution | Durable queue, exactly-once |
| Rate limiting / backoff | The vendor sets the pace |

**Unsubscribe URLs live in inboxes forever.** That endpoint's contract can never break.
Design it once, carefully, and version it from day one.

**Exit criteria**

- [ ] Real email delivered to a real inbox in staging
- [ ] DMARC passing; SPF/DKIM aligned
- [ ] Hard bounce auto-suppresses, proven end to end
- [ ] Unsubscribe works from a real email in one click
- [ ] SMS STOP auto-suppresses
- [ ] A scheduled send fires **once** — verified under a simulated restart at the
      scheduled moment
- [ ] Deliverability tab shows real data or is honestly labeled

---

## Phase 5 · Pilot

**Estimate:** 2 weeks · **Depends on:** Phase 4 + **signed BAA with the pilot agency**

One agency. **Non-PHI outreach only** — referral partners, not clients. Prove the
mechanism before trusting it with the hard cases.

| Work | Detail |
| --- | --- |
| Onboard one agency | Real contact types, real templates |
| Instrument the metrics | Guard trip rate, **override rate**, suppression violations |
| Daily audit-log review | For the first two weeks, by a human |
| Feedback loop | Especially: where did the safe path feel slower than the unsafe one? |

**Exit criteria**

- [ ] 4 weeks, zero suppression violations
- [ ] Zero PHI in any outbound body, verified by sampling
- [ ] Guard override rate < 5% — **if it's higher, the design is wrong, not the users**
- [ ] Audit log complete and reconcilable against the ESP's own records
- [ ] The agency wants to keep using it

**The override rate is the real exit criterion.** If operators routinely acknowledge and
send anyway, the guard has become a speed bump that trains people to click through
warnings — which is worse than no guard, because it manufactures false confidence. The
fix is to make the safe path faster, not the warning louder.

---

## Milestones

| Milestone | Phase | Meaning |
| --- | --- | --- |
| **M0 · Repo is real** | 0 | CI green, one source of truth |
| **M1 · Server exists** | 1 | Real HTTP, real auth, nothing sends |
| **M2 · Guards are real** | 2 | The security fix. Client bypass no longer matters |
| **M3 · Legally clear** | 3 | BAAs signed, risk assessment closed |
| **M4 · Email is real** | 4 | Actual delivery, actual unsubscribe |
| **M5 · One happy agency** | 5 | Non-PHI pilot proven |
| **M6 · PHI-capable** | — | Full go-live checklist ✅. **Not before.** |

## Dependencies

```
 Phase 0 ─┬─▶ Phase 1 ─▶ Phase 2 ─▶ Phase 3 ─▶ Phase 4 ─▶ Phase 5 ─▶ M6
          │                            ▲
 ADR-0005 ┘ (PHI boundary)             │
    ▲                                  │
    │                                  │
 Risk assessment ──────────────────────┤
 BAA procurement ──────────────────────┘   ← starts week 1, external wait
```

| Dependency | Blocks | Lead time | Owner |
| --- | --- | --- | --- |
| **BAA procurement** | Phase 4, M6 | **4–10 wks, external** | Jay / counsel |
| **Risk assessment** | Phase 3 | 1–2 wks + remediation | Jay / counsel |
| **PHI boundary ([ADR-0005](adr/0005-phi-minimization-in-outreach.md))** | Data model, Phase 1 | 2–3 days | Tech lead + counsel |
| ESP selection | Phase 4 | 1 wk, after BAA terms | Tech lead |
| Hosting decision | Phase 1 | 2 days | Tech lead |

## Team

**Currently: one developer, part-time, no bus factor.**

| Role | Need | Have |
| --- | --- | --- |
| Backend engineer | Phases 1–4, full-time | ⬜ |
| Compliance counsel | Phases 0–3, advisory | ⬜ |
| Security review | Before M6 | ⬜ |
| Product/domain | Ongoing | ✅ Jay |

The estimates assume **one full-time backend engineer**. At the current staffing —
part-time, one person, also doing product — multiply by roughly 2.5–3×. That puts M6
somewhere past week 40, and it is worth saying that out loud rather than discovering it
in month six.

## Risks to the schedule

| Risk | Impact | Mitigation |
| --- | --- | --- |
| **BAA starts late** | Day-for-day slip, unrecoverable | Start week 1. Backlog #1 |
| **Risk assessment finds schema problems** | Phase 1 rework | Do it before Phase 1, not after |
| Guard extraction is harder than estimated | Phase 1–2 slip | Extract with tests first; don't port and rewrite together |
| Deliverability rabbit hole | Phase 4 doubles | Timebox; DMARC is fiddly and always takes longer |
| Single developer unavailable | Full stop | This doc set is the mitigation. Hire before Phase 1 |
| Scope creep (segments, triggers) | Endless | Both are parked **on purpose**. Keep them parked until M5 |

## Related

- [project-status.md](project-status.md#prioritized-backlog) — the ordered backlog
- [security-compliance.md](security-compliance.md#go-live-checklist) — what M6 requires
- [architecture.md](architecture.md) — what's being built
