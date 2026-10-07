# Provisional Model and Effort Routing

These are v1 cost/quality defaults, not permanent truths. Change them only from eval evidence or a material model/runtime change.

Every delegated assignment should choose role, model, and effort deliberately when practical.

## Baseline

| Work | Model | Effort |
|---|---|---|
| Broad repository mapping / mechanical discovery | GPT-6 Luna | Low |
| Routine Release/Git publication | GPT-6 Luna | Low |
| Small predictable implementation | GPT-6 Luna | Medium |
| Routine independent QA | GPT-6 Luna | Medium |
| Ordinary bounded Security/Reliability review | GPT-6 Luna | Medium |
| Substantial or ambiguous implementation | GPT-6.1 Sol | Medium |
| Complex/cross-cutting QA | GPT-6.1 Sol | Medium |
| Difficult/adversarial Security/Reliability | GPT-6.1 Sol | Medium |
| Difficult escalation after concrete evidence | GPT-6.1 Sol | High or higher supported effort |

Do not escalate merely because a stronger model is available.

Do not downgrade a high-risk or ambiguous assignment merely to reduce first-turn cost.

## Routing principle

Use the least expensive model and effort expected to complete the bounded assignment reliably.

Optimize total cost to validated completion, including:

- first-QA outcome;
- repair cycles;
- repository rereads;
- validation executions;
- environment-aborted work;
- input/output tokens;
- elapsed activity.

If a cheaper route repeatedly causes rework, it is not cheaper in practice.

## A/B policy

Do not embed temporary model experiments into permanent role files.

When comparing candidate routing policies, capture the experiment in `evals/` and keep runtime routing stable until representative evidence supports a change.
