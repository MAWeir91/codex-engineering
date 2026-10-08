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

# Path checks cannot make PowerShell filesystem operations atomic against an
# unrelated process replacing an ancestor between inspection and mutation.
$script:installerOwnsLock = $false
$script:journalHash = $null
$installerMutex = $null

function Get-InstallerLockKey {
    param([string]$Path)
    # Resolve the longest existing directory through an OS handle, including
    # DOS short names and alternate drive mappings. Append missing components so
    # creation of CodexHome does not change the lock identity mid-transaction.
    if (-not ('CodexEngineering.NativePaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace CodexEngineering {
    public static class NativePaths {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,
            StringBuilder path, uint size, uint flags);
        public static string CanonicalDirectory(string path) {
            using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                var result = new StringBuilder(32768);
                // Volume GUID identity does not depend on the drive mapping.
                uint length = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 1);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= result.Capacity) throw new InvalidOperationException("Canonical path is too long.");
                return result.ToString();
            }
        }
    }
}
'@
    }
    $existing = $Path.TrimEnd('\', '/')
    $suffix = @()
    while (-not (Test-Path -LiteralPath $existing -PathType Container)) {
        $suffix = @(Split-Path -Leaf $existing) + $suffix
        $parent = Split-Path -Parent $existing
        if (-not $parent -or $parent -eq $existing) { throw "Cannot establish installer lock identity for: $Path" }
        $existing = $parent
    }
    $canonical = [CodexEngineering.NativePaths]::CanonicalDirectory($existing).TrimEnd('\', '/')
    foreach ($part in $suffix) { $canonical += '\' + $part }
    return $canonical.ToUpperInvariant()
}

function Assert-NoReparsePath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        $entry = $null
        try { $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { }
        if ($null -ne $entry -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsupported reparse point in destination/backup path: $current"
        }
        if ($null -ne $entry -and $current -ne $full -and -not $entry.PSIsContainer) {
            throw "Destination ancestor is not a directory: $current"
        }
    }
}

function Get-FileState {
    param([string]$Path)
    Assert-NoReparsePath -Path $Path
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Expected file or absent path: $Path" }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return Get-Sha256 -Path $Path }
    return $null
}

function Assert-JournalIdentity {
    param([string]$Path)
    if (-not $script:installerOwnsLock) { throw "Installer does not own its lock." }
    if ((Get-FileState -Path $Path) -ne $script:journalHash) {
        throw "Transaction journal identity changed; preserving journal: $Path"
    }
}

function Remove-OwnedJournal {
    param([string]$Path)
    Assert-JournalIdentity -Path $Path
    if ($null -eq $script:journalHash) { throw "Expected transaction journal is missing: $Path" }
    Remove-Item -LiteralPath $Path -Force
    $script:journalHash = $null
}

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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    Assert-NoReparsePath -Path $Path
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonAtomically {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$Depth = 10
    )

    Assert-NoReparsePath -Path $Destination
    $directory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $temp = "$Destination.codex-engineering-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        Write-Utf8NoBom -Path $temp -Content $json
        Assert-NoReparsePath -Path $Destination
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-NoReparsePath -Path $Destination
    $directory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $temp = "$Destination.codex-engineering-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Assert-NoReparsePath -Path $Destination
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON file '$Path': $($_.Exception.Message)"
    }
}

