# Operations runbook

> **Audience:** whoever is on call. **Purpose:** what to do when it's running, and when
> it's broken.

> ## ⚠ There is nothing to operate.
>
> No service is deployed. There is no on-call, no pager, no SLO, no backup — because
> there is no system. **This document is a plan for Phase 3+.**
>
> It exists now for one reason: several items here (the kill switch, the audit-log
> snapshot procedure, the breach clock) must be **designed into the build**, not bolted on
> after the first incident. A runbook written the night of an incident is written by
> someone who is panicking.

## Service map (⬜ target)

| Service | Purpose | Failure impact | Recovery |
| --- | --- | --- | --- |
| **App (Node / Next.js)** | The API + static | Total outage. Nothing sends | Redeploy previous image |
| **Postgres** | All data incl. audit | Total outage + **data risk** | Restore from snapshot. See [DR](#disaster-recovery) |
| **Queue** | Scheduled + outbound | Sends stall. **Scheduled sends may miss their window** | Drain and replay. Idempotency prevents duplicates |
| **ESP** | Email delivery | No email. Reputation risk if retried badly | Backoff. Do not hammer |
| **SMS vendor** | SMS + STOP | No SMS. **STOP handling stops — a consent risk** | Escalate to vendor |
| **KMS** | Encryption keys | Cannot decrypt PHI. Effectively total outage | Vendor escalation |

**The SMS row is the one people miss.** If STOP handling is down, people who opt out
aren't recorded as opting out, and the next send goes to them. An SMS vendor outage is
therefore a **consent incident**, not just an availability one. Halt SMS sending until
STOP processing is confirmed healthy.

## Deploys and rollback

Procedure in [deployment.md](deployment.md#deploy-procedure--target). This is the "it's
going wrong" half.

### Rollback

```
Something's wrong post-deploy
        │
        ├─ Is data being corrupted or PHI exposed?
        │     YES ──▶ 1. FEATURE_SENDING_ENABLED=off   (kill switch first)
        │             2. Snapshot the audit log
        │             3. Then diagnose. Containment beats understanding.
        │
        ├─ Code-only change?
        │     YES ──▶ Redeploy previous version. Fast, safe, boring.
        │
        └─ Migration involved?
              │
              ├─ Additive (new table/column/index)?
              │     YES ──▶ Roll back code only. Leave the schema.
              │             An unused column harms nothing.
              │
              └─ Destructive (drop/alter/backfill)?
                    YES ──▶ ⚠ STOP. Do not "roll back" the migration.
                            Down-migrations on live data lose data.
                            Write a FORWARD fix. Restore only if
                            data is already corrupt — and accept the
                            data loss window that implies.
```

**The instinct to run the down-migration is almost always wrong.** A down-migration
tested on an empty dev database, run against production data under time pressure, is how
a bad deploy becomes a data-loss incident. Forward-fix.

**Kill switch first, always.** `FEATURE_SENDING_ENABLED=off` halts outbound. It costs
nothing to flip and un-flip. A stopped send can be resumed; a sent email cannot be
unsent.

## Health and SLOs

⬜ No baseline. Proposed once there's traffic:

| Signal | Target | Why |
| --- | --- | --- |
| API availability | 99.5% | Business hours matter; nights are cheap |
| p95 latency | < 500ms | Audience filtering is the slow path |
| Send success | > 98% | Excluding legitimate suppression skips |
| Bounce rate | < 2% | Above this the ESP starts throttling you |
| Complaint rate | < 0.1% | Above this the ESP drops you entirely |
| **Suppression violations** | **0** | Not an SLO. A **bug class**. Any occurrence is P1 |
| Scheduled send accuracy | Within 5 min | |

`/healthz` — liveness, no auth, no data. `/readyz` — DB + queue reachable.
**Neither endpoint returns anything about contacts, counts, or PHI.** A health endpoint
that leaks "1,847 contacts" is an information disclosure on an unauthenticated route.

## Backups and restore

| | |
| --- | --- |
| What | Full Postgres, incl. `audit_log` |
| Frequency | Daily full, continuous WAL |
| Retention | 30 days point-in-time; **audit data 6 years** (HIPAA) |
| Encryption | At rest, KMS-managed |
| Location | Separate failure domain from prod |
| **Testing** | **Quarterly restore rehearsal. Timed. Written up.** |

**An untested backup is a rumor.** The rehearsal isn't about whether the file exists —
it's about whether you can restore it under pressure, how long it takes, and who knows
how. Every one of those is unknown until you've done it once on a calm afternoon.

### Restore

1. Stop the app. `FEATURE_SENDING_ENABLED=off` **first** — a restored DB with stale job
   state can re-send.
2. Identify the target timestamp. Prefer the latest clean point before the incident.
3. Restore to a **new instance**. Never over the original — you may need it for forensics.
4. Verify: row counts, latest `audit_log` entry, `jobs` in `sending` state.
5. **Reconcile jobs.** Anything mid-flight at snapshot time is ambiguous: did it send?
   Check the ESP's records, not your own — theirs are the ground truth for what left the
   building.
6. Repoint the app. Smoke test.
7. Re-enable sending only after job state is reconciled.

**Step 5 is where duplicate sends come from.** A restore rewinds your database but not the
ESP's outbox. Resuming a job that already sent means sending twice, which trips frequency
caps, annoys partners, and — for a clinical reminder — is a small but real harm.
Idempotency keys make this recoverable; check them.

## Common tasks

| Task | Procedure |
| --- | --- |
| **Halt all sending** | `FEATURE_SENDING_ENABLED=off`. Takes effect immediately. First move in any send-related incident |
| **Cancel a queued job** | `DELETE /sends/{id}`. Only works while `queued`; in-flight recipients may already be gone |
| **Add a suppression** | `POST /suppressions`. Immediate, absolute, no override |
| **Investigate "why did X get this email?"** | Query `job_recipients` by `contact_id` → `jobs` → `audience_criteria` + `body_snapshot`. The snapshot is why this is answerable |
| **Prove we didn't email someone** | `audit_log` + `job_recipients`. **If the audit log is incomplete, you cannot answer this** — which is the whole argument for durability |
| **Rotate ESP key** | Update the secret, redeploy, verify a canary send, revoke the old |
| **Rotate session secret** | Invalidates every session. Announce first — it's a forced logout |
| **Restore a contact deleted by mistake** | Clear `deleted_at`. Soft delete exists for this |

## Incident severities

| Sev | Definition | Response | Examples |
| --- | --- | --- | --- |
| **P1** | PHI exposed, or consent violated | **Immediate.** Kill switch, snapshot audit, call counsel | PHI in an outbound body · sent to a suppressed address · unauthorized data access · **PHI found in logs** |
| **P2** | Total outage or data at risk | < 30 min | App down · DB unreachable · queue lost jobs |
| **P3** | Degraded | < 4h business hours | High bounce rate · slow audience filter · scheduled send late |
| **P4** | Minor | Next business day | UI bug · cosmetic |

**Any suppression violation is P1, not P3.** It looks like a small bug — one email to one
address. It is a consent violation with regulatory exposure, and it means a guard failed,
which means other guards may be failing silently. Treat it as a breach until proven
otherwise.

## Incident response

Compliance context in
[security-compliance.md](security-compliance.md#incident-response).

```
 Detect
   │
   ▼
 CONTAIN  ◀── FEATURE_SENDING_ENABLED=off
   │           Do this BEFORE you understand the problem.
   │
   ▼
 PRESERVE ◀── Snapshot audit_log + DB immediately.
   │           Do not "clean up." Do not delete the bad rows.
   │           You are now handling evidence.
   │
   ▼
 ASSESS   ◀── PHI involved? Whose? How many? Actually acquired?
   │
   ├── PHI? ──▶ CALL COUNSEL. 60-day notification clock may be running.
   │             Legal decides notification. Not engineering. Not the founder.
   │
   ▼
 REMEDIATE
   │
   ▼
 POSTMORTEM ◀── Blameless. Within 5 days. What made this possible?
```

**Preserve before you fix.** The instinct under pressure is to delete the bad data and
make it stop. That destroys your ability to scope the breach — and an unscopeable breach
gets scoped as worst-case, which means notifying everyone instead of the eleven people
actually affected.

**Engineering does not decide whether to notify.** That is a legal determination with
criteria that are not obvious. Escalate.

## On-call

⬜ Not established. Honest note: **with one part-time developer, "on-call" means "Jay,
whenever he sees it."** That's tolerable for a prototype and unacceptable for a system
sending clinical reminders — a P1 at 2am on a Saturday has nobody to answer it.

Before the pilot, decide the minimum viable version: business-hours coverage, a documented
escalation path, and an alert that reaches a human. Real rotation requires a second
person, which is a hiring dependency ([roadmap](roadmap.md#team)), not a scheduling one.

| | Target |
| --- | --- |
| Coverage | Business hours minimum; 24/7 once sending is real |
| Escalation | Primary → tech lead → **counsel for any P1 with PHI** |
| Alerting | Suppression violation, send failure spike, queue stall, auth anomaly |

## Disaster recovery

| Scenario | RTO | RPO | Plan |
| --- | --- | --- | --- |
| App instance lost | 15 min | 0 | Redeploy |
| DB corruption | 4h | < 5 min | PITR to a new instance |
| Region loss | 24h | < 1h | Cross-region backups. **Untested until rehearsed** |
| Ransomware / destructive compromise | 24h+ | < 1h | Immutable backups. Assume the live DB is gone |
| **Audit log lost** | — | **0 tolerance** | **There is no recovery.** Compliance evidence gone |

The last row has no RTO because there is no restoring it. If the audit log is lost, you
cannot prove what you did or didn't send, and every subsequent question from an auditor
gets answered with "we don't know." That is why it's append-only, partitioned, backed up
separately, and why `UPDATE`/`DELETE` are revoked at the grant level rather than merely
avoided in code.

## Related

- [deployment.md](deployment.md) — infra and config
- [security-compliance.md](security-compliance.md) — breach obligations
- [data-model.md](data-model.md) — what you're restoring
