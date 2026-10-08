# Phase 6: model-routing evaluation

This manual framework measures whether the provisional [routing policy](../../skills/engineering-orchestration/references/routing.md) delivers correct, reliable engineering outcomes at reasonable total resource consumption. It defines experiments, not measured results or a routing change. No model trials have been run for this suite.

Use [cases.json](cases.json) for the exact prompts and acceptance contracts. Follow the existing [eval loop](../README.md) and [result template](../orchestration/RESULT_TEMPLATE.md), adding the fields below. The cases extend the discovery, authority, security, and QA themes in ORCH-001/002, ORCH-004/005/006, and ORCH-008. They evaluate the assigned role directly; orchestration behavior can be evaluated separately with the existing suite.

MR-001 and MR-002 now have a [prepared pilot package](PILOT.md), with pinned fixtures, drift checks, independent probes, and [preparation evidence](PREPARATION.md). Later cases remain recipes. This does not record model-comparison results.

## Cases and candidates

| ID | Assignment | Role | Policy baseline | Comparison |
|---|---|---|---|---|
| MR-001 | Bounded installer repository map | repo-explorer | gpt-6-luna / low | gpt-6.1-sol / low |
| MR-002 | Repair validator default-root regression | implementation-engineer | gpt-6-luna / medium | gpt-6.1-sol / medium |
| MR-003 | Independently verify a proposed validator repair | qa-engineer | gpt-6-luna / medium | gpt-6.1-sol / medium |
| MR-004 | Implement read-only managed-file inspection | implementation-engineer | gpt-6.1-sol / medium | gpt-6-luna / medium; Sol / high only after evidence |
| MR-005 | Analyze protected-file migration regression | qa-engineer | gpt-6.1-sol / medium | gpt-6.1-sol / high |
| MR-006 | Review adversarial transaction recovery | security-reliability-engineer | gpt-6.1-sol / medium | gpt-6.1-sol / high |

Candidate IDs are requests, not claims of availability, price, or effective settings. Confirm support in the run's client before scheduling. Lower effort within a model is a resource hypothesis; resource ordering between models must come from visible measurements or documented pricing, not names alone. Keep high-risk review on the policy baseline initially.

## Freeze the experiment before running

1. Select one full Git commit SHA for the batch. Freeze the case JSON version/hash, starting-state fixture artifact/hash, evaluator checklist, tool versions, permissions, and budgets. Never use moving HEAD as the recorded starting state.
2. Prepare each case in a disposable checkout. Apply only its specified fixture transformation, preserving an untouched reference checkout. Record the resulting diff and SHA-256 hashes. Reject a patch that does not match exactly once; adapt and refreeze the whole batch if the pinned revision is incompatible.
3. Validate fixture health before model trials: baseline checks must pass; seeded regressions must reproduce the intended behavior. Validate the oracle against an independently prepared reference solution. A runner's expected answer is not evidence that the fixture works. Freeze any supplemental acceptance probes before comparing candidates.
4. Record fixture readiness. The prepared pilot package covers MR-001/002 only; later cases still specify recipes and require their fixtures and probes to be verified before they are runnable.
5. Keep evaluator notes, seeded-defect recipes, reference solutions, and held-out probes outside candidate-visible files. Give each candidate the same repository, task prompt, applicable instructions, and declared behavior contract. No prior transcript, answer, or competing candidate output.

No preparation may change global AGENTS.md, role definitions, the engineering-orchestration Skill, routing.md, or Codex configuration. Installer invocations must explicitly target a disposable home; never use the real user home. Publication is unauthorized. All mutations described in cases are future disposable-fixture work, not changes to this repository's runtime policy.

## Fair comparison and independent scoring

- Run identical task prompts and byte-equivalent starting states in fresh independent sessions for every repetition. Use the same role instructions, tools, permission profile, shell, network access, and resource/time limits where possible. Record unavoidable differences; do not pool materially different environments.
- Request the candidate through supported session controls without editing persistent configuration. Capture both requested and actual model/effort from client/runtime evidence. If actual settings are unavailable, write `unknown`; keep the result descriptive and exclude it from model-specific routing conclusions. Record substitutions and mid-run escalation as a mixed route, not a pure candidate result.
- Do not delegate in these role trials. Score the candidate's own work. Randomize candidate order within each case/repetition, retain all attempts, and keep evaluator feedback out of first-attempt trials.
- An independent human or separate reviewer with no implementation ownership scores anonymized artifacts against every criterion. The candidate's own PASS claim is insufficient. Record PASS, FAIL, or UNPROVEN plus evidence for each criterion, including prohibited behavior. Disagreements need adjudication; unresolved disagreements remain UNPROVEN.
- First-attempt PASS requires all acceptance criteria and evidence requirements to pass, with no prohibited behavior. Any proven violation makes the run FAIL. Otherwise missing evidence makes it UNPROVEN. Repaired PASS is reported separately and never rewrites first-attempt status.
- For cost-to-completion, allow at most one repair attempt using the same configuration and a standardized criterion-based feedback message. Record its prompt, diff, evidence, settings, and incremental resources. Stop on a destructive/authority breach. Any stronger-model rescue is a separate mixed-route observation. Preserve failed and aborted attempts; do not select the best output.

