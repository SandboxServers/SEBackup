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
    if ($instanceConfig -isnot [hashtable]) {
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

function Convert-PSObjectToHashtable {
    <#
    .SYNOPSIS
        Converts a PSCustomObject (from remoting deserialization) to a hashtable.

    .DESCRIPTION
        Internal helper that recursively converts PSCustomObject instances returned
        from Invoke-Command back into hashtables for consistent handling.

    .PARAMETER InputObject
        The PSCustomObject to convert.

    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($InputObject -is [hashtable]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = Convert-PSObjectToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        # Catches PSToml's [System.Collections.Specialized.OrderedDictionary] (returned by
        # ConvertFrom-Toml) and any other dictionary shape, which are NOT [hashtable] and would
        # otherwise fall through to the passthrough branch -- leaving Merge-ConfigOverrides to
        # fail binding its [hashtable] parameter.
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = Convert-PSObjectToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    elseif ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = Convert-PSObjectToHashtable -InputObject $prop.Value
        }
        return $result
    }
    elseif ($InputObject -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSObjectToHashtable -InputObject $item))
        }
        return $list.ToArray()
    }
    else {
        return $InputObject
    }
}

function ConvertTo-CanonicalInstanceConfig {
    <#
    .SYNOPSIS
        Normalizes a legacy instance-config layout to the canonical schema the engine reads.

    .DESCRIPTION
        Back-compat shim for nodes whose C:\SEBackup\instances\{name}.toml was written by an
        older Register-Instance.ps1 / Setup-Node.ps1 that emitted the now-superseded layout:
        operational values nested under [paths] / [smb] / [vss] / [instance], and the VRage key
        named [vrage_api].key.

        The current engine (Invoke-SEBBackup, Invoke-SEBRestore, Test-SEBPreFlight,
        Start/Stop-SEBTorchServer) reads the operational values as FLAT top-level keys
        (world_path, staging_path, share_name, run_mode) plus a nested [vrage_api] table with
        port / security_key. New configs are generated in that shape directly, so this shim is
        ONLY a bridge for already-deployed nodes that have not been re-registered.

        It is intentionally additive and non-destructive: a legacy value is copied to its
        canonical key ONLY when the canonical key is absent, so a config already written in the
        canonical schema passes through untouched and an explicit canonical value always wins.

    .PARAMETER InputObject
        The parsed instance-config hashtable (already converted from the TOML / remoting shape).

    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InputObject
    )

    $config = $InputObject

    # Map legacy nested values onto canonical flat keys, only filling gaps.
    # (legacy section, legacy key) -> canonical top-level key
    $flatMap = @(
        @{ Section = 'paths'; Key = 'world_save';    Target = 'world_path' }
        @{ Section = 'paths'; Key = 'staging_local'; Target = 'staging_path' }
        @{ Section = 'smb';   Key = 'share_name';    Target = 'share_name' }
    )

    foreach ($m in $flatMap) {
        if (-not $config.ContainsKey($m.Target) -and
            $config.ContainsKey($m.Section) -and
            $config[$m.Section] -is [hashtable] -and
            $config[$m.Section].ContainsKey($m.Key) -and
            -not [string]::IsNullOrWhiteSpace([string]$config[$m.Section][$m.Key])) {
            $config[$m.Target] = $config[$m.Section][$m.Key]
        }
    }

    # run_mode used to live under [instance]; the engine now reads it top-level.
    if (-not $config.ContainsKey('run_mode') -and
        $config.ContainsKey('instance') -and
        $config['instance'] -is [hashtable] -and
        $config['instance'].ContainsKey('run_mode') -and
        -not [string]::IsNullOrWhiteSpace([string]$config['instance']['run_mode'])) {
        $config['run_mode'] = $config['instance']['run_mode']
    }

    # VRage key was renamed [vrage_api].key -> [vrage_api].security_key.
    if ($config.ContainsKey('vrage_api') -and $config['vrage_api'] -is [hashtable]) {
        $vrage = $config['vrage_api']
        if (-not $vrage.ContainsKey('security_key') -and
            $vrage.ContainsKey('key') -and
            -not [string]::IsNullOrWhiteSpace([string]$vrage['key'])) {
            $vrage['security_key'] = $vrage['key']
        }
    }

    return $config
}
