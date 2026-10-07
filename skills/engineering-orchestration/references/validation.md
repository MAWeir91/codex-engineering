# Validation Ownership and Safety Fuse

Validation exists to establish specific claims with the least sufficient evidence.

## Implementation boundary

Implementation owns changed-surface readiness:

- focused checks for the behavior it changed;
- necessary local compile/type/build/static health for that surface;
- narrow defect checks while repairing a concrete failure;
- final diff inspection;
- concise evidence for QA.

Implementation does not normally own broad independent acceptance or repository-wide regression sweeps.

Prefer one terminating command that establishes several related claims over many tiny commands that repeatedly re-enter the same context.

## Provisional validation safety fuse

For v1, use **six validation executions per bounded implementation assignment as a safety fuse, not a target**.

Counting:

- each test, build, type-check, lint, static-analysis, or equivalent validation command counts as one execution;
- one command running many checks still counts as one execution;
- repository reads, searches, edits, and final diff inspection do not count;
- environment-aborted validation still counts because it consumes execution/context budget.

After execution six, stop implementation-side validation and return current evidence unless the Director explicitly authorizes a bounded extension.

An extension must name:

- the unresolved implementation claim or concrete failure;
- why the remaining validation belongs with implementation instead of QA;
- a maximum of normally one or two additional executions.

This number is experimental. Evals may change or remove it.

## QA boundary

QA independently owns:

- requested acceptance behavior;
- material regression boundaries;
- required build/type/static gates;
- defect-focused checks justified by evidence.

QA has no fixed execution count. It stops when required acceptance claims and material regression boundaries are adequately evidenced.

More QA validation should correspond to a concrete unresolved claim, defect hypothesis, newly changed implementation, or uncovered acceptance boundary.

A failing command is not automatically CODE_FAIL. Establish the expectation, actual deviation, substantiation, and reasonable exclusion of environment/test-harness causes.

## Director boundary

After implementation and QA are delegated, routine Director validation defaults to zero.

The Director may perform one targeted integration check when all are true:

- the claim is necessary for acceptance;
- worker evidence cannot establish it;
- the check answers a specific integration question;
- it is not a duplicate of adequate worker evidence.

If broader validation is needed, route it to QA.

## Repairs

When QA establishes CODE_FAIL, route the repair to an implementation owner.

After the repair, QA should verify the repaired acceptance boundary and relevant nearby regression cases. Reuse prior evidence where still valid rather than restarting validation from zero.