function Test-ProtectedDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][object[]]$Protected
    )

    $normalized = $Destination.Replace('/', '\').TrimStart('\')
    foreach ($entry in $Protected) {
        $p = ([string]$entry).Replace('/', '\').Trim('\')
        if (
            $normalized.Equals($p, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return $true
        }
    }

    return $false
}

function Get-DeploymentPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TargetHome,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $plan = @()

    foreach ($item in $Manifest.managed) {
        $sourceRelative = [string]$item.source
        $destinationRelative = [string]$item.destination
        $kind = [string]$item.kind

        if (Test-ProtectedDestination -Destination $destinationRelative -Protected $Manifest.protectedDestinations) {
            throw "Manifest attempts to manage protected destination '$destinationRelative'."
        }

        $sourcePath = Get-FullPathSafe -Root $Root -RelativePath $sourceRelative
        $destinationRoot = Get-FullPathSafe -Root $TargetHome -RelativePath $destinationRelative

        switch ($kind) {
            "file" {
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Managed source file does not exist: $sourceRelative"
                }

                $plan += [pscustomobject]@{
                    Source = $sourcePath
                    SourceRelative = $sourceRelative.Replace('\', '/')
                    Destination = $destinationRoot
                    DestinationRelative = $destinationRelative.Replace('\', '/')
                    SourceHash = Get-Sha256 -Path $sourcePath
                }
            }

            "tree" {
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                    throw "Managed source directory does not exist: $sourceRelative"
                }

                foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force) {
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Refusing to install a reparse point/symlink: $($file.FullName)"
                    }

                    $childRelative = Get-RelativePathCompat -BasePath $sourcePath -TargetPath $file.FullName
                    $destination = Join-Path $destinationRoot $childRelative
                    $destinationChildRelative = Join-Path $destinationRelative $childRelative

                    if (Test-ProtectedDestination -Destination $destinationChildRelative -Protected $Manifest.protectedDestinations) {
                        throw "Managed tree reaches protected destination '$destinationChildRelative'."
                    }

                    $plan += [pscustomobject]@{
                        Source = $file.FullName
                        SourceRelative = (Join-Path $sourceRelative $childRelative).Replace('\', '/')
                        Destination = $destination
                        DestinationRelative = $destinationChildRelative.Replace('\', '/')
                        SourceHash = Get-Sha256 -Path $file.FullName
                    }
                }
            }

            default {
                throw "Unsupported manifest kind '$kind'."
            }
        }
    }

    $duplicates = @(
        $plan |
            Group-Object { $_.DestinationRelative.ToLowerInvariant() } |
            Where-Object { $_.Count -gt 1 }
    )

    if ($duplicates.Count -gt 0) {
        throw "Deployment plan contains duplicate destination paths."
    }

    return $plan
}

function New-HashMapFromRecord {
    param([object]$Record)

    $map = @{}
    if ($null -eq $Record -or $null -eq $Record.files) {
        return $map
    }

    foreach ($file in $Record.files) {
        $key = ([string]$file.destination).ToLowerInvariant()
        $map[$key] = [pscustomobject]@{
            Destination = [string]$file.destination
            Source = [string]$file.source
            Sha256 = [string]$file.sha256
        }
    }

    return $map
}

function Get-BackupBase {
    param([Parameter(Mandatory = $true)][string]$TargetHome)

    $parent = Split-Path -Parent $TargetHome
    return Join-Path $parent ".codex-engineering-backups"
}

function Copy-ToTransactionBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ExistingPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupRelative
    )

    $backupPath = Get-FullPathSafe -Root $BackupRoot -RelativePath $BackupRelative
    Assert-NoReparsePath -Path $ExistingPath
    Assert-NoReparsePath -Path $backupPath
    $directory = Split-Path -Parent $backupPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Copy-Item -LiteralPath $ExistingPath -Destination $backupPath -Force
}

