# Infrastructure Blockers

Treat tool, sandbox, process-launch, permission, and environment failures separately from product defects unless concrete evidence attributes the failure to product behavior.

## Blocker key

Track a blocked path by:

- operation or capability;
- failure signature;
- execution environment.

Do not create a global ban from a broad label such as "permission denied". The key must be specific enough that unrelated operations remain available.

## Breaker

For one failing execution path:

1. Record the exact operation, environment, and error.
2. Retry the same operation at most once when a transient failure is genuinely plausible.
3. Try at most one safe alternative when an equivalent approved path exists.
4. If the same capability/signature persists, mark that path blocked.
5. Mark dependent acceptance evidence ENV_BLOCKED or UNPROVEN as appropriate.
6. Continue independent checks that do not require the blocked capability.

Do not:

- spawn a replacement worker solely to retry the same blocked path;
- have QA repeat an equivalent capability already blocked by implementation;
- have implementation repeat an equivalent capability already blocked by QA;
- have the Director retry it from an equivalent environment merely for reassurance;
- modify production code merely to work around the sandbox.

A new attempt is justified when:

- the execution environment is materially different;
- the capability or operation has changed;
- new evidence changes the diagnosis;
- the user explicitly requests or performs a local/manual attempt.

## Propagation

Carry only relevant active blocker entries into later handoffs.

A compact entry is enough:

**CAPABILITY**
- command/operation

**SIGNATURE**
- concrete error or failure mode

**ENVIRONMENT**
- runtime/sandbox/tool context

**IMPACT**
- acceptance claim that remains blocked or unproven

This state belongs to the Director session, not to one worker.
