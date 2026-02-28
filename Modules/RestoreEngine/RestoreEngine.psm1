# RestoreEngine.psm1 - SEBackup Point-in-Time Restore Reconstruction Module
# Provides restore operations including chain reconstruction, safety backups,
# and atomic deployment for the SEBackup Space Engineers Torch Server Backup
# & Restore System.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
