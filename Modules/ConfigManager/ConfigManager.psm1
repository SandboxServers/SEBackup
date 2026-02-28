# ConfigManager.psm1 - SEBackup Configuration Management Module
# Provides TOML-based configuration loading, merging, caching, and validation
# for the SEBackup Space Engineers Torch Server Backup & Restore System.

# Module-scoped variables for caching
$script:CachedGlobalConfig = $null
$script:CachedGlobalConfigTime = [datetime]::MinValue
$script:CacheTTLSeconds = 60

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
