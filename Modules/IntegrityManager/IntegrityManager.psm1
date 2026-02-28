# IntegrityManager.psm1 - SEBackup Archive Integrity Verification Module
# Provides three levels of archive verification: quick CRC/hash checks,
# manifest cross-checks, and full chain reconstruction validation for the
# SEBackup Space Engineers Torch Server Backup & Restore System.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
