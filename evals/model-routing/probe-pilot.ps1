[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepoRoot,
      [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
      [switch]$ExpectSeedFailure)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Evidence directory must be new.' }
New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
$ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$version = & $ps -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($version -notmatch '^5\.1\.') { throw "Requires Windows PowerShell 5.1, found $version" }
$validator = Join-Path $RepoRoot 'scripts/validate.ps1'
$q = "'" + $validator.Replace("'", "''") + "'"
$r = "'" + $RepoRoot.Replace("'", "''") + "'"
function Invoke-Probe($name, [string[]]$arguments, [bool]$success, [string]$match, [string]$absent='') {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = (& $ps @arguments 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    [ordered]@{ name=$name; executable=$ps; arguments=$arguments; exitCode=$code; output=$output; version=$version } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$name.json") -Encoding UTF8
    if (($code -eq 0) -ne $success -or $output -notmatch $match -or ($absent -and $output -match $absent)) {
        throw "Probe mismatch: $name (exit $code); see evidence."
    }
    if ($name -eq 'quiet') {
        $result = $output | ConvertFrom-Json
        if ($result.Status -ne 'PASS' -or $result.ManagedFileCount -le 0 -or $result.WarningCount -lt 0 -or
            ((@($result.PSObject.Properties.Name | Sort-Object) -join ',') -ne 'ManagedFileCount,Status,WarningCount')) {
            throw 'Quiet object contract mismatch.'
        }
    }
}
Invoke-Probe 'omitted' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$validator) (-not $ExpectSeedFailure) $(if ($ExpectSeedFailure) {'Split-Path|Path'} else {'PASS  Codex engineering'})
Invoke-Probe 'valid' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$validator,'-RepoRoot',$RepoRoot) $true 'PASS  Codex engineering'
# Actual empty string passed through -Command; -File native quoting is not a reliable empty-string oracle.
Invoke-Probe 'empty' @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"& $q -RepoRoot ([string]::Empty)") $false 'FAIL'
Invoke-Probe 'quiet' @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"& $q -RepoRoot $r -Quiet | ConvertTo-Json -Compress") $true '"Status":"PASS"' 'PASS  Codex engineering|WARN  |Managed files:'
Invoke-Probe 'focused' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot 'evals/validate/test-validator-root.ps1'),'-RepoRoot',$RepoRoot) (-not $ExpectSeedFailure) $(if ($ExpectSeedFailure) {'Split-Path.*empty string'} else {'PASS  Validator -File'})
# Malformed manifest control in a separate full copy, never in the evaluated checkout.
$scratch = Join-Path $EvidenceDirectory 'malformed'
New-Item -ItemType Directory -Path $scratch | Out-Null
Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object Name -ne '.git' | Copy-Item -Destination $scratch -Recurse -Force
[IO.File]::WriteAllText((Join-Path $scratch 'manifest.json'), '{broken', (New-Object Text.UTF8Encoding($false)))
Invoke-Probe 'malformed' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $scratch 'scripts/validate.ps1'),'-RepoRoot',$scratch,'-Quiet') $false 'manifest.json is invalid JSON' 'PASS  Codex engineering'
Write-Output 'PASS independent probes'
