# Codex Engineering Evals

Evals are the evidence layer for runtime changes.

Use this loop:

1. reproduce a behavior or failure with a stable prompt;
2. record the expected routing, authority, mutation, and evidence behavior;
3. run in a fresh Codex session against a known Git commit;
4. capture the skill activation, child agents, mutations, validation evidence, and final result;
5. score the case;
6. change runtime instructions only when representative eval evidence supports the change.

Do not convert every observed failure directly into a new global rule.

## Result record

A manual result should record:

- date and Codex client surface;
- repository Git commit;
- effective model/effort when visible;
- prompt/case ID;
- Skill activation;
- child agents spawned;
- files modified;
- validation commands/evidence;
- PASS/FAIL/UNPROVEN for each expected behavior;
- unexpected behavior or cost.

`orchestration/cases.json` is the initial behavioral suite.
Use the [manual orchestration result template](orchestration/RESULT_TEMPLATE.md) to record each run.
`bootstrap/` and `config/` contain deterministic local regression checks.

## Release authority

Behavioral eval work must not be committed or pushed unless publication is explicitly authorized.
