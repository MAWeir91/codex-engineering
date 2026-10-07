[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [switch]$Force,
    [switch]$DryRun,
    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FullPathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Path must be relative: $RelativePath"
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

    if (
        -not $candidate.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Path escapes its root: $RelativePath"
    }

    return $candidate
}

function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

    if (-not $targetFull.StartsWith(
        $baseFull + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Target is not under base path: $TargetPath"
    }

    return $targetFull.Substring($baseFull.Length + 1)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DeploymentPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TargetHome,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    # Native PowerShell arrays avoid generic-list binder issues on Windows PowerShell 5.1.
    $plan = @()

    foreach ($item in $Manifest.managed) {
        $sourcePath = Get-FullPathSafe -Root $Root -RelativePath ([string]$item.source)
        $destinationRoot = Get-FullPathSafe -Root $TargetHome -RelativePath ([string]$item.destination)

        switch ([string]$item.kind) {
            "file" {
                $plan += [pscustomobject]@{
                    Source = $sourcePath
                    SourceRelative = ([string]$item.source).Replace('\', '/')
                    Destination = $destinationRoot
                    DestinationRelative = ([string]$item.destination).Replace('\', '/')
                    SourceHash = Get-Sha256 -Path $sourcePath
                }
            }

            "tree" {
                foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force) {
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Refusing to install a reparse point/symlink: $($file.FullName)"
                    }

                    $childRelative = Get-RelativePathCompat -BasePath $sourcePath -TargetPath $file.FullName
                    $destination = Join-Path $destinationRoot $childRelative
                    $destinationRelative = Join-Path ([string]$item.destination) $childRelative

                    $plan += [pscustomobject]@{
                        Source = $file.FullName
                        SourceRelative = (Join-Path ([string]$item.source) $childRelative).Replace('\', '/')
                        Destination = $destination
                        DestinationRelative = $destinationRelative.Replace('\', '/')
                        SourceHash = Get-Sha256 -Path $file.FullName
                    }
                }
            }

            default {
                throw "Unsupported manifest kind '$($item.kind)'."
            }
        }
    }

    $duplicates = $plan |
        Group-Object { $_.DestinationRelative.ToLowerInvariant() } |
        Where-Object { $_.Count -gt 1 }

    if ($duplicates) {
        throw "Deployment plan contains duplicate destination paths."
    }

    return $plan
}

function Read-InstallRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Existing install record is invalid JSON: $Path"
    }
}

function New-HashMapFromRecord {
    param([object]$Record)

    $map = @{}
    if ($null -eq $Record -or $null -eq $Record.files) {
        return $map
    }

    foreach ($file in $Record.files) {
        $map[[string]$file.destination.ToLowerInvariant()] = [pscustomobject]@{
            Destination = [string]$file.destination
            Source = [string]$file.source
            Sha256 = [string]$file.sha256
        }
    }

    return $map
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$ExistingPath,
        [Parameter(Mandatory = $true)][string]$DestinationRelative,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $ExistingPath -PathType Leaf)) {
        return
    }

    $backupPath = Join-Path $BackupRoot $DestinationRelative
    $backupDirectory = Split-Path -Parent $backupPath
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $ExistingPath -Destination $backupPath -Force
}

