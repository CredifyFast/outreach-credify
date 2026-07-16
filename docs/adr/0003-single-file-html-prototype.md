# ADR-0003 · Single-file HTML prototype

**Status:** Accepted
**Date:** 2026-07-16
*Retroactive — documents a decision made before ADRs existed.*

## Context

The Cluster Email app is one file: `index.html`, 4,598 lines, one `<script>`, one
`<style>`, no build step, no dependencies, no framework. Open it in a browser and it runs.

This was never written down as a decision — it's simply how the project has always been
built, following the maintainer's convention for Credify HTML tools. Recording it now,
retroactively, because an engineer arriving at a 4,598-line HTML file will assume it's an
accident and "fix" it. It isn't an accident, and the fix has a specific right time.

Context that made it reasonable: one part-time developer, a domain nobody had modeled
yet (what *are* the rules for emailing a discharged behavioral health client?), and a
need to put something clickable in front of stakeholders quickly.

## Decision

**Build the prototype as a single self-contained HTML file. Keep doing so until the
backend forces the split — then extract domain logic first, and only what must move.**

The file has an internal structure that makes this viable: data and pure logic occupy
roughly lines 1051–1900, the DOM-coupled render/dispatch code sits below line 1907. That
seam is not accidental — the convention explicitly requires keeping "pure
data/validation/scoring functions free of `window`, `document`, `localStorage` so they
can be lifted into Node."

## Consequences

**Positive**

- **It worked.** Twelve tabs of genuinely sophisticated domain modeling — PHI scanning,
  frequency caps, quiet hours, suppression, discharge acknowledgment — exist because the
  cost of trying an idea was zero. A React scaffold would have spent the same weeks on
  build config and produced less domain insight.
- The artifact is portable: email the file, it runs. For stakeholder review with a
  non-technical founder, that's worth a lot.
- No build means no build breakage, no dependency churn, no supply-chain surface.
- The `SEED_*` constants forced the domain model to be explicit and complete. They're now
  the source for the reference-data migration — the most valuable thing in the repo to
  port faithfully.

**Negative**

- **Nothing can be unit tested.** The guard chain — the most security-critical code here
  — has zero tests, because you cannot import a function from an HTML file. This is the
  cost, and it's a big one.
- **The logic can't run server-side**, which is precisely what
  [ADR-0004](0004-server-side-enforcement-of-send-guards.md) requires.
- 4,598-line merge conflicts. Fine with one developer; hostile with two.
- **Whole-file regeneration has already silently destroyed work in this project's
  history** — which is why the convention now forbids it in bold. That's not a
  hypothetical risk; it happened.
- Duplicate-file confusion: `index.html` and the `CLUSTER_EMAIL_…` mockup are byte-
  identical with no marker saying which is canonical
  ([R-1](../project-status.md#risks)). Single-file artifacts get copied, and copies drift.
- No linting, no type checking, no CI. Every refactor is a leap of faith.

**The honest summary:** this decision bought real domain knowledge at the cost of all
verification. That was a good trade for discovery and is a bad trade for production. The
trade expires the moment PHI is involved.

## Alternatives considered

**A framework (React/Vue) from the start.** Rejected at the time, correctly: build config,
dependency management, and component design would have consumed the exploration budget.
The domain was the unknown, not the rendering. Still not obviously right *now* — the
`state` + `render()` + dispatcher pattern is coherent and understood, and rewriting the UI
buys nothing while the backend doesn't exist. Revisit when there are two front-end
developers, not before.

**Split into modules with a bundler.** Rejected at the time: a build step breaks
"double-click and it runs," which was the entire point for stakeholder review. Partially
adopted in Phase 1 — `src/domain/` is exactly this split, but only for the logic that must
move, not for the UI.

**Server-rendered from day one.** Rejected: presupposes the backend that this ADR exists
because we didn't have.

## Supersession

Not superseded — **scoped.** The single-file pattern remains correct for the front end
today. What changes in Phase 1 is that the domain logic below the seam gets extracted to
`src/domain/` so it can be tested and run server-side
([ADR-0004](0004-server-side-enforcement-of-send-guards.md),
[project-structure.md](../project-structure.md)).

**Extract with tests before porting.** Lift a function, write its tests, prove it behaves
identically, then call it from the API. Doing extraction and rewriting in one motion means
rewriting the guard chain without a safety net — see
[roadmap Phase 1](../roadmap.md#phase-1--backend-skeleton).
