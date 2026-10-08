[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot "validate.ps1") -RepoRoot $repoRoot | Out-Null
& (Join-Path $repoRoot "evals\validate\test-validator-root.ps1") -RepoRoot $repoRoot
& (Join-Path $repoRoot "evals\config\test-config-ownership.ps1") -RepoRoot $repoRoot
& (Join-Path $repoRoot "evals\bootstrap\test-bootstrap.ps1") -RepoRoot $repoRoot

Write-Host ""
Write-Host "PASS  Codex Engineering local test suite passed." -ForegroundColor Green
