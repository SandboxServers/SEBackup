function Get-SEBNodeConfig {
    <#
    .SYNOPSIS
        Reads and returns node configuration from a per-node TOML file.

    .DESCRIPTION
        Loads the TOML configuration for a specific compute node from the
        Config/nodes/{NodeName}.toml file. Each node config contains connection
        details such as hostname, username, and display name.

        When the -All switch is specified, all node configuration files in the
        Config/nodes/ directory are loaded and returned as an array.

    .PARAMETER NodeName
        The name of the node whose configuration to load. This corresponds to
        the filename (without extension) in the Config/nodes/ directory.
        Required unless -All is specified.

    .PARAMETER All
        When specified, loads and returns all node configurations found in the
        Config/nodes/ directory as an array of hashtables. Each hashtable
        includes a _NodeName key with the filename stem for identification.

    .EXAMPLE
        $node = Get-SEBNodeConfig -NodeName 'gamingpc01'
        $node.node.hostname

    .EXAMPLE
        # Load all node configurations
        $nodes = Get-SEBNodeConfig -All
        $nodes | ForEach-Object { Write-Host "$($_._NodeName): $($_.node.hostname)" }

    .OUTPUTS
        System.Collections.Hashtable
        A single node configuration hashtable, or an array of hashtables when -All is used.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All
    )

    $paths = Resolve-ConfigPaths

    if ($PSCmdlet.ParameterSetName -eq 'All') {
        # Load all node configs from the nodes directory
        if (-not (Test-Path -Path $paths.NodesDir -PathType Container)) {
            Write-Warning "Nodes config directory not found at: $($paths.NodesDir)"
            return @()
        }

        $nodeFiles = Get-ChildItem -Path $paths.NodesDir -Filter '*.toml' -File -ErrorAction SilentlyContinue
        if (-not $nodeFiles -or $nodeFiles.Count -eq 0) {
            Write-Verbose "No node config files found in: $($paths.NodesDir)"
            return @()
        }

        $allConfigs = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($nodeFile in $nodeFiles) {
            try {
                $rawToml = Get-Content -Path $nodeFile.FullName -Raw -ErrorAction Stop
                $nodeConfig = ConvertFrom-Toml -InputObject $rawToml
                if ($null -eq $nodeConfig) {
                    $nodeConfig = @{}
                }
                # Attach the node name (filename without extension) for identification
                $nodeConfig['_NodeName'] = $nodeFile.BaseName
                $allConfigs.Add($nodeConfig)
                Write-Verbose "Loaded node config: $($nodeFile.BaseName)"
            }
            catch {
                Write-Error "Failed to parse node config '$($nodeFile.Name)': $_"
            }
        }

        return $allConfigs.ToArray()
    }
    else {
        # NodeName becomes a filename segment ("<NodeName>.toml"). Validate it through the shared
        # traversal/filename guard so a crafted or mistyped node name cannot escape the nodes
        # directory or be treated as a wildcard before it is interpolated into the path below.
        if (-not (Test-SEBSafeName -Name $NodeName)) {
            Write-Error "Invalid NodeName '$NodeName': path separators, traversal, rooted paths, wildcards, and invalid filename characters are not allowed."
            return $null
        }

        # Load a single node config
        $nodeFilePath = Join-Path -Path $paths.NodesDir -ChildPath "${NodeName}.toml"

        if (-not (Test-Path -Path $nodeFilePath -PathType Leaf)) {
            Write-Error "Node config not found: $nodeFilePath"
            return $null
        }

        Write-Verbose "Reading node config from: $nodeFilePath"
        try {
            $rawToml = Get-Content -Path $nodeFilePath -Raw -ErrorAction Stop
            $nodeConfig = ConvertFrom-Toml -InputObject $rawToml
            if ($null -eq $nodeConfig) {
                $nodeConfig = @{}
            }
            $nodeConfig['_NodeName'] = $NodeName
            return $nodeConfig
        }
        catch {
            Write-Error "Failed to parse node config '${NodeName}.toml': $_"
            return $null
        }
    }
}
