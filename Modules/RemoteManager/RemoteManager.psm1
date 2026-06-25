# RemoteManager.psm1 - SEBackup Remote Session Management Module
# Provides PSSession management, WinRM connectivity, and SMB share operations
# for communicating with remote Space Engineers Torch server nodes.

# Module-scoped session cache (NodeName -> live PSSession)
$script:SEBSessions = @{}

# Module-scoped map of NodeName -> the resolved connection target (hostname/IP) that
# New-SEBSession last successfully connected to for that node. This is the safety net that
# kills the "NodeConfig-drop" bug class: when New-SEBSession is later called WITHOUT
# -NodeConfig and must (re)create a session (cache miss or a dead cache entry), it reuses
# this pinned host for -ComputerName instead of falling through to the bare friendly alias.
# Every by-value refresh/reconnect site (the orchestrator/VSS cache refreshes and the
# wrapper's reconnect) therefore targets the pinned IP/FQDN, never the alias. Cleared per
# node in Remove-SEBSession.
$script:SEBSessionHosts = @{}

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)

foreach ($import in @($Private + $Public)) {
    try { . $import.FullName }
    catch { Write-Error "Failed to import $($import.FullName): $_" }
}

Export-ModuleMember -Function $Public.BaseName
