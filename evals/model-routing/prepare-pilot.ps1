[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('MR-001','MR-002')][string]$Case,
    [Parameter(Mandatory=$true)][string]$Destination,
    [string]$SourceRepo = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.ToString() -ne '7.6.5') {
    throw 'Frozen pilot preparation requires PowerShell 7.6.5; validator probes use Windows PowerShell 5.1.'
}
if (-not $PSBoundParameters.ContainsKey('SourceRepo')) {
    $SourceRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$base = '356015018de0f835c0b6b52663d041f782d63ecd'
$Destination = [IO.Path]::GetFullPath($Destination)
$SourceRepo = [IO.Path]::GetFullPath($SourceRepo)
if (Test-Path -LiteralPath $Destination) { throw 'Destination must not exist; never reuse a run.' }
if ($Destination.StartsWith($SourceRepo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture must be outside the source working tree.'
}
& git -C $SourceRepo cat-file -e "$base^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Pinned commit unavailable.' }
New-Item -ItemType Directory -Path $Destination | Out-Null
$repo = Join-Path $Destination 'candidate'
& git -c core.autocrlf=false clone --quiet --no-local --no-checkout $SourceRepo $repo
if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
& git -C $repo -c core.autocrlf=false checkout --quiet --detach $base
if ($LASTEXITCODE -ne 0) { throw 'Checkout failed.' }
# Freeze line-ending behavior in this disposable clone only.
& git -C $repo config core.autocrlf false
if ($LASTEXITCODE -ne 0) { throw 'Clone-local setting failed.' }
if ($Case -eq 'MR-002') {
    $path = Join-Path $repo 'scripts/validate.ps1'
    $text = [IO.File]::ReadAllText($path)
    $default = '[string]$RepoRoot = ""'
    $guardPattern = [regex]::Escape('if (-not $PSBoundParameters.ContainsKey("RepoRoot")) {') + '\r?\n' +
        [regex]::Escape('    $RepoRoot = Split-Path -Parent $PSScriptRoot') + '\r?\n' + '\}'
    if ([regex]::Matches($text, [regex]::Escape($default)).Count -ne 1 -or
        [regex]::Matches($text, $guardPattern).Count -ne 1) { throw 'Incompatible seed; refreeze batch.' }
    $text = [regex]::Replace($text.Replace($default, '[string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)'), $guardPattern, '')
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
$contract = Get-Content (Join-Path $PSScriptRoot 'cases.json') -Raw | ConvertFrom-Json
$entry = @($contract.cases | Where-Object id -eq $Case)[0]
[IO.File]::WriteAllText((Join-Path $Destination 'prompt.txt'), $entry.prompt, (New-Object Text.UTF8Encoding($false)))
$files = @(Get-ChildItem -LiteralPath $repo -File -Recurse -Force | Where-Object {
    -not $_.FullName.StartsWith((Join-Path $repo '.git') + '\', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    [ordered]@{ path=$_.FullName.Substring($repo.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
} | Sort-Object { $_.path })
$record = [ordered]@{ schemaVersion=1; case=$Case; baseRevision=$base; files=$files }
[IO.File]::WriteAllText((Join-Path $Destination 'fixture.json'), ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$patchPath = Join-Path $Destination 'seed.patch'
& git -C $repo diff --binary "--output=$patchPath"
if ($LASTEXITCODE -ne 0) { throw 'Diff capture failed.' }
& (Join-Path $PSScriptRoot 'verify-pilot.ps1') -Fixture $Destination