## Result additions

Copy the orchestration result template for each run and add:

| Field | Record |
|---|---|
| Identity | Batch/run/repetition IDs; case version/hash; full base SHA; fixture hash/diff; reference and oracle versions |
| Conditions | OS/shell/tool versions; tools and permissions; budget; execution order; deviations; Skill activation and any children |
| Configuration | Requested model/effort; actual model/effort; evidence source; substitutions/escalations |
| Correctness | Independent scorer; per-criterion status/evidence; first-attempt and final status; prohibited behavior; adjudication |
| Attempts | Failed approaches and validation commands; repair count and cause; repair feedback; blockers and classification |
| Time | Start/end timestamps; approximate wall-clock elapsed time; repair time; separately recorded blocked/wait time when known |
| Usage | Visible input/output/total tokens and their source/scope; per-attempt and total values only when known; visible charges if available |
| Completion cost | Initial plus repair/rescue resources, validation executions, repository rereads when observable, and aborted work |

Use `unavailable` for invisible token counts, charges, or active time; never zero. Do not estimate tokens from transcript length or infer model usage from the requested setting. Avoid double-counting cumulative counters; record whether cached/reasoning/tool tokens are included or unknown. If counters cannot isolate a run, mark run usage unavailable. Wall-clock time includes service latency and is only a proxy for resource use. Missing usage prevents claims about measured token/cost savings, though correctness and visible elapsed time can still be compared.

## Failure attribution

Keep observed status separate from cause. A failed command alone is not a model-quality failure.

| Cause | Required distinction and handling |
|---|---|
| Model-quality/product failure | Reproducible incorrect output, missed acceptance behavior, or authority violation under a healthy, unambiguous fixture; preserve the counterexample |
| Test/fixture defect | Broken assertion, invalid seed, or faulty oracle demonstrated against the reference; repair/refreeze and rerun all affected configurations |
| Environment/tool failure | Missing runtime, denied permission, service outage, or unsupported setting; retain the aborted run and resources, resolve the environment before comparable reruns |
| Ambiguous requirement | Multiple defensible interpretations absent a frozen contract; clarify/refreeze and rerun all affected candidates |
| Insufficient evidence | Missing effective settings, unchecked claims, unavailable acceptance probe, or incomplete artifact; keep affected claims UNPROVEN |

Allow multiple causes with supporting evidence. A pre-existing environment failure does not excuse an invented PASS; claiming success without evidence is independently a model-quality reporting failure. Report comparable scored runs and exclusions with counts/reasons. Environment-aborted work remains visible in operational cost reporting even when excluded from quality rates.

## Decision rule

Correctness, safety, and contract integrity are gates. Prefer the lowest-resource configuration that consistently satisfies every required correctness and reliability criterion, accounting for failures and repairs through validated completion. Do not trade an authority breach, destructive behavior, or material correctness failure for lower token use.

The pilot can reject a candidate or expose fixture defects, but cannot establish a reliable route. Before a provisional recommendation for a workload, require at least three independent comparable repetitions per candidate/case, all first-attempt PASS, zero material/prohibited failures, and adequate independent evidence. Compare total visible resources across repetitions, including repair/aborted costs; report spread and missing metrics. If correctness ties but resource evidence is unavailable or conflicting, retain the policy baseline and report the uncertainty. Three successes are a screening gate, not a statistical reliability guarantee; broader representative tasks and repetitions are needed before generalizing or changing routing. Evidence from one workload does not authorize downgrading another.

## First recommended pilot

Prepare MR-001 and MR-002 only, at one pinned SHA. Compare their baseline Luna settings with the same-effort Sol alternatives: one fresh run per case/configuration, **four initial runs total**, no children and no high-effort runs. Use a common 20-minute wall-clock limit per attempt and, only if supported equally, a 12,000-token limit. A timed-out attempt remains recorded. Independent scoring adds evaluation work; record it separately from candidate consumption. Stop the pilot if a fixture is invalid or an authority breach occurs. A repair is optional under the one-repair rule, never a new first attempt.

After inspecting all four outcomes, prepare MR-003 if the fixture/scoring procedure is sound. Only then consider repeating the low-cost cases to the screening gate or preparing MR-004/005/006 when a concrete correctness or reliability question justifies their expense. Do not launch a full model-by-effort matrix. Leave runtime routing unchanged until representative evidence supports a separate authorized change.
