function Get-SEBAllInstanceConfigs {
    <#
    .SYNOPSIS
        Reads all instance configurations from a remote compute node.

    .DESCRIPTION
        Connects to a remote compute node using the provided PSSession and
        discovers all TOML instance configuration files located at:
            C:\SEBackup\instances\*.toml

        Each discovered file is parsed on the remote node, transferred back,
        and merged with global defaults using the same logic as
        Get-SEBInstanceConfig. Returns an array of hashtables, one per instance.

        This function is useful for backup orchestration when you need to
        process all server instances on a given node in a single pass.

    .PARAMETER Session
        An active PSSession connected to the target compute node. The session
        must have access to read files at C:\SEBackup\instances\.

    .EXAMPLE
        $session = New-PSSession -ComputerName 'gamingpc01' -Credential $cred
        $instances = Get-SEBAllInstanceConfigs -Session $session
        foreach ($inst in $instances) {
            Write-Host "Instance: $($inst._InstanceName) - Port: $($inst.vrage_api.port)"
        }

    .EXAMPLE
        # Count how many instances are configured on a node
        $instances = Get-SEBAllInstanceConfigs -Session $session
        Write-Host "Found $($instances.Count) instance(s) on $($session.ComputerName)"

    .OUTPUTS
        System.Collections.Hashtable[]
        An array of hashtables, each representing a fully-merged instance
        configuration. Each hashtable includes _InstanceName and _NodeName
        metadata keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $instancesDir = 'C:\SEBackup\instances'

    Write-Verbose "Discovering instance configs on remote node: $($Session.ComputerName):$instancesDir"

    try {
        $remoteResults = Invoke-Command -Session $Session -ScriptBlock {
            param($dir)

            if (-not (Test-Path -Path $dir -PathType Container)) {
                Write-Warning "Instances directory not found on remote node: $dir"
                return @()
            }

            $tomlFiles = Get-ChildItem -Path $dir -Filter '*.toml' -File -ErrorAction SilentlyContinue
            if (-not $tomlFiles -or $tomlFiles.Count -eq 0) {
                Write-Verbose "No instance config files found in: $dir"
                return @()
            }

            # PSToml must be available on the remote node
            if (-not (Get-Module -Name PSToml -ListAvailable)) {
                throw "PSToml module is not installed on the remote node. Install it with: Install-Module PSToml"
            }

            Import-Module PSToml -ErrorAction Stop

            $results = [System.Collections.Generic.List[object]]::new()

            foreach ($file in $tomlFiles) {
                try {
                    $rawContent = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
                    $parsed = ConvertFrom-Toml -InputObject $rawContent

                    $results.Add(@{
                        InstanceName = $file.BaseName
                        Config       = $parsed
                    })
                }
                catch {
                    Write-Error "Failed to parse instance config '$($file.Name)': $_"
                }
            }

            return $results.ToArray()
        } -ArgumentList $instancesDir -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to read instance configs from $($Session.ComputerName): $_"
        return @()
    }

    if ($null -eq $remoteResults -or $remoteResults.Count -eq 0) {
        Write-Verbose "No instance configs found on $($Session.ComputerName)"
        return @()
    }

    # Get global config for merging
    $globalConfig = Get-SEBGlobalConfig

    $globalDefaults = @{}
    if ($null -ne $globalConfig) {
        if ($globalConfig.ContainsKey('defaults')) {
            $globalDefaults = $globalConfig.defaults.Clone()
        }
        $mergeableGlobalKeys = @('compression', 'load_awareness', 'network')
        foreach ($key in $mergeableGlobalKeys) {
            if ($globalConfig.ContainsKey($key)) {
                $globalDefaults[$key] = $globalConfig[$key]
            }
        }
    }

    $allInstances = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($result in $remoteResults) {
        $instanceName = $null
        $instanceConfig = $null

        # Handle deserialization from remoting (could be PSObject or hashtable)
        if ($result -is [hashtable]) {
            $instanceName = $result.InstanceName
            $instanceConfig = $result.Config
        }
        elseif ($result -is [System.Management.Automation.PSCustomObject]) {
            $instanceName = $result.InstanceName
            $instanceConfig = $result.Config
        }
        else {
            Write-Warning "Unexpected result type from remote node: $($result.GetType().FullName)"
            continue
        }

        if ($null -eq $instanceConfig) {
            Write-Warning "Instance config '$instanceName' was null, skipping."
            continue
        }

        # Convert PSObject to hashtable if remoting deserialized it
        if ($instanceConfig -isnot [hashtable]) {
            $instanceConfig = Convert-PSObjectToHashtable -InputObject $instanceConfig
        }

        # Normalize legacy instance-config layouts to the canonical schema the engine reads
        # (same shim Get-SEBInstanceConfig applies, so batch discovery and single-load agree).
        $instanceConfig = ConvertTo-CanonicalInstanceConfig -InputObject $instanceConfig

        # Merge with global defaults
        if ($globalDefaults.Count -gt 0) {
            $merged = Merge-ConfigOverrides -Default $globalDefaults -Override $instanceConfig
        }
        else {
            $merged = $instanceConfig
        }

        # Attach metadata
        $merged['_InstanceName'] = $instanceName
        $merged['_NodeName'] = $Session.ComputerName

        $allInstances.Add($merged)
        Write-Verbose "Loaded instance config: $instanceName"
    }

    return $allInstances.ToArray()
}
