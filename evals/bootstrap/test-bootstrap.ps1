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

function ConvertTo-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Argument)
    # ProcessStartInfo.Arguments is available on .NET Framework. Quote using
    # Windows argv rules; no command shell interprets special characters.
    $quoted = New-Object Text.StringBuilder
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * (2 * $slashes + 1)))
        }
        else { [void]$quoted.Append(('\' * $slashes)) }
        [void]$quoted.Append($character)
        $slashes = 0
    }
    [void]$quoted.Append(('\' * (2 * $slashes)))
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function New-TestProcessInfo {
    param([string]$Executable, [string[]]$ProcessArguments, [switch]$CaptureOutput)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Arguments = ($ProcessArguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument $_ }) -join ' '
    $info.RedirectStandardOutput = [bool]$CaptureOutput
    $info.RedirectStandardError = [bool]$CaptureOutput
    return $info
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$installer = Join-Path $RepoRoot "scripts\install.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex engineering eval & ' " + [guid]::NewGuid().ToString("N"))
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
        schemaVersion = 2
        transactionId = "simulated"
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        codexHome = $codexHome
        backupSet = $backupSet
        operations = @(
            [ordered]@{
                destination = "AGENTS.md"
                beforeHash = Get-Sha256 -Path $backupAgents
                afterHash = Get-Sha256 -Path $agentsPath
                existedBefore = $true
                backupRelative = "files/AGENTS.md"
            },
            [ordered]@{
                destination = "skills/interrupted.tmp"
                beforeHash = $null
                afterHash = Get-Sha256 -Path $interruptedNewFile
                existedBefore = $false
                backupRelative = $null
            }
        )
        installRecord = [ordered]@{
            destination = ".codex-engineering-install.json"
            beforeHash = Get-Sha256 -Path $backupRecord
            afterHash = Get-Sha256 -Path $installRecord
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

    # Ambiguous existing and newly created files must both survive recovery.
    foreach ($ambiguousRelative in @("AGENTS.md", "skills/interrupted.tmp")) {
        Copy-Item -LiteralPath $backupAgents -Destination $agentsPath -Force
        Write-Utf8NoBom -Path $interruptedNewFile -Content "partial new file"
        Copy-Item -LiteralPath $backupRecord -Destination $installRecord -Force
        Write-Utf8NoBom -Path $transactionRecord -Content ($journal | ConvertTo-Json -Depth 8)
        $ambiguousPath = Join-Path $codexHome $ambiguousRelative
        Write-Utf8NoBom -Path $ambiguousPath -Content "EXTERNAL CHANGE AFTER INTERRUPTION"
        $beforeRecovery = Get-Sha256 -Path $ambiguousPath
        $journalBefore = Get-Sha256 -Path $transactionRecord
        $blocked = $false
        try { & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null }
        catch { $blocked = $_.Exception.Message -match "Ambiguous recovery state" }
        Assert-True $blocked "Ambiguous recovery did not fail for $ambiguousRelative."
        Assert-True ((Get-Sha256 -Path $ambiguousPath) -eq $beforeRecovery) "Ambiguous file was changed/deleted."
        Assert-True ((Get-Sha256 -Path $transactionRecord) -eq $journalBefore) "Ambiguous recovery did not preserve journal."
        # Manual fixture repair returns the files to recognized transaction states.
        Write-Utf8NoBom -Path $agentsPath -Content "CORRUPTED DURING INTERRUPTED DEPLOYMENT"
        Write-Utf8NoBom -Path $interruptedNewFile -Content "partial new file"
        & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null
    }

    # Recovery also accepts operations never applied (unchanged before states).
    Copy-Item -LiteralPath $backupAgents -Destination $agentsPath -Force
    Copy-Item -LiteralPath $backupRecord -Destination $installRecord -Force
    Write-Utf8NoBom -Path $transactionRecord -Content ($journal | ConvertTo-Json -Depth 8)
    & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $transactionRecord)) "Unchanged-before recovery failed."

    # Use two real installer processes. A copied validate script holds the first
    # inside its lifecycle after lock acquisition without production test hooks.
    $fixtureRepo = Join-Path $tempRoot "contention-repo"
    New-Item -ItemType Directory -Path (Join-Path $fixtureRepo "scripts") -Force | Out-Null
    Copy-Item -LiteralPath $installer -Destination (Join-Path $fixtureRepo "scripts/install.ps1")
    Copy-Item -LiteralPath (Join-Path $RepoRoot "manifest.json") -Destination $fixtureRepo
    $ready = Join-Path $tempRoot "first-ready"
    $gate = Join-Path $tempRoot "release-first"
    $validator = "param([string]" + '$RepoRoot' + ")" + [Environment]::NewLine +
        "[IO.File]::WriteAllText('$($ready.Replace("'", "''"))', 'ready')" + [Environment]::NewLine +
        "while (-not [IO.File]::Exists('$($gate.Replace("'", "''"))')) { Start-Sleep -Milliseconds 50 }"
    Write-Utf8NoBom -Path (Join-Path $fixtureRepo "scripts/validate.ps1") -Content $validator
    $pwsh = (Get-Process -Id $PID).Path
    # Exercise argument encoding through the actual host, including embedded
    # quotes, backslashes, and shell metacharacters rather than just string shape.
    $argumentProbe = Join-Path $fixtureRepo "argument probe.ps1"
    $argumentResult = Join-Path $fixtureRepo "argument result.txt"
    Write-Utf8NoBom -Path $argumentProbe -Content 'param([string]$Value, [string]$OutputPath) [IO.File]::WriteAllText($OutputPath, $Value)'
    $probeValue = 'space & ; $ '' "quoted" backslash\" tail\'
    $probeInfo = New-TestProcessInfo -Executable $pwsh -CaptureOutput -ProcessArguments @("-NoProfile", "-File", $argumentProbe, "-Value", $probeValue, "-OutputPath", $argumentResult)
    $probe = [Diagnostics.Process]::Start($probeInfo)
    try {
        $probeOut = $probe.StandardOutput.ReadToEndAsync()
        $probeErr = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit(20000)) { $probe.Kill(); $probe.WaitForExit(); throw "Argument probe timed out." }
        $probeDiagnostic = $probeOut.GetAwaiter().GetResult() + $probeErr.GetAwaiter().GetResult()
        Assert-True ($probe.ExitCode -eq 0) "Argument probe failed: $probeDiagnostic"
        Assert-True ((Get-Content -LiteralPath $argumentResult -Raw) -ceq $probeValue) "Child process arguments did not round-trip exactly."
    }
    finally { $probe.Dispose() }
    $firstInfo = New-TestProcessInfo -Executable $pwsh -ProcessArguments @("-NoProfile", "-File", (Join-Path $fixtureRepo "scripts/install.ps1"), "-RepoRoot", $RepoRoot, "-CodexHome", $codexHome)
    $first = [Diagnostics.Process]::Start($firstInfo)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $ready) -and -not $first.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $ready) "First installer did not reach lock-held validation."
        $recordBefore = Get-Sha256 -Path $installRecord
        $managedBefore = Get-Sha256 -Path $agentsPath
        $secondInfo = New-TestProcessInfo -Executable $pwsh -CaptureOutput -ProcessArguments @("-NoProfile", "-File", $installer, "-RepoRoot", $RepoRoot, "-CodexHome", $codexHome, "-SkipValidation")
        $second = [Diagnostics.Process]::Start($secondInfo)
        try {
            $stdout = $second.StandardOutput.ReadToEndAsync()
            $stderr = $second.StandardError.ReadToEndAsync()
            if (-not $second.WaitForExit(20000)) { $second.Kill(); $second.WaitForExit(); throw "Contending installer did not exit promptly." }
            $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            Assert-True ($second.ExitCode -ne 0 -and $output -match "Another installer owns") "Concurrent installer did not fail on ownership."
        }
        finally { $second.Dispose() }
        Assert-True ((Get-Sha256 -Path $installRecord) -eq $recordBefore -and (Get-Sha256 -Path $agentsPath) -eq $managedBefore) "Contender modified state."
        Assert-True (-not (Test-Path -LiteralPath $transactionRecord)) "Contender created a journal."
        # A killed owner must release OS ownership without lock-file cleanup.
        $first.Kill()
        $first.WaitForExit()
        & $installer -RepoRoot $RepoRoot -CodexHome $codexHome -SkipValidation | Out-Null
    }
    finally {
        if (-not $first.HasExited) { $first.Kill(); $first.WaitForExit() }
        $first.Dispose()
    }

    # Inject an external edit at the actual record replacement boundary. The
    # installer must verify the written record before retiring recovery evidence.
    $recordFaultHome = Join-Path $tempRoot "record-fault\.codex"
    & $installer -RepoRoot $RepoRoot -CodexHome $recordFaultHome -SkipValidation | Out-Null
    $recordFaultPath = Join-Path $recordFaultHome ".codex-engineering-install.json"
    $recordFaultJournal = Join-Path $recordFaultHome ".codex-engineering-transaction.json"
    $externalRecordContent = "EXTERNAL RECORD EDIT AFTER REPLACEMENT"
    function Move-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
        if ($Destination -eq $recordFaultPath) {
            Write-Utf8NoBom -Path $Destination -Content $externalRecordContent
        }
    }
    try {
        $blocked = $false
        try { & $installer -RepoRoot $RepoRoot -CodexHome $recordFaultHome -SkipValidation | Out-Null }
        catch { $blocked = $_.Exception.Message -match "Ambiguous recovery state.*codex-engineering-install" }
        Assert-True $blocked "Installer committed an install record that did not match the journal after state."
        Assert-True (Test-Path -LiteralPath $recordFaultJournal -PathType Leaf) "Record mismatch discarded recovery journal."
        Assert-True ((Get-Content -LiteralPath $recordFaultPath -Raw) -ceq $externalRecordContent) "Record mismatch overwrote the external edit."
        $faultJournal = Get-Content -LiteralPath $recordFaultJournal -Raw | ConvertFrom-Json
        Assert-True ((Get-Sha256 -Path $recordFaultPath) -ne $faultJournal.installRecord.afterHash) "Fault fixture did not create a record hash mismatch."
    }
    finally { Remove-Item -LiteralPath Function:\Move-Item }

    # Junction creation requires no symlink privilege on Windows. Always remove
    # links themselves before recursive temp cleanup, never their target tree.
    $outside = Join-Path $tempRoot "outside"
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    $sentinel = Join-Path $outside "sentinel.txt"
    Write-Utf8NoBom -Path $sentinel -Content "outside preserved"
    foreach ($layout in @("home", "ancestor", "destination", "backup")) {
        $layoutRoot = Join-Path $tempRoot "junction-$layout"
        New-Item -ItemType Directory -Path $layoutRoot -Force | Out-Null
        $targetHome = Join-Path $layoutRoot ".codex"
        $junction = switch ($layout) {
            "home" { $targetHome }
            "ancestor" { Join-Path $layoutRoot "parent" }
            "destination" { Join-Path $targetHome "agents" }
            "backup" { Join-Path $layoutRoot ".codex-engineering-backups" }
        }
        if ($layout -eq "ancestor") { $targetHome = Join-Path $junction ".codex" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $junction) -Force | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        try {
            $blocked = $false
            try { & $installer -RepoRoot $RepoRoot -CodexHome $targetHome -SkipValidation | Out-Null }
            catch { $blocked = $_.Exception.Message -match "Unsupported reparse point" }
            Assert-True $blocked "Installer did not reject $layout junction."
            Assert-True ((Get-Content -LiteralPath $sentinel -Raw) -eq "outside preserved") "Outside sentinel changed."
            Assert-True (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1) "Installer followed junction into outside tree."
        }
        finally { [IO.Directory]::Delete($junction) }
    }

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
