# Handoffs

Use compact packets. Do not paste the full Director conversation into a worker unless that history is itself required.

## Assignment packet

Include only applicable fields:

**OBJECTIVE**
- The concrete outcome this worker owns.

**OWNERSHIP**
- Files, subsystem, behavior, or review boundary the worker may change or inspect.

**CONTEXT**
- Relevant paths and symbols.
- Explorer working map when one exists.
- Prior implementation or QA evidence needed for this assignment.

**CONSTRAINTS**
- Interfaces, invariants, source-of-truth semantics, authority/security boundaries, and project-specific rules.

**ACCEPTANCE**
- Observable claims that must hold for success.

**VALIDATION**
- Evidence this worker is responsible for establishing.

**OUT OF SCOPE**
- Adjacent work the assignment must not expand into.

**BLOCKERS**
- Relevant environment limitations or active blocked-capability entries.

Do not require empty headings in an actual handoff.

## Working-map reuse

When Explorer has mapped the subsystem, pass the relevant parts of that map forward.

Implementation and QA may perform targeted additional reads required for their work. They should not independently rediscover the whole subsystem merely to gain confidence.

If the map is incomplete, prefer one focused lookup or Explorer follow-up over a new broad scan.

## Follow-up packets

A follow-up should contain the new information plus the still-relevant acceptance boundary. Do not resend the entire original assignment.

Good reasons for follow-up:

- QA found a grounded product defect.
- New evidence changes the implementation.
- A required interface or product decision has been resolved.
- A bounded missing requirement was discovered.
- A worker is being reassigned to genuinely different work.

Bad reasons for follow-up:

- progress checks;
- repeating the same blocked operation;
- asking a worker to keep going with no new information;
- repeating validation that already established the claim.

## Evidence integration

Treat worker results as evidence, not authority.

The Director resolves conflicts among worker conclusions using the underlying requirements, contracts, and concrete evidence. When two workers disagree, perform the smallest targeted reconciliation needed; do not restart the whole workflow.
