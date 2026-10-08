[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Errors = @()
$script:Warnings = @()

function Add-ValidationError {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Errors += $Message
}

function Add-ValidationWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Warnings += $Message
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

function Get-ManagedSourceFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $result = @()

    foreach ($item in $Manifest.managed) {
        $kind = [string]$item.kind
        $sourceRelative = [string]$item.source
        $destinationRelative = [string]$item.destination

        try {
            $sourcePath = Get-FullPathSafe -Root $Root -RelativePath $sourceRelative
        }
        catch {
            Add-ValidationError $_.Exception.Message
            continue
        }

        if (Test-ProtectedDestination -Destination $destinationRelative -Protected $Manifest.protectedDestinations) {
            Add-ValidationError "Manifest attempts to manage protected destination '$destinationRelative'."
            continue
        }

        switch ($kind) {
            "file" {
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    Add-ValidationError "Managed source file does not exist: $sourceRelative"
                    continue
                }

                $result += [pscustomobject]@{
                    Source = $sourcePath
                    SourceRelative = $sourceRelative.Replace('\', '/')
                    Destination = $destinationRelative.Replace('\', '/')
                }
            }

            "tree" {
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                    Add-ValidationError "Managed source directory does not exist: $sourceRelative"
                    continue
                }

                foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force) {
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        Add-ValidationError "Managed source contains a reparse point/symlink: $($file.FullName)"
                        continue
                    }

                    $childRelative = Get-RelativePathCompat -BasePath $sourcePath -TargetPath $file.FullName
                    $destination = Join-Path $destinationRelative $childRelative

                    if (Test-ProtectedDestination -Destination $destination -Protected $Manifest.protectedDestinations) {
                        Add-ValidationError "Managed tree reaches protected destination '$destination'."
                        continue
                    }

                    $result += [pscustomobject]@{
                        Source = $file.FullName
                        SourceRelative = (Join-Path $sourceRelative $childRelative).Replace('\', '/')
                        Destination = $destination.Replace('\', '/')
                    }
                }
            }

            default {
                Add-ValidationError "Unsupported manifest kind '$kind' for source '$sourceRelative'."
            }
        }
    }

    return $result
}

function Test-SkillManifest {
    param([Parameter(Mandatory = $true)][string]$SkillFile)

    $lines = @(Get-Content -LiteralPath $SkillFile)
    if ($lines.Count -lt 4 -or $lines[0].Trim() -ne "---") {
        Add-ValidationError "Skill lacks YAML frontmatter: $SkillFile"
        return
    }

    $closingIndex = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") {
            $closingIndex = $i
            break
        }
    }

    if ($closingIndex -lt 2) {
        Add-ValidationError "Skill frontmatter is not closed: $SkillFile"
        return
    }

    $frontmatter = ($lines[1..($closingIndex - 1)] -join "`n")
    $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*$')
    $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(.+?)\s*$')

    if (-not $nameMatch.Success) {
        Add-ValidationError "Skill frontmatter requires a simple 'name:' value: $SkillFile"
    }

    if (-not $descriptionMatch.Success -or $descriptionMatch.Groups[1].Value.Trim().Length -lt 20) {
        Add-ValidationError "Skill frontmatter requires a meaningful 'description:' value: $SkillFile"
    }

    if ($nameMatch.Success) {
        $folderName = Split-Path -Leaf (Split-Path -Parent $SkillFile)
        if ($folderName -ne $nameMatch.Groups[1].Value) {
            Add-ValidationError "Skill folder '$folderName' does not match frontmatter name '$($nameMatch.Groups[1].Value)'."
        }
    }

    $body = Get-Content -LiteralPath $SkillFile -Raw
    $links = [regex]::Matches($body, '\]\(((?:references|scripts|assets)/[^)#]+)')
    $skillRoot = Split-Path -Parent $SkillFile

    foreach ($match in $links) {
        $relative = $match.Groups[1].Value
        try {
            $linked = Get-FullPathSafe -Root $skillRoot -RelativePath $relative
            if (-not (Test-Path -LiteralPath $linked)) {
                Add-ValidationError "Skill link does not exist: $relative in $SkillFile"
            }
        }
        catch {
            Add-ValidationError $_.Exception.Message
        }
    }
}

