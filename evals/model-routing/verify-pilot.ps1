[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Fixture, [switch]$AfterRun)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$record = Get-Content (Join-Path $Fixture 'fixture.json') -Raw | ConvertFrom-Json
$repo = [IO.Path]::GetFullPath((Join-Path $Fixture 'candidate'))
$head = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $record.baseRevision) { throw 'HEAD drift.' }
$index = @(& git -C $repo diff --cached --name-only)
if ($LASTEXITCODE -ne 0 -or $index.Count -ne 0) { throw 'Index drift.' }
$actual = @(Get-ChildItem -LiteralPath $repo -File -Recurse -Force | Where-Object {
    -not $_.FullName.StartsWith((Join-Path $repo '.git') + '\', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object { $_.FullName.Substring($repo.Length+1).Replace('\','/') } | Sort-Object)
$expected = @($record.files.path | Sort-Object)
if (Compare-Object $expected $actual) { throw 'File inventory drift (including ignored/untracked files).' }
$allowed = @()
if ($AfterRun -and $record.case -eq 'MR-002') { $allowed = @('scripts/validate.ps1','evals/validate/test-validator-root.ps1') }
foreach ($file in $record.files) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $repo $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $file.sha256 -and $file.path -notin $allowed) { throw "Unexpected byte drift: $($file.path)" }
}
Write-Output "PASS fixture $($record.case) ($($record.baseRevision)); AfterRun=$AfterRun"
