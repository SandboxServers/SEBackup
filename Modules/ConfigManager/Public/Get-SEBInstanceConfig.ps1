function Get-SEBInstanceConfig {
    <#
    .SYNOPSIS
        Reads an instance configuration from a remote compute node via PSRemoting.

    .DESCRIPTION
        Connects to a remote compute node using the provided PSSession and reads
        the instance TOML configuration file located at:
            C:\SEBackup\instances\{InstanceName}.toml

        The remote node must have the PSToml module available for TOML parsing.
        The function uses Invoke-Command to execute the file read and parse
        operation on the remote node.

        The returned instance config is then deep-merged with the global defaults
        (from Get-SEBGlobalConfig), with instance-level values taking precedence.
        This allows instances to override specific settings like VRage API port
        or backup paths while inheriting everything else from the global config.

    .PARAMETER Session
        An active PSSession connected to the target compute node. The session
        must have access to read files at C:\SEBackup\instances\.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance. This corresponds to
        the TOML filename (without extension) on the remote node.

    .EXAMPLE
        $session = New-PSSession -ComputerName 'gamingpc01' -Credential $cred
        $config = Get-SEBInstanceConfig -Session $session -InstanceName 'PvPArena'
        $config.instance.name
        $config.vrage_api.port

    .EXAMPLE
        # Instance overrides the default VRage API port
        $config = Get-SEBInstanceConfig -Session $session -InstanceName 'Creative'
        # If the instance TOML sets port=9090, that wins over the global default of 8080

    .OUTPUTS
        System.Collections.Hashtable
        The instance configuration merged with global defaults. Instance values
        take precedence over global defaults for matching keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName
    )

    # InstanceName becomes a filename segment in the remote path
    # ("C:\SEBackup\instances\<InstanceName>.toml"). Validate it through the shared
    # traversal/filename guard so a crafted or mistyped instance name cannot redirect the remote
    # read outside the instances directory before it is interpolated into the path below.
    if (-not (Test-SEBSafeName -Name $InstanceName)) {
        Write-Error "Invalid InstanceName '$InstanceName': path separators, traversal, rooted paths, wildcards, and invalid filename characters are not allowed."
        return $null
    }

    $remotePath = "C:\SEBackup\instances\${InstanceName}.toml"

    Write-Verbose "Reading instance config from remote node: $($Session.ComputerName):$remotePath"

    try {
        $instanceConfig = Invoke-Command -Session $Session -ScriptBlock {
            param($tomlPath)

            if (-not (Test-Path -Path $tomlPath -PathType Leaf)) {
                throw "Instance config not found on remote node: $tomlPath"
            }

            $rawContent = Get-Content -Path $tomlPath -Raw -ErrorAction Stop

            # PSToml must be available on the remote node
            if (-not (Get-Module -Name PSToml -ListAvailable)) {
                throw "PSToml module is not installed on the remote node. Install it with: Install-Module PSToml"
            }

            Import-Module PSToml -ErrorAction Stop
            $parsed = ConvertFrom-Toml -InputObject $rawContent
            return $parsed
        } -ArgumentList $remotePath -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to read instance config '${InstanceName}' from $($Session.ComputerName): $_"
        return $null
    }

    if ($null -eq $instanceConfig) {
        Write-Error "Instance config '${InstanceName}' returned null from $($Session.ComputerName)"
        return $null
    }

    # Convert deserialized PSObject back to hashtable if needed (remoting can deserialize
    # differently). PSToml's ConvertFrom-Toml also returns an ordered dictionary rather than a
    # [hashtable], and remoting can hand it back as a PSCustomObject or a dictionary depending on
    # the transport -- Convert-PSObjectToHashtable normalizes all of those shapes to a hashtable so
    # the downstream Merge-ConfigOverrides (which requires [hashtable]) binds cleanly.
    #
    # A SHALLOW "-isnot [hashtable]" guard is not enough: remoting/PSToml can hand back a top-level
    # [hashtable] whose NESTED tables are still OrderedDictionary/PSCustomObject. That would skip
    # conversion here, leaving ConvertTo-CanonicalInstanceConfig's "-is [hashtable]" section checks
    # to miss legacy [paths]/[smb]/[vrage_api] tables and Merge-ConfigOverrides (which only recurses
    # when BOTH sides are [hashtable]) to clobber instead of deep-merge them. Test-IsHashtableTree
    # walks the whole tree, so we normalize unless EVERY dictionary descendant is already a hashtable.
    if (-not (Test-IsHashtableTree -InputObject $instanceConfig)) {
        $instanceConfig = Convert-PSObjectToHashtable -InputObject $instanceConfig
    }

    # Normalize legacy instance-config layouts to the canonical schema the engine reads.
    $instanceConfig = ConvertTo-CanonicalInstanceConfig -InputObject $instanceConfig

    # Get global config to use as defaults
    $globalConfig = Get-SEBGlobalConfig

    if ($null -eq $globalConfig) {
        Write-Warning "Could not load global config for default merging. Returning instance config as-is."
        $instanceConfig['_InstanceName'] = $InstanceName
        $instanceConfig['_NodeName'] = $Session.ComputerName
        return $instanceConfig
    }

    # Extract the defaults section from global config for merging
    $globalDefaults = @{}
    if ($globalConfig.ContainsKey('defaults')) {
        $globalDefaults = $globalConfig.defaults.Clone()
    }

    # Also pull in top-level global sections as base defaults that instances can override
    $mergeableGlobalKeys = @('compression', 'load_awareness', 'network')
    foreach ($key in $mergeableGlobalKeys) {
        if ($globalConfig.ContainsKey($key)) {
            $globalDefaults[$key] = $globalConfig[$key]
        }
    }

    # Merge: instance config overrides global defaults
    $merged = Merge-ConfigOverrides -Default $globalDefaults -Override $instanceConfig

    # Attach metadata
    $merged['_InstanceName'] = $InstanceName
    $merged['_NodeName'] = $Session.ComputerName

    return $merged
}