function Get-PythonTomlCommand {
    $candidates = @(
        @{ Command = "py"; Prefix = @("-3") },
        @{ Command = "python"; Prefix = @() },
        @{ Command = "python3"; Prefix = @() }
    )

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate.Command -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }

        try {
            $probeArgs = @()
            $probeArgs += $candidate.Prefix
            $probeArgs += "-c"
            $probeArgs += 'import tomllib'
            $previousErrorAction = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                & $command.Source @probeArgs *> $null
                $probeExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorAction
            }

            if ($probeExitCode -eq 0) {
                return [pscustomobject]@{
                    Command = $command.Source
                    Prefix = @($candidate.Prefix)
                }
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Test-TomlFiles {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $python = Get-PythonTomlCommand
    if ($null -eq $python) {
        Add-ValidationWarning "Python 3.11+ was not available, so strict TOML parsing was skipped."
        return
    }

    $code = "import sys,tomllib; tomllib.load(open(sys.argv[1],'rb'))" 

    foreach ($path in $Paths) {
        $args = @()
        $args += $python.Prefix
        $args += "-c"
        $args += $code
        $args += $path

        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = @(& $python.Command @args 2>&1)
            $parseExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }

        if ($parseExitCode -ne 0) {
            $detail = ($output | ForEach-Object { "$_" }) -join " "
            Add-ValidationError "TOML parse failed for '$path': $detail"
        }
    }
}

