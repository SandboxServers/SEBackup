# ManifestManager.psm1 - SEBackup Manifest Management Module
# Provides SHA256 manifest generation, diff comparison, incremental chain
# traversal, and manifest I/O for the SEBackup Space Engineers Torch Server
# Backup & Restore System.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
