[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-ValidatorInvocation {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $output = (& $script:WindowsPowerShell @Arguments 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output -notmatch "PASS  Codex engineering source tree is valid\.") {
        throw "$Description failed with exit code $exitCode.`n$output"
    }
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$script:WindowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$validator = Join-Path $RepoRoot "scripts\validate.ps1"

Assert-ValidatorInvocation `
    -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $validator) `
    -Description "Validator -File invocation with default repository root"

Assert-ValidatorInvocation `
    -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $validator, "-RepoRoot", $RepoRoot) `
    -Description "Validator -File invocation with explicit repository root"

$quotedValidator = "'" + $validator.Replace("'", "''") + "'"
$invalidCommand = "& $quotedValidator -RepoRoot [string]::Empty"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$invalidOutput = (& $script:WindowsPowerShell -NoProfile -Command $invalidCommand 2>&1 | Out-String)
$invalidExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidExitCode -eq 0 -or $invalidOutput -notmatch "FAIL") {
    throw "Validator accepted an explicitly empty repository root.`n$invalidOutput"
}

Write-Host "PASS  Validator -File root resolution regression checks passed." -ForegroundColor Green
