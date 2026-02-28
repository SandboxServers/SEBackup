# Logger.psm1 - SEBackup Logging Module
# Provides structured, thread-safe logging for the SEBackup system.

# Module-scoped variables
$script:SEBLogRoot = $null
$script:SEBLogContext = $null
$script:LastRotationCheck = $null
$script:LogMutex = $null

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
