[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$installer = Join-Path $RepoRoot "scripts\install.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-engineering-eval-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $tempRoot ".codex"

try {
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

    # Fresh install must preserve user/machine-owned config and unrelated files.
    $userConfig = Join-Path $codexHome "config.toml"
    $unowned = Join-Path $codexHome "unowned.txt"
    Write-Utf8NoBom -Path $userConfig -Content "# user-owned`nlocal_marker = `"preserve-me`"`n"
    Write-Utf8NoBom -Path $unowned -Content "preserve me"

    & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null

    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "AGENTS.md")) "Fresh install did not deploy AGENTS.md."
    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "agents\repo-explorer.toml")) "Fresh install did not deploy repo-explorer."
    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "skills\engineering-orchestration\SKILL.md")) "Fresh install did not deploy orchestration skill."
    Assert-True ((Get-Content -LiteralPath $userConfig -Raw) -match "preserve-me") "Fresh install modified user-owned config.toml."
    Assert-True (Test-Path -LiteralPath $unowned) "Fresh install removed an unowned file."

    $installRecord = Join-Path $codexHome ".codex-engineering-install.json"
    $transactionRecord = Join-Path $codexHome ".codex-engineering-transaction.json"
    Assert-True (Test-Path -LiteralPath $installRecord -PathType Leaf) "Install record is missing."
    Assert-True (-not (Test-Path -LiteralPath $transactionRecord)) "Transaction journal remained after successful install."

    # A local edit to a managed file must block ordinary reinstall.
    $agentsPath = Join-Path $codexHome "AGENTS.md"
    Add-Content -LiteralPath $agentsPath -Value "`nLOCAL EDIT"
    $blocked = $false
    try {
        & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null
    }
    catch {
        if ($_.Exception.Message -match "Deployment conflict") {
            $blocked = $true
        }
    }
    Assert-True $blocked "Installer did not block overwrite of a locally modified managed file."

    Copy-Item -LiteralPath (Join-Path $RepoRoot "runtime\AGENTS.md") -Destination $agentsPath -Force
    & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null

    # Simulate an interrupted deployment journal and verify startup recovery.
    $backupBase = Join-Path $tempRoot ".codex-engineering-backups"
    $backupSet = "simulated-interruption"
    $backupRoot = Join-Path $backupBase $backupSet
    $backupAgents = Join-Path $backupRoot "files\AGENTS.md"
    $backupRecord = Join-Path $backupRoot "install-record.json"
    New-Item -ItemType Directory -Path (Split-Path -Parent $backupAgents) -Force | Out-Null
    Copy-Item -LiteralPath $agentsPath -Destination $backupAgents -Force
    Copy-Item -LiteralPath $installRecord -Destination $backupRecord -Force

    $interruptedNewFile = Join-Path $codexHome "skills\interrupted.tmp"
    Write-Utf8NoBom -Path $agentsPath -Content "CORRUPTED DURING INTERRUPTED DEPLOYMENT"
    Write-Utf8NoBom -Path $interruptedNewFile -Content "partial new file"

    $journal = [ordered]@{
        schemaVersion = 1
        transactionId = "simulated"
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        codexHome = $codexHome
        backupSet = $backupSet
        operations = @(
            [ordered]@{
                destination = "AGENTS.md"
                existedBefore = $true
                backupRelative = "files/AGENTS.md"
            },
            [ordered]@{
                destination = "skills/interrupted.tmp"
                existedBefore = $false
                backupRelative = $null
            }
        )
        installRecord = [ordered]@{
            existedBefore = $true
            backupRelative = "install-record.json"
        }
    }

    Write-Utf8NoBom -Path $transactionRecord -Content ($journal | ConvertTo-Json -Depth 8)

    & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null

    Assert-True (
        (Get-Sha256 -Path $agentsPath) -eq
        (Get-Sha256 -Path (Join-Path $RepoRoot "runtime\AGENTS.md"))
    ) "Interrupted transaction recovery did not restore AGENTS.md."

    Assert-True (-not (Test-Path -LiteralPath $interruptedNewFile)) "Interrupted transaction recovery did not remove a newly-created partial file."
    Assert-True (-not (Test-Path -LiteralPath $transactionRecord)) "Interrupted transaction journal was not cleared after recovery."

    # Simulate migration from v1 where config.toml was managed.
    $migrationHome = Join-Path $tempRoot "migration\.codex"
    New-Item -ItemType Directory -Path $migrationHome -Force | Out-Null
    $legacyConfig = Join-Path $migrationHome "config.toml"
    Write-Utf8NoBom -Path $legacyConfig -Content "# legacy repo-managed config"
    $legacyHash = Get-Sha256 -Path $legacyConfig

    $legacyRecord = [ordered]@{
        schemaVersion = 1
        managedBy = "codex-engineering"
        installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        repository = $RepoRoot
        gitCommit = $null
        manifestSha256 = "legacy"
        files = @(
            [ordered]@{
                source = "runtime/config.toml"
                destination = "config.toml"
                sha256 = $legacyHash
            }
        )
    }

    Write-Utf8NoBom `
        -Path (Join-Path $migrationHome ".codex-engineering-install.json") `
        -Content ($legacyRecord | ConvertTo-Json -Depth 8)

    & $installer -RepoRoot $RepoRoot -CodexHome $migrationHome -SkipValidation | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $legacyConfig)) "Unmodified v1-managed config.toml was not retired during migration."

    # A locally modified v1-managed config that becomes protected in v2 must be
    # preserved and released from ownership rather than blocking or being deleted.
    $releaseHome = Join-Path $tempRoot "release\.codex"
    New-Item -ItemType Directory -Path $releaseHome -Force | Out-Null
    $releaseConfig = Join-Path $releaseHome "config.toml"

    $originalManagedContent = "# legacy repo-managed config"
    Write-Utf8NoBom -Path $releaseConfig -Content $originalManagedContent
    $originalManagedHash = Get-Sha256 -Path $releaseConfig

    $releaseRecord = [ordered]@{
        schemaVersion = 1
        managedBy = "codex-engineering"
        installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        repository = $RepoRoot
        gitCommit = $null
        manifestSha256 = "legacy"
        files = @(
            [ordered]@{
                source = "runtime/config.toml"
                destination = "config.toml"
                sha256 = $originalManagedHash
            }
        )
    }

    Write-Utf8NoBom `
        -Path (Join-Path $releaseHome ".codex-engineering-install.json") `
        -Content ($releaseRecord | ConvertTo-Json -Depth 8)

    Write-Utf8NoBom `
        -Path $releaseConfig `
        -Content ($originalManagedContent + "`n# machine-local change`nlocal_marker = `"preserve-me`"`n")

    & $installer -RepoRoot $RepoRoot -CodexHome $releaseHome -SkipValidation | Out-Null

    Assert-True (Test-Path -LiteralPath $releaseConfig -PathType Leaf) "Modified protected config.toml was deleted."
    Assert-True ((Get-Content -LiteralPath $releaseConfig -Raw) -match "preserve-me") "Modified protected config.toml was not preserved."

    $releasedRecord = Get-Content -LiteralPath (Join-Path $releaseHome ".codex-engineering-install.json") -Raw | ConvertFrom-Json
    $releasedDestinations = @($releasedRecord.files | ForEach-Object { [string]$_.destination })
    Assert-True (-not ($releasedDestinations -contains "config.toml")) "Released config.toml remained in the install ownership record."

    Write-Host "PASS  Bootstrap regression checks passed." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
