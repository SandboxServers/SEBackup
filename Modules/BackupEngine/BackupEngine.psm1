# BackupEngine.psm1 - SEBackup Full + Incremental Backup Orchestration Module
# Brings together all SEBackup modules to execute the complete backup workflow
# for Space Engineers Torch Server instances across remote Windows nodes.

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