function Write-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $directory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $temp = "$Destination.codex-engineering-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $CodexHome = [System.IO.Path]::GetFullPath($CodexHome)

    $manifestPath = Join-Path $RepoRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json not found: $manifestPath"
    }

    if (-not $SkipValidation) {
        Write-Host "Validating source tree..."
        & (Join-Path $PSScriptRoot "validate.ps1") -RepoRoot $RepoRoot | Out-Null
        Write-Host ""
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $installRecordPath = Get-FullPathSafe -Root $CodexHome -RelativePath ([string]$manifest.installRecord)
    $previousRecord = Read-InstallRecord -Path $installRecordPath
    $previousFiles = New-HashMapFromRecord -Record $previousRecord

    # Build the deployment plan before touching ~/.codex.
    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
        # Get-DeploymentPlan needs the home path only for safe destination resolution;
        # it does not require the directory to exist.
    }

    $plan = @(Get-DeploymentPlan -Root $RepoRoot -TargetHome $CodexHome -Manifest $manifest)
    $newDestinations = @{}
    foreach ($item in $plan) {
        $newDestinations[$item.DestinationRelative.ToLowerInvariant()] = $true
    }

    # Detect conflicts before modifying anything.
    $conflicts = @()

    foreach ($item in $plan) {
        if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf)) {
            continue
        }

        $currentHash = Get-Sha256 -Path $item.Destination
        $key = $item.DestinationRelative.ToLowerInvariant()

        if ($previousFiles.ContainsKey($key)) {
            $expectedHash = $previousFiles[$key].Sha256
            if ($currentHash -ne $expectedHash -and $currentHash -ne $item.SourceHash -and -not $Force) {
                $conflicts += "Locally modified managed file: $($item.DestinationRelative)"
            }
        }
        elseif ($currentHash -ne $item.SourceHash -and -not $Force) {
            $conflicts += "Existing unowned file would be overwritten: $($item.DestinationRelative)"
        }
    }

    # Detect stale previously-managed files that would be removed.
    $stale = @()
    foreach ($entry in $previousFiles.GetEnumerator()) {
        if ($newDestinations.ContainsKey($entry.Key)) {
            continue
        }

        $relative = $entry.Value.Destination
        $path = Get-FullPathSafe -Root $CodexHome -RelativePath $relative

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $currentHash = Get-Sha256 -Path $path
            if ($currentHash -ne $entry.Value.Sha256 -and -not $Force) {
                $conflicts += "Locally modified stale managed file: $relative"
            }
        }

        $stale += [pscustomobject]@{
            DestinationRelative = $relative
            Destination = $path
        }
    }

    if ($conflicts.Count -gt 0) {
        Write-Host "Installation stopped because it would overwrite local changes:" -ForegroundColor Red
        foreach ($conflict in $conflicts) {
            Write-Host " - $conflict" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Review the files or rerun with -Force only if overwriting them is intentional."
        throw "Deployment conflict."
    }

    $toWrite = @(
        $plan | Where-Object {
            -not (Test-Path -LiteralPath $_.Destination -PathType Leaf) -or
            (Get-Sha256 -Path $_.Destination) -ne $_.SourceHash
        }
    )

    $toRemove = @(
        $stale | Where-Object { Test-Path -LiteralPath $_.Destination -PathType Leaf }
    )

    Write-Host "Codex Engineering deployment plan"
    Write-Host "  Repo:       $RepoRoot"
    Write-Host "  Codex home: $CodexHome"
    Write-Host "  Managed:    $($plan.Count) file(s)"
    Write-Host "  Write:      $($toWrite.Count) file(s)"
    Write-Host "  Remove:     $($toRemove.Count) stale managed file(s)"
    Write-Host "  Preserve:   all unowned files/directories"
    Write-Host ""

    if ($DryRun) {
        foreach ($item in $toWrite) {
            Write-Host "WRITE  $($item.DestinationRelative)"
        }
        foreach ($item in $toRemove) {
            Write-Host "REMOVE $($item.DestinationRelative)"
        }

        Write-Host ""
        Write-Host "DRY RUN: no files were changed." -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $HOME ".codex-engineering-backups\$stamp"
    # Avoid relying on .Count from a pipeline result: Windows PowerShell 5.1
    # can unwrap a single pipeline object under StrictMode.
    $existingManagedFile = $toWrite |
        Where-Object { Test-Path -LiteralPath $_.Destination -PathType Leaf } |
        Select-Object -First 1

    $backupNeeded = ($null -ne $existingManagedFile) -or ($toRemove.Count -gt 0)

    if ($backupNeeded) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    # Back up and remove stale managed files.
    foreach ($item in $toRemove) {
        Backup-ExistingFile `
            -ExistingPath $item.Destination `
            -DestinationRelative $item.DestinationRelative `
            -BackupRoot $backupRoot

        Remove-Item -LiteralPath $item.Destination -Force
        Write-Host "REMOVED $($item.DestinationRelative)"
    }

    # Back up and write current managed files.
    foreach ($item in $toWrite) {
        if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
            Backup-ExistingFile `
                -ExistingPath $item.Destination `
                -DestinationRelative $item.DestinationRelative `
                -BackupRoot $backupRoot
        }

        Write-FileAtomically -Source $item.Source -Destination $item.Destination
        Write-Host "WROTE   $($item.DestinationRelative)"
    }

    $gitCommit = $null
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        try {
            $candidate = (& $git.Source -C $RepoRoot rev-parse HEAD 2>$null).Trim()
            if ($LASTEXITCODE -eq 0 -and $candidate) {
                $gitCommit = $candidate
            }
        }
        catch {
            $gitCommit = $null
        }
    }

    $recordFiles = @()
    foreach ($item in ($plan | Sort-Object DestinationRelative)) {
        $installedHash = Get-Sha256 -Path $item.Destination
        $recordFiles += [ordered]@{
            source = $item.SourceRelative
            destination = $item.DestinationRelative
            sha256 = $installedHash
        }
    }

    $record = [ordered]@{
        schemaVersion = 1
        managedBy = "codex-engineering"
        installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        repository = $RepoRoot
        gitCommit = $gitCommit
        manifestSha256 = Get-Sha256 -Path $manifestPath
        files = $recordFiles
    }

    $recordJson = $record | ConvertTo-Json -Depth 8
    $recordTemp = "$installRecordPath.codex-engineering-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $recordTemp -Value $recordJson -Encoding UTF8
        Move-Item -LiteralPath $recordTemp -Destination $installRecordPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $recordTemp) {
            Remove-Item -LiteralPath $recordTemp -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "PASS  Codex Engineering installed successfully." -ForegroundColor Green
    Write-Host "      Install record: $installRecordPath"
    if ($backupNeeded) {
        Write-Host "      Backup:         $backupRoot"
    }
    Write-Host ""
    Write-Host "Unowned Codex state (for example auth/runtime state) is preserved on future installs."
}
catch {
    Write-Host ""
    Write-Host "FAIL  $($_.Exception.Message)" -ForegroundColor Red
    throw
}
