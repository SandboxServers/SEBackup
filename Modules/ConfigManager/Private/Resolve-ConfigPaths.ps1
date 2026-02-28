function Resolve-ConfigPaths {
    <#
    .SYNOPSIS
        Resolves filesystem paths to the SEBackup configuration directory and files.

    .DESCRIPTION
        Determines the location of the Config/ directory relative to the module root.
        The expected project layout places ConfigManager at Modules/ConfigManager/ and
        the configuration directory at Config/ in the project root, so the Config/
        directory is located two levels up from $PSScriptRoot (../../Config).

        Returns a hashtable containing resolved paths for:
        - ConfigRoot:  The Config/ directory path
        - GlobalToml:  The full path to global.toml
        - NodesDir:    The Config/nodes/ directory path

        If the SEBACKUP_CONFIG_ROOT environment variable is set, it takes precedence
        over the computed path.

    .EXAMPLE
        $paths = Resolve-ConfigPaths
        $paths.GlobalToml  # e.g., /home/user/SEBackup/Config/global.toml

    .OUTPUTS
        System.Collections.Hashtable
        A hashtable with keys: ConfigRoot, GlobalToml, NodesDir.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # Allow override via environment variable
    if ($env:SEBACKUP_CONFIG_ROOT -and (Test-Path -Path $env:SEBACKUP_CONFIG_ROOT -PathType Container)) {
        $configRoot = $env:SEBACKUP_CONFIG_ROOT
    }
    else {
        # Navigate from Modules/ConfigManager/ up to project root, then into Config/
        $moduleRoot = $PSScriptRoot | Split-Path -Parent   # Modules/ConfigManager/
        $projectRoot = $moduleRoot | Split-Path -Parent     # Modules/
        $projectRoot = $projectRoot | Split-Path -Parent    # Project root
        $configRoot = Join-Path -Path $projectRoot -ChildPath 'Config'
    }

    if (-not (Test-Path -Path $configRoot -PathType Container)) {
        Write-Warning "Config directory not found at: $configRoot"
    }

    $globalToml = Join-Path -Path $configRoot -ChildPath 'global.toml'
    $nodesDir   = Join-Path -Path $configRoot -ChildPath 'nodes'

    return @{
        ConfigRoot = $configRoot
        GlobalToml = $globalToml
        NodesDir   = $nodesDir
    }
}