try {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $manifestPath = Join-Path $RepoRoot "manifest.json"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json not found at repo root: $RepoRoot"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "manifest.json is invalid JSON: $($_.Exception.Message)"
    }

    if ([int]$manifest.schemaVersion -ne 2) {
        Add-ValidationError "Unsupported manifest schemaVersion '$($manifest.schemaVersion)'. Expected 2."
    }

    foreach ($requiredProperty in @("installRecord", "transactionRecord")) {
        if ([string]::IsNullOrWhiteSpace([string]$manifest.$requiredProperty)) {
            Add-ValidationError "manifest.json must define $requiredProperty."
        }
    }

    if (-not (Test-ProtectedDestination -Destination "config.toml" -Protected $manifest.protectedDestinations)) {
        Add-ValidationError "manifest.json must protect user-level config.toml from repo management."
    }

    $managedFiles = @(Get-ManagedSourceFiles -Root $RepoRoot -Manifest $manifest)

    $duplicates = @(
        $managedFiles |
            Group-Object { $_.Destination.ToLowerInvariant() } |
            Where-Object { $_.Count -gt 1 }
    )
    foreach ($duplicate in $duplicates) {
        Add-ValidationError "Multiple managed source files map to destination '$($duplicate.Group[0].Destination)'."
    }

    $required = @(
        "runtime/AGENTS.md",
        "runtime/agents/repo-explorer.toml",
        "runtime/agents/implementation-engineer.toml",
        "runtime/agents/qa-engineer.toml",
        "runtime/agents/security-reliability-engineer.toml",
        "runtime/agents/release-engineer.toml",
        "skills/engineering-orchestration/SKILL.md",
        ".codex/config.toml",
        "project-template/.codex/config.toml",
        "evals/orchestration/cases.json",
        "evals/orchestration/results/ORCH-001-2026-10-07.md",
        "evals/bootstrap/test-bootstrap.ps1",
        "evals/config/test-config-ownership.ps1"
    )

    foreach ($relative in $required) {
        $path = Get-FullPathSafe -Root $RepoRoot -RelativePath $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-ValidationError "Required file is missing: $relative"
        }
    }

    $retiredRuntimeConfig = Join-Path $RepoRoot "runtime\config.toml"
    if (Test-Path -LiteralPath $retiredRuntimeConfig -PathType Leaf) {
        Add-ValidationError "runtime/config.toml is retired. Move shared engineering config to .codex/config.toml and project-template/.codex/config.toml."
    }

    $agentsPath = Join-Path $RepoRoot "runtime\AGENTS.md"
    if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
        $agentsLength = (Get-Item -LiteralPath $agentsPath).Length
        if ($agentsLength -gt 16384) {
            Add-ValidationError "runtime/AGENTS.md is $agentsLength bytes; v1 kernel ceiling is 16384 bytes."
        }
    }

    $projectConfig = Join-Path $RepoRoot ".codex\config.toml"
    $templateConfig = Join-Path $RepoRoot "project-template\.codex\config.toml"
    if (
        (Test-Path -LiteralPath $projectConfig -PathType Leaf) -and
        (Test-Path -LiteralPath $templateConfig -PathType Leaf)
    ) {
        if ((Get-Sha256 -Path $projectConfig) -ne (Get-Sha256 -Path $templateConfig)) {
            Add-ValidationError "Root .codex/config.toml and project-template/.codex/config.toml must match."
        }

        $configText = Get-Content -LiteralPath $projectConfig -Raw
        foreach ($requiredText in @("[agents]", "[skills]", "memories = false")) {
            if ($configText -notmatch [regex]::Escape($requiredText)) {
                Add-ValidationError "Project config is missing expected v1 setting '$requiredText'."
            }
        }

        $forbiddenProjectKeys = @(
            "openai_base_url",
            "chatgpt_base_url",
            "apps_mcp_product_sku",
            "model_provider",
            "model_providers",
            "notify",
            "profile",
            "profiles",
            "experimental_realtime_ws_base_url",
            "otel"
        )

        foreach ($key in $forbiddenProjectKeys) {
            if ($configText -match "(?m)^\s*$([regex]::Escape($key))\s*=" -or
                $configText -match "(?m)^\s*\[$([regex]::Escape($key))[\.\]]") {
                Add-ValidationError "Project config contains machine/user-only key '$key'."
            }
        }
    }

    $agentTomls = @()
    $agentsRoot = Join-Path $RepoRoot "runtime\agents"
    if (Test-Path -LiteralPath $agentsRoot -PathType Container) {
        foreach ($agentFile in Get-ChildItem -LiteralPath $agentsRoot -Filter "*.toml" -File) {
            $agentTomls += $agentFile.FullName
            $text = Get-Content -LiteralPath $agentFile.FullName -Raw
            $nameMatch = [regex]::Match($text, '(?m)^name\s*=\s*"([^"]+)"\s*$')

            if (-not $nameMatch.Success) {
                Add-ValidationError "Agent TOML lacks a simple name field: $($agentFile.FullName)"
            }
            elseif ($nameMatch.Groups[1].Value -ne $agentFile.BaseName) {
                Add-ValidationError "Agent file '$($agentFile.Name)' name '$($nameMatch.Groups[1].Value)' does not match filename."
            }

            foreach ($requiredAgentField in @("description", "sandbox_mode", "developer_instructions")) {
                if ($text -notmatch "(?m)^$requiredAgentField\s*=") {
                    Add-ValidationError "Agent TOML '$($agentFile.Name)' lacks '$requiredAgentField'."
                }
            }
        }
    }

    $skillsRoot = Join-Path $RepoRoot "skills"
    if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $skillsRoot -Directory -Force) {
            $skillFile = Join-Path $directory.FullName "SKILL.md"
            if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
                Add-ValidationError "Top-level skill directory lacks SKILL.md: $($directory.FullName)"
                continue
            }
            Test-SkillManifest -SkillFile $skillFile
        }
    }

    $tomlPaths = @()
    if (Test-Path -LiteralPath $projectConfig -PathType Leaf) { $tomlPaths += $projectConfig }
    if (Test-Path -LiteralPath $templateConfig -PathType Leaf) { $tomlPaths += $templateConfig }
    $tomlPaths += $agentTomls
    Test-TomlFiles -Paths $tomlPaths

    $forbiddenNames = @(
        "auth.json",
        ".codex-global-state.json",
        ".env",
        "id_rsa",
        "id_ed25519"
    )
    $forbiddenExtensions = @(".key", ".pem", ".pfx", ".p12")
    $secretPatterns = @(
        @{ Label = "private key material"; Regex = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' },
        @{ Label = "OpenAI-style secret key"; Regex = '\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b' },
        @{ Label = "GitHub fine-grained token"; Regex = '\bgithub_pat_[A-Za-z0-9_]{20,}\b' },
        @{ Label = "GitHub token"; Regex = '\bgh[pousr]_[A-Za-z0-9]{20,}\b' },
        @{ Label = "AWS access key"; Regex = '\bAKIA[0-9A-Z]{16}\b' },
        @{ Label = "Bearer credential"; Regex = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{24,}' }
    )

    foreach ($file in Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force) {
        if ($file.FullName -match '[\\/]\.git[\\/]') {
            continue
        }

        if ($forbiddenNames -contains $file.Name) {
            Add-ValidationError "Repository contains forbidden runtime/credential file: $($file.FullName)"
            continue
        }

        if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) {
            Add-ValidationError "Repository contains forbidden credential extension: $($file.FullName)"
            continue
        }

        if ($file.Length -le 2MB) {
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                foreach ($pattern in $secretPatterns) {
                    if ($content -match $pattern.Regex) {
                        Add-ValidationError "Possible $($pattern.Label) found in repository file: $($file.FullName)"
                    }
                }
            }
            catch {
                # Binary/non-text files may exist in future skill assets.
            }
        }
    }

    if (-not $Quiet) {
        foreach ($warning in $script:Warnings) {
            Write-Host "WARN  $warning" -ForegroundColor Yellow
        }
    }

    if ($script:Errors.Count -gt 0) {
        foreach ($message in $script:Errors) {
            Write-Host "ERROR $message" -ForegroundColor Red
        }
        throw "Validation failed with $($script:Errors.Count) error(s)."
    }

    if (-not $Quiet) {
        Write-Host "PASS  Codex engineering source tree is valid." -ForegroundColor Green
        Write-Host "      Managed files: $($managedFiles.Count)"
        Write-Host "      Warnings: $($script:Warnings.Count)"
    }

    [pscustomobject]@{
        Status = "PASS"
        ManagedFileCount = $managedFiles.Count
        WarningCount = $script:Warnings.Count
    }
}
catch {
    if (-not $Quiet) {
        Write-Host "FAIL  $($_.Exception.Message)" -ForegroundColor Red
    }
    throw
}
