# LoadMonitor.psm1 - SEBackup Load Monitoring Module
# Provides CPU, memory, and player-count load checks against configurable
# thresholds with defer/skip logic for the SEBackup Space Engineers Torch
# Server Backup & Restore System.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
