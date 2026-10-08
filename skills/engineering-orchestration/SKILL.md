---
name: engineering-orchestration
description: Coordinate substantial software-development work across Codex subagents when repository discovery, implementation, independent QA, security/reliability review, or authorized publication benefits from bounded delegation. Do not use for trivial single-owner work that is cheaper and clearer to complete directly.
metadata:
  short-description: Coordinate substantial engineering work
---

# Engineering Orchestration

Use this skill only from the root Engineering Director context.

The goal is not to maximize delegation. The goal is to reach a correct, independently evidenced result with the least useful coordination and context overhead.

## Decide whether to delegate

Complete work directly when the change is small, the relevant surface is already known, independent validation adds little value, and delegation would create more coordination than useful separation.

Use bounded specialists when one or more of these are true:

- broad repository discovery is needed before ownership can be assigned;
- implementation is substantial enough that an isolated worker keeps the Director context cleaner;
- independent QA materially improves confidence;
- a security/reliability boundary warrants adversarial review;
- publication is explicitly authorized and should be isolated from implementation.

Do not spawn every role merely because the role exists.

## Route by ownership

- **Repository Explorer (`repo-explorer`)** — broad read-only discovery when the relevant subsystem is not already sufficiently mapped.
- **Implementation Engineer** — one coherent implementation owner by default.
- **QA Engineer** — independent acceptance/regression evidence when the change or acceptance contract warrants it.
- **Security / Reliability Engineer** — independent adversarial review only for material security, authority, durable-state, destructive-operation, concurrency, recovery, or high-impact reliability risk.
- **Release Engineer** — Git/publication actions only after acceptance and explicit publication authority.

For provisional model/effort routing, read [references/routing.md](references/routing.md) before spawning workers.

## Operating pattern

1. Orient only enough to understand the request, identify obvious scope, and decide whether delegation is useful.
2. If broad discovery is needed, assign `repo-explorer` and reuse its working map. Do not independently remap the same subsystem afterward.
3. Assign one implementation owner per coherent change. Parallel implementation is appropriate only for genuinely independent ownership boundaries with stable interfaces.
4. When independent QA is warranted, hand it the acceptance criteria, working map, changed areas, implementation evidence, relevant contracts, and known blockers.
5. Add Security / Reliability only when the risk profile justifies it. It may run alongside QA after the implementation surface is stable when their work is independent.
6. Integrate worker evidence. Do not rerun routine worker validation merely for reassurance.
7. Spawn Release only when Codex is authorized to publish accepted work.

Use [references/handoffs.md](references/handoffs.md) for assignment and follow-up packets.

Use [references/validation.md](references/validation.md) when implementation/QA validation boundaries, repeated checks, or the validation safety fuse matter.

Use [references/infrastructure-blockers.md](references/infrastructure-blockers.md) when a tool, sandbox, process-launch, permission, or environment failure blocks evidence.

## Coordination

After starting all currently independent workers, wait for a meaningful event rather than polling them for progress.

Do not message active workers merely to ask for status, tell them to continue, or repeat an unchanged assignment.

Send follow-up only when new evidence changes scope, resolves a blocker, corrects a misunderstanding, supplies a required decision/interface, or assigns a genuinely new task.

Do not duplicate delegated discovery, implementation, QA, or release work in the Director thread. Targeted Director inspection is appropriate only when needed to make an integration decision that worker evidence cannot establish.

## Completion

Accept work only from evidence actually obtained.

If required evidence is blocked, preserve the distinction between defective code and unproven behavior.

If QA establishes a product defect, route the repair to an implementation owner and use independent QA to verify the repaired acceptance boundary when practical.

Keep final reporting concise: outcome, material changes, validation evidence, unresolved risks or blockers, and publication status.
