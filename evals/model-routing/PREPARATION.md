# Pilot preparation evidence — 2026-10-08

**Pilot readiness verdict: UNPROVEN for candidate launch.** Fixture and scoring preparation is READY; independent QA is PASS. The execution client's effective settings and restricted permission profile remain launch checks. No model trials were run.

Both cases are pinned to `356015018de0f835c0b6b52663d041f782d63ecd`. Preparation commands and scoring are in [PILOT.md](PILOT.md); byte-level package/fixture identity is in [freeze.json](freeze.json). The original framework was untracked at preparation start; it is deliberately not copied into candidate checkouts.

Director evidence:

- Independent full clones created outside the main working tree with no shared Git metadata (`clone --no-local`); no existing destinations overwritten, no cleanup/reset/commit/push.
- Both inventories and seed diffs recorded; preflight verifier passed for both before and after probes. MR-001 seed patch is empty. MR-002 changes only the parameter default and omitted-argument assignment block in scripts/validate.ps1.
- Windows PowerShell `5.1.26100.9444`; preparation shell PowerShell `7.6.5`; Git `2.54.0.windows.1`. Baseline quiet object: Status PASS, ManagedFileCount 12, WarningCount 0 (strict TOML parsing available).
- Reference: omitted-root, valid-root and focused checks exit 0; actual empty-string and malformed-manifest controls exit nonzero; quiet output is exactly the existing three-field PASS object.
- Seed: omitted-root and focused checks exit 1 with Split-Path empty-string diagnostic; explicit valid root exits 0; independent actual-empty/quiet/malformed controls retain reference behavior.
- Final command/exit/output records: [baseline](preparation-evidence/baseline/omitted.json) and [seed](preparation-evidence/seed/omitted.json), with all six probes under each directory. Seed diff: [seed.patch](preparation-evidence/seed.patch). Temporary checkout location is recorded in preparation-location.txt; retained logs remain usable after eventual scratch removal.
- `git diff --exit-code` passed for main tracked content; final status contains only the existing/new untracked evals/model-routing package. Runtime instructions, routing, and Codex configuration were not changed.

Preparation failures were investigated rather than attributed to candidate quality: sandbox denied disposable Git metadata; approved temporary access resolved it. Native --output argument construction, CRLF seed matching, focused diagnostic expectation, and mixed-slash verifier paths were harness defects corrected before freezing. Earlier partial directories/logs remain retained; only final successful evidence is authoritative. Preparation consumption is evaluator overhead, not model-comparison consumption.

Remaining launch conditions: preparation requires PowerShell 7.6.5, separately from the Windows PowerShell 5.1 validator runtime. Independent QA confirmed that PowerShell 5.1 preparation produces identical seed diffs but different serialized inventory hashes; the final script now rejects other preparation versions before mutation. Availability and effective model/effort must be checked in the chosen execution client, and identical restricted permissions must be enforceable for both candidates. Tool schemas advertise all four requested pairs; no candidate sessions have been launched to establish effective settings. Unsupported requests must be recorded UNSUPPORTED without substitution. This desktop sandbox required approved temporary-clone access; a comparable execution profile needs that access established before launch. Invisible token counters/budget enforcement may remain unavailable and cannot support savings claims.

No model-ranking evidence exists. Four initial runs are only a feasibility pilot. Later fixtures remain unprepared.

Independent [QA verdict](QA.md): PASS, no remaining fixture/scoring defects. QA prepared four new clones under PowerShell 7.6.5, matched every frozen inventory/seed hash, verified them, and independently validated all six controls on reference/seed fixtures. It confirmed the final preparation script rejects PowerShell 5.1 before creating a destination. QA requested gpt-6-luna / medium; actual QA configuration was not exposed and is recorded unknown. This QA work was preparation review, not a candidate trial.

Final freeze.json SHA-256: 7f27b69979d7d0c6798959da710fdc1c828dd312cf233b3ee7a7bea34cb0850c. Retain this identity in the future batch record; do not regenerate the manifest to bypass drift checks.
