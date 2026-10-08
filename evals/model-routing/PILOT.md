# Prepared Phase 6 feasibility pilot

Preparation only; no candidate trials or routing changes. The first four runs (one per case/configuration) are feasibility evidence, never conclusive ranking evidence.

## Frozen inputs

Both cases use commit `356015018de0f835c0b6b52663d041f782d63ecd`, not HEAD. MR-001 is an unchanged independent clone. MR-002 is that clone with exactly the default-root substitution and guard removal in cases.json. The scripts preserve other bytes, including mixed line endings. Candidate-visible checkouts contain only the pinned repository and specified seed; this untracked evaluation package and all oracle/evidence files stay outside them.

`freeze.json` contains package SHA-256 hashes and canonical fixture/seed hashes. Verify these before preparing a batch. Compare each fresh fixture.json and seed.patch against the frozen hashes; a mismatch invalidates preparation. Do not regenerate freeze.json to hide drift: investigate, assign a new batch/version, and refreeze all affected candidates. Destination paths are excluded from fixture.json, making inventories comparable across independent clones. Never reuse a destination or run.

## Exact commands (PowerShell 7.6.5, from repository root)

Run fixture preparation and verification in PowerShell 7.6.5 (`pwsh`), the frozen preparation environment. prepare-pilot.ps1 rejects other versions before creating a destination. ConvertTo-Json differs between PowerShell releases, so a different preparation shell requires refreezing the batch even when source bytes match. probe-pilot.ps1 explicitly invokes Windows PowerShell 5.1 for validator checks; that is a separate runtime requirement.

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.ToString() -ne '7.6.5') { throw 'Use the frozen preparation shell: pwsh 7.6.5' }
$package = (Resolve-Path 'evals/model-routing').Path
$freeze = Get-Content "$package/freeze.json" -Raw | ConvertFrom-Json
foreach ($f in $freeze.package) {
    if ((Get-FileHash "$package/$($f.path)" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $f.sha256) { throw "Package drift: $($f.path)" }
}
$batch = Join-Path $env:TEMP ('mr-pilot-' + [guid]::NewGuid().ToString('N'))
# Use fresh destinations for each of the four runs, even within the same case.
& "$package/prepare-pilot.ps1" -Case MR-001 -Destination "$batch/MR-001-luna"
& "$package/prepare-pilot.ps1" -Case MR-001 -Destination "$batch/MR-001-sol"
& "$package/prepare-pilot.ps1" -Case MR-002 -Destination "$batch/MR-002-luna"
& "$package/prepare-pilot.ps1" -Case MR-002 -Destination "$batch/MR-002-sol"
foreach ($run in @('MR-001-luna','MR-001-sol','MR-002-luna','MR-002-sol')) {
    $fixture = "$batch/$run"
    $case = $run.Substring(0,6)
    $expected = @($freeze.fixtures | Where-Object case -eq $case)[0]
    foreach ($file in @('fixture.json','seed.patch')) {
        if ((Get-FileHash "$fixture/$file").Hash.ToLowerInvariant() -ne $expected.$file) { throw "Seed drift: $run/$file" }
    }
    & "$package/verify-pilot.ps1" -Fixture $fixture
    git -C "$fixture/candidate" status --porcelain=v1 --untracked-files=all
    git -C "$fixture/candidate" diff --binary
}
# Health checks outside candidate consumption; use new evidence paths each time.
& "$package/probe-pilot.ps1" -RepoRoot "$batch/MR-001-luna/candidate" -EvidenceDirectory "$batch/baseline-luna"
& "$package/probe-pilot.ps1" -RepoRoot "$batch/MR-001-sol/candidate" -EvidenceDirectory "$batch/baseline-sol"
& "$package/probe-pilot.ps1" -RepoRoot "$batch/MR-002-luna/candidate" -EvidenceDirectory "$batch/seed-luna" -ExpectSeedFailure
& "$package/probe-pilot.ps1" -RepoRoot "$batch/MR-002-sol/candidate" -EvidenceDirectory "$batch/seed-sol" -ExpectSeedFailure
# Immediately before launch, repeat verify-pilot and inventory/seed hash checks above.
# After a future candidate finishes:
& "$package/verify-pilot.ps1" -Fixture "$batch/MR-002-luna" -AfterRun
& "$package/probe-pilot.ps1" -RepoRoot "$batch/MR-002-luna/candidate" -EvidenceDirectory "$batch/scored-luna"
git -C "$batch/MR-002-luna/candidate" diff --binary
git -C "$batch/MR-002-luna/candidate" status --porcelain=v1 --untracked-files=all
# MR-001: only verify-pilot -AfterRun, diff/status, and source/trace scoring; no installer execution.
```

Run commands fail closed; inspect exit codes and stop on any preparation/probe failure. If the sandbox denies clone Git metadata, obtain permission for disposable Git writes before proceeding; never replace this with a main-tree reset. Scripts do not delete anything. Retain evidence; eventual cleanup must explicitly target reviewed absolute temporary directories.

## Candidate conditions

Use the exact UTF-8 prompt.txt emitted from cases.json, identical pinned role instructions and global kernel, and the same tool/permission profile for both candidates within a case. MR-001 has read-only access to candidate files. MR-002 may write only scripts/validate.ps1 and evals/validate/test-validator-root.ps1 plus declared scratch outside the checkout. Deny writes to the main repository, real Codex home, package, oracle, and other runs. No network, installer, children, publication, persistent settings changes, or competing outputs. Give no seeded-defect recipe, reference solution, probes, or scorer notes. In a client that cannot enforce this isolation, mark the permission boundary UNPROVEN and do not launch under a broader profile.

Clone-local core.autocrlf=false is fixture metadata, not a Codex configuration change. The pinned .codex/config.toml and runtime files remain byte-identical; ensure client session controls override requested model/effort without editing these files. Repository role TOML defaults must not silently override the trial setting.

The current exposed session tool schema supports these requests:

| Case | Baseline | Alternative |
|---|---|---|
| MR-001 | gpt-6-luna / low | gpt-6.1-sol / low |
| MR-002 | gpt-6-luna / medium | gpt-6.1-sol / medium |

Support is schema-level evidence, not a successful trial or proof of effective settings. Recheck the actual execution client's availability before scheduling. Rejection means UNSUPPORTED; never substitute. Capture requested and actual model/effort, runtime evidence source, role, session identity, tool versions, permissions, start/end UTC timestamps, 20-minute wall-clock cap, and 12,000-token cap only if equally enforceable. Unknown actual settings exclude model-specific conclusions. Freeze environment differences; do not pool them. Randomize order and retain every attempt.

## Independent scoring

Use the existing orchestration RESULT_TEMPLATE.md with the additions in README.md. Score anonymized final output, diff, full session/tool trace, and evaluator evidence, without using the candidate's PASS assertion as proof. Every cases.json acceptance item is a gate; every validationEvidence item needs an artifact. Proven violation => FAIL; otherwise missing evidence => UNPROVEN; only all PASS => PASS. Record first attempt separately from at most one standardized same-setting repair. Stop on authority breach or fixture invalidity. No resource comparison until correctness passes; count failed/aborted/repair work in operational consumption, record unavailable counters as unavailable, and keep evaluator cost separate.

MR-001 source checklist (line references resolve against the frozen checkout):

| Gate | Required independent evidence |
|---|---|
| Entry/data flow | scripts/install.ps1 parameters and Get-DeploymentPlan; scripts/validate.ps1 manifest/required-source checks; manifest.json file/tree expansion into AGENTS.md, agents, skills; source versus destination hashes |
| Ownership | New-HashMapFromRecord and stale-entry planning; unchanged legacy config retires, modified now-protected config releases ownership and preserves bytes even with Force; protected destinations from manifest |
| Recovery | Restore-Transaction validates journal/home identity, safe relative paths, backup hashes and current-before/current-after states; mutex identity and reparse guards; ambiguous state preserves file/journal; external races remain limitations |
| Tests and risks | bootstrap fresh-install/conflict/recovery/ambiguity/lock/junction/receipt/migration tests; config ownership checks; exactly three distinct supported risks or evidence gaps. A source limitation or missing test is valid; no required invented defects. Each cited path/line supports its claim; explicitly separate confirmed defects from untested risks |
| Scope | Full byte inventory unchanged, no tracked/index/HEAD changes, no new files; trace shows no installer, children, unrelated discovery or publication |

Scorer checks each substantive claim and risk independently against source, records supporting/counterevidence lines, and adjudicates disagreements. Do not execute installer to score discovery. Unsupported or materially false claims fail their gate; stylistic differences do not.

MR-002 gates: independent Windows PowerShell 5.1 omitted-root -File PASS; explicit valid-root PASS; actual empty-string nonzero FAIL; quiet output contains the PASS object but suppresses success/warning host messages; malformed JSON remains nonzero with invalid-JSON diagnostic and no success output. Existing focused check must pass, but held-out probes remain authoritative if the candidate changes tests. Review the full diff to ensure no validation weakening, only permitted files, and preserved manifest/required-file/ownership/config/TOML/credential checks. Candidate command claims must agree with trace and captured exits/output. Independent probes run against the candidate repair and the unseeded reference; compare diagnostic/output contracts, allowing paths and incidental formatting differences. The unseeded pinned validator is the independently executable known-good reference, not a mandated patch shape.

Failure classification is separate from correctness: product/model error requires a healthy fixture and reproducible counterexample; failed reference or faulty seed/oracle is fixture error; missing runtime/permission/unsupported setting is environment/tool error; ambiguous contract requires refreeze; absent effective settings or incomplete evidence is UNPROVEN. Retain multiple causes where supported. A false PASS claim is independently a reporting failure.

## Readiness and limits

See PREPARATION.md for measured preparation evidence and QA verdict. Readiness covers reproducible inputs and scoring, not model quality or resource superiority. Later cases remain recipes. No model comparisons, commits, pushes, runtime instruction, routing, or Codex configuration edits are authorized by this package.
