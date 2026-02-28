function Get-SEBSharePath {
    <#
    .SYNOPSIS
        Constructs the UNC path to a Space Engineers instance's SMB share.

    .DESCRIPTION
        Builds and returns the UNC share path for accessing a specific Space
        Engineers Torch server instance over the network. The path is constructed
        from the node configuration's hostname and the instance configuration's
        share name:

            \\{hostname}\{share_name}

        This UNC path can then be used with Test-SEBShare, Mount-SEBShare,
        or standard PowerShell file operations.

    .PARAMETER NodeConfig
        A hashtable containing the node's configuration. Must include a
        'hostname' key with the server's network-accessible hostname or IP.

    .PARAMETER InstanceConfig
        A hashtable containing the instance's configuration. Must include a
        'share_name' key with the SMB share name configured on the remote node.

    .EXAMPLE
        $nodeConfig = @{ hostname = "GameServer01" }
        $instanceConfig = @{ share_name = "TorchBackups" }
        Get-SEBSharePath -NodeConfig $nodeConfig -InstanceConfig $instanceConfig
        # Returns: \\GameServer01\TorchBackups

    .EXAMPLE
        $nodeConfig = @{ hostname = "192.168.1.100" }
        $instanceConfig = @{ share_name = "SE_PvP_Arena" }
        $sharePath = Get-SEBSharePath -NodeConfig $nodeConfig -InstanceConfig $instanceConfig
        Test-SEBShare -SharePath $sharePath -Credential $cred
        # Constructs the UNC path and tests share accessibility.

    .OUTPUTS
        System.String
        The UNC path in the format \\hostname\share_name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [hashtable]$NodeConfig,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNull()]
        [hashtable]$InstanceConfig
    )

    if (-not $NodeConfig.ContainsKey('hostname') -or [string]::IsNullOrWhiteSpace($NodeConfig['hostname'])) {
        throw "NodeConfig must contain a non-empty 'hostname' key."
    }

    if (-not $InstanceConfig.ContainsKey('share_name') -or [string]::IsNullOrWhiteSpace($InstanceConfig['share_name'])) {
        throw "InstanceConfig must contain a non-empty 'share_name' key."
    }

    $hostname  = $NodeConfig['hostname']
    $shareName = $InstanceConfig['share_name']

    $uncPath = "\\$hostname\$shareName"
    Write-Verbose "Constructed UNC path: $uncPath"

    return $uncPath
}