function Restore-Transaction {
    param(
        [Parameter(Mandatory = $true)][string]$JournalPath,
        [Parameter(Mandatory = $true)][string]$TargetHome,
        [Parameter(Mandatory = $true)][string]$InstallRecordPath
    )

    Assert-JournalIdentity -Path $JournalPath
    $journal = Read-JsonFile -Path $JournalPath
    if ($null -eq $journal) {
        if ($null -ne $script:journalHash) { throw "Expected transaction journal is missing: $JournalPath" }
        return
    }

    Assert-JournalIdentity -Path $JournalPath
    if ([int]$journal.schemaVersion -ne 2) {
        throw "Unsupported transaction journal schema '$($journal.schemaVersion)'; preserve it for manual recovery."
    }
    if ([string]::IsNullOrWhiteSpace([string]$journal.transactionId)) { throw "Transaction journal identity is missing." }
    $recordedHome = [IO.Path]::GetFullPath([string]$journal.codexHome)
    if (-not $recordedHome.Equals($TargetHome, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Transaction journal belongs to a different Codex home: $recordedHome"
    }
    $backupBase = Get-BackupBase -TargetHome $TargetHome
    $backupRoot = Get-FullPathSafe -Root $backupBase -RelativePath ([string]$journal.backupSet)
    Assert-NoReparsePath -Path $backupRoot
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { throw "Transaction recovery backup is missing: $backupRoot" }

    # Preflight all states before reversing any file. Before states also recognize
    # operations never applied or already reversed by an interrupted recovery.
    $reversals = @()
    $destinations = @{}
    foreach ($operation in @($journal.operations) + @($journal.installRecord)) {
        $relative = [string]$operation.destination
        $destination = Get-FullPathSafe -Root $TargetHome -RelativePath $relative
        $key = $destination.ToLowerInvariant()
        if ($destinations.ContainsKey($key) -or $destination -eq $JournalPath) { throw "Invalid duplicate/journal recovery destination: $relative" }
        $destinations[$key] = $true
        $before = $operation.beforeHash
        $after = $operation.afterHash
        foreach ($hash in @($before, $after)) {
            if ($null -ne $hash -and [string]$hash -notmatch '^[a-f0-9]{64}$') { throw "Invalid transaction state hash for '$relative'." }
        }
        if ([bool]$operation.existedBefore -ne ($null -ne $before)) { throw "Inconsistent before state for '$relative'." }
        $backupPath = $null
        if ($null -ne $before) {
            $backupPath = Get-FullPathSafe -Root $backupRoot -RelativePath ([string]$operation.backupRelative)
            if ((Get-FileState -Path $backupPath) -ne $before) { throw "Transaction backup is missing or changed for '$relative'." }
        }
        $current = Get-FileState -Path $destination
        if ($current -ne $before -and $current -ne $after) {
            throw "Ambiguous recovery state for '$relative': file changed after interruption; preserving file and journal."
        }
        $reversals += [pscustomobject]@{ Path = $destination; Before = $before; After = $after; Backup = $backupPath }
    }
    if ([string]$journal.installRecord.destination -ne (Get-RelativePathCompat -BasePath $TargetHome -TargetPath $InstallRecordPath).Replace('\', '/')) {
        throw "Transaction install-record destination is inconsistent."
    }
    foreach ($entry in $reversals) {
        Assert-JournalIdentity -Path $JournalPath
        $current = Get-FileState -Path $entry.Path
        if ($current -eq $entry.Before) { continue }
        if ($current -ne $entry.After) { throw "Ambiguous recovery state for '$($entry.Path)'; preserving file and journal." }
        if ($null -ne $entry.Before) { Write-FileAtomically -Source $entry.Backup -Destination $entry.Path }
        else {
            Assert-NoReparsePath -Path $entry.Path
            Remove-Item -LiteralPath $entry.Path -Force
        }
    }
    Remove-OwnedJournal -Path $JournalPath
    Write-Host "RECOVERED unfinished Codex Engineering transaction." -ForegroundColor Yellow
}

function Get-GitCommit {
    param([Parameter(Mandatory = $true)][string]$Root)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return $null
    }

    try {
        $candidate = (& $git.Source -C $Root rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $candidate) {
            return $candidate
        }
    }
    catch {
        return $null
    }

    return $null
}

function New-InstallRecord {
    param(
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $files = @()
    foreach ($item in ($Plan | Sort-Object DestinationRelative)) {
        $files += [ordered]@{
            source = $item.SourceRelative
            destination = $item.DestinationRelative
            sha256 = $item.SourceHash
        }
    }

    return [ordered]@{
        schemaVersion = 2
        managedBy = "codex-engineering"
        installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        repository = $Root
        gitCommit = Get-GitCommit -Root $Root
        manifestSha256 = Get-Sha256 -Path $ManifestPath
        files = $files
    }
}

try {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
    Assert-NoReparsePath -Path $CodexHome
    Assert-NoReparsePath -Path (Get-BackupBase -TargetHome $CodexHome)
    $lockKey = Get-InstallerLockKey -Path $CodexHome
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $lockHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lockKey))).Replace('-', '') }
    finally { $sha.Dispose() }
    $installerMutex = New-Object Threading.Mutex($false, "Global\CodexEngineeringInstaller-$lockHash")
    try { $script:installerOwnsLock = $installerMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $script:installerOwnsLock = $true }
    if (-not $script:installerOwnsLock) { throw "Another installer owns this Codex home; no state was changed: $CodexHome" }
    $manifestPath = Join-Path $RepoRoot "manifest.json"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json not found: $manifestPath"
    }

    $manifest = Read-JsonFile -Path $manifestPath
    if ([int]$manifest.schemaVersion -ne 2) {
        throw "Unsupported manifest schemaVersion '$($manifest.schemaVersion)'. Expected 2."
    }

    $installRecordPath = Get-FullPathSafe -Root $CodexHome -RelativePath ([string]$manifest.installRecord)
    $transactionPath = Get-FullPathSafe -Root $CodexHome -RelativePath ([string]$manifest.transactionRecord)

    Assert-NoReparsePath -Path $installRecordPath
    $script:journalHash = Get-FileState -Path $transactionPath
    if ($null -ne $script:journalHash) {
        if ($DryRun) {
            throw "An unfinished transaction requires recovery. Run install.ps1 without -DryRun first."
        }

        Restore-Transaction `
            -JournalPath $transactionPath `
            -TargetHome $CodexHome `
            -InstallRecordPath $installRecordPath

        Write-Host ""
    }

    if (-not $SkipValidation) {
        Write-Host "Validating source tree..."
        & (Join-Path $PSScriptRoot "validate.ps1") -RepoRoot $RepoRoot | Out-Null
        Write-Host ""
    }

    $previousRecord = Read-JsonFile -Path $installRecordPath
    $previousFiles = New-HashMapFromRecord -Record $previousRecord
    $plan = @(Get-DeploymentPlan -Root $RepoRoot -TargetHome $CodexHome -Manifest $manifest)

    foreach ($item in $plan) { $null = Get-FileState -Path $item.Destination }
    $newDestinations = @{}
    foreach ($item in $plan) {
        $newDestinations[$item.DestinationRelative.ToLowerInvariant()] = $true
    }

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

    $stale = @()
    $released = @()

    foreach ($entry in $previousFiles.GetEnumerator()) {
        if ($newDestinations.ContainsKey($entry.Key)) {
            continue
        }

        $relative = $entry.Value.Destination
        $path = Get-FullPathSafe -Root $CodexHome -RelativePath $relative
        $null = Get-FileState -Path $path
        $isNowProtected = Test-ProtectedDestination `
            -Destination $relative `
            -Protected $manifest.protectedDestinations

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $currentHash = Get-Sha256 -Path $path
            $wasLocallyModified = $currentHash -ne $entry.Value.Sha256

            if ($wasLocallyModified -and $isNowProtected) {
                # Ownership migration: a destination that is protected in the
                # new manifest must never be overwritten or removed merely
                # because an older manifest managed it. Preserve the local file
                # and omit it from the new install record, thereby releasing it
                # from Codex Engineering ownership.
                $released += [pscustomobject]@{
                    DestinationRelative = $relative
                    Destination = $path
                }
                continue
            }

            if ($wasLocallyModified -and -not $Force) {
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
    Write-Host "  Release:    $($released.Count) locally modified protected file(s)"
    Write-Host "  Preserve:   all unowned files/directories"
    Write-Host ""

    if ($DryRun) {
        foreach ($item in $toWrite) {
            Write-Host "WRITE   $($item.DestinationRelative)"
        }
        foreach ($item in $toRemove) {
            Write-Host "REMOVE  $($item.DestinationRelative)"
        }
        foreach ($item in $released) {
            Write-Host "RELEASE $($item.DestinationRelative) (preserve local file)"
        }

        Write-Host ""
        Write-Host "DRY RUN: no files were changed." -ForegroundColor Yellow
        return
    }

    Assert-NoReparsePath -Path $CodexHome
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null

    foreach ($item in $released) {
        Write-Host "RELEASED $($item.DestinationRelative) (preserved; no longer managed)" -ForegroundColor Yellow
    }

    $transactionId = [guid]::NewGuid().ToString("N")
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupSet = "$stamp-$($transactionId.Substring(0,8))"
    $backupBase = Get-BackupBase -TargetHome $CodexHome
    $backupRoot = Get-FullPathSafe -Root $backupBase -RelativePath $backupSet
    Assert-NoReparsePath -Path $backupRoot
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

    $operations = @()
    $seen = @{}

    foreach ($item in @($toRemove + $toWrite)) {
        $key = $item.DestinationRelative.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        $exists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        $backupRelative = $null

        if ($exists) {
            $backupRelative = (Join-Path "files" $item.DestinationRelative).Replace('\', '/')
            Copy-ToTransactionBackup `
                -ExistingPath $item.Destination `
                -BackupRoot $backupRoot `
                -BackupRelative $backupRelative
        }

        $operations += [ordered]@{
            destination = $item.DestinationRelative
            beforeHash = Get-FileState -Path $item.Destination
            afterHash = if ($item.PSObject.Properties.Name -contains "SourceHash") { $item.SourceHash } else { $null }
            existedBefore = [bool]$exists
            backupRelative = $backupRelative
        }
    }

    $recordExistedBefore = Test-Path -LiteralPath $installRecordPath -PathType Leaf
    $recordBackupRelative = $null
    if ($recordExistedBefore) {
        $recordBackupRelative = "install-record.json"
        Copy-ToTransactionBackup `
            -ExistingPath $installRecordPath `
            -BackupRoot $backupRoot `
            -BackupRelative $recordBackupRelative
    }

    $record = New-InstallRecord -Plan $plan -Root $RepoRoot -ManifestPath $manifestPath
    $preparedRecord = Join-Path $backupRoot "after-install-record.json"
    Write-Utf8NoBom -Path $preparedRecord -Content ($record | ConvertTo-Json -Depth 10)

    $journal = [ordered]@{
        schemaVersion = 2
        transactionId = $transactionId
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        codexHome = $CodexHome
        backupSet = $backupSet
        operations = $operations
        installRecord = [ordered]@{
            destination = ([string]$manifest.installRecord).Replace('\', '/')
            beforeHash = Get-FileState -Path $installRecordPath
            afterHash = Get-Sha256 -Path $preparedRecord
            existedBefore = [bool]$recordExistedBefore
            backupRelative = $recordBackupRelative
        }
    }

    Assert-JournalIdentity -Path $transactionPath
    Write-JsonAtomically -Value $journal -Destination $transactionPath
    $script:journalHash = Get-Sha256 -Path $transactionPath

    try {
        foreach ($operation in $operations) {
            $path = Get-FullPathSafe -Root $CodexHome -RelativePath $operation.destination
            if ((Get-FileState -Path $path) -ne $operation.beforeHash) {
                throw "Destination changed during planning: $($operation.destination)"
            }
        }
        foreach ($item in $toRemove) {
            Assert-JournalIdentity -Path $transactionPath
            Assert-NoReparsePath -Path $item.Destination
            Remove-Item -LiteralPath $item.Destination -Force
            Write-Host "REMOVED $($item.DestinationRelative)"
        }

        foreach ($item in $toWrite) {
            Assert-JournalIdentity -Path $transactionPath
            Write-FileAtomically -Source $item.Source -Destination $item.Destination
            Write-Host "WROTE   $($item.DestinationRelative)"
        }

        foreach ($operation in $operations) {
            $path = Get-FullPathSafe -Root $CodexHome -RelativePath $operation.destination
            if ((Get-FileState -Path $path) -ne $operation.afterHash) {
                throw "Destination does not match transaction after state: $($operation.destination)"
            }
        }
        Assert-JournalIdentity -Path $transactionPath
        if ((Get-FileState -Path $installRecordPath) -ne $journal.installRecord.beforeHash) {
            throw "Install record changed during transaction."
        }
        Write-FileAtomically -Source $preparedRecord -Destination $installRecordPath
        if ((Get-FileState -Path $installRecordPath) -ne $journal.installRecord.afterHash) {
            throw "Install record does not match transaction after state; preserving recovery journal."
        }
        Remove-OwnedJournal -Path $transactionPath

        Write-Host ""
        Write-Host "PASS  Codex Engineering installed successfully." -ForegroundColor Green
        Write-Host "      Install record: $installRecordPath"
        Write-Host "      Recovery backup: $backupRoot"
    }
    catch {
        $applyError = $_
        Write-Host ""
        Write-Host "Deployment failed; attempting transaction rollback..." -ForegroundColor Yellow

        try {
            Restore-Transaction `
                -JournalPath $transactionPath `
                -TargetHome $CodexHome `
                -InstallRecordPath $installRecordPath

            Write-Host "ROLLBACK PASS  Previous managed state restored." -ForegroundColor Green
        }
        catch {
            Write-Host "ROLLBACK FAIL  Automatic recovery could not complete." -ForegroundColor Red
            Write-Host "               Leave the transaction journal in place and do not use -Force."
            throw
        }

        throw $applyError
    }
}
catch {
    Write-Host ""
    Write-Host "FAIL  $($_.Exception.Message)" -ForegroundColor Red
    throw
}

finally {
    if ($script:installerOwnsLock) { $installerMutex.ReleaseMutex() }
    if ($null -ne $installerMutex) { $installerMutex.Dispose() }
    $script:installerOwnsLock = $false
}
