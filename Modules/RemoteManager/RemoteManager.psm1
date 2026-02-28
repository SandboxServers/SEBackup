# RemoteManager.psm1 - SEBackup Remote Session Management Module
# Provides PSSession management, WinRM connectivity, and SMB share operations
# for communicating with remote Space Engineers Torch server nodes.

# Module-scoped session cache
$script:SEBSessions = @{}

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
