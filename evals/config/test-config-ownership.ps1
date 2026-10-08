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

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$rootConfig = Join-Path $RepoRoot ".codex\config.toml"
$templateConfig = Join-Path $RepoRoot "project-template\.codex\config.toml"
$runtimeConfig = Join-Path $RepoRoot "runtime\config.toml"
$manifestPath = Join-Path $RepoRoot "manifest.json"

Assert-True (Test-Path -LiteralPath $rootConfig -PathType Leaf) "Root project config is missing."
Assert-True (Test-Path -LiteralPath $templateConfig -PathType Leaf) "Project-template config is missing."
Assert-True (-not (Test-Path -LiteralPath $runtimeConfig -PathType Leaf)) "runtime/config.toml must not exist."

Assert-True `
    ((Get-Sha256 -Path $rootConfig) -eq (Get-Sha256 -Path $templateConfig)) `
    "Root and template project configs differ."

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$managedDestinations = @($manifest.managed | ForEach-Object { ([string]$_.destination).Replace('\','/') })
Assert-True (-not ($managedDestinations -contains "config.toml")) "User-level config.toml must not be managed."

$protected = @($manifest.protectedDestinations | ForEach-Object { ([string]$_).ToLowerInvariant() })
Assert-True ($protected -contains "config.toml") "User-level config.toml must be protected."

$config = Get-Content -LiteralPath $rootConfig -Raw
$forbidden = @(
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

foreach ($key in $forbidden) {
    if ($config -match "(?m)^\s*$([regex]::Escape($key))\s*=" -or
        $config -match "(?m)^\s*\[$([regex]::Escape($key))[\.\]]") {
        throw "Project config contains machine/user-only key '$key'."
    }
}

Write-Host "PASS  Config ownership regression checks passed." -ForegroundColor Green
