# VSSManager.psm1 - SEBackup VSS Shadow Copy Lifecycle Management Module
# Provides Volume Shadow Copy Service (VSS) shadow copy creation, mounting,
# dismounting, and cleanup operations for consistent backup snapshots on
# remote Windows nodes.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
