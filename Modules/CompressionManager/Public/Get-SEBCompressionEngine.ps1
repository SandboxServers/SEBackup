function Get-SEBCompressionEngine {
    <#
    .SYNOPSIS
        Detects which compression engine is available on the system.

    .DESCRIPTION
        Checks the local or remote system for available compression engines. Prefers
        7-Zip when available because it offers superior compression ratios and speeds
        for large game server files. Falls back to the built-in .NET compression
        (Compress-Archive / System.IO.Compression) which is always available.

        When 7-Zip is found, queries its version string for logging and compatibility
        purposes.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the detection runs
        on the remote machine.

    .EXAMPLE
        $engine = Get-SEBCompressionEngine
        Write-Host "Using engine: $($engine.Engine) $(if ($engine.Path) { "at $($engine.Path)" })"

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        $engine = Get-SEBCompressionEngine -Session $session

    .OUTPUTS
        PSCustomObject
        An object with properties:
        - Engine  (string): "7zip" or "dotnet"
        - Version (string): Version string for the engine, or "built-in" for dotnet
        - Path    (string): Full path to 7z.exe, or $null for dotnet
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $sevenZipPath = Find-7ZipPath -Session $Session

    if ($sevenZipPath) {
        # Get version information from 7-Zip
        $versionScript = {
            param([string]$ExePath)
            try {
                $versionInfo = (Get-Item -Path $ExePath -ErrorAction Stop).VersionInfo
                return "$($versionInfo.ProductMajorPart).$($versionInfo.ProductMinorPart).$($versionInfo.ProductBuildPart)"
            }
            catch {
                return 'unknown'
            }
        }

        if ($Session) {
            $version = Invoke-Command -Session $Session -ScriptBlock $versionScript -ArgumentList $sevenZipPath -ErrorAction SilentlyContinue
        }
        else {
            $version = & $versionScript -ExePath $sevenZipPath
        }

        if (-not $version) { $version = 'unknown' }

        Write-Verbose "7-Zip detected at '$sevenZipPath' (version $version)."

        return [PSCustomObject]@{
            Engine  = '7zip'
            Version = $version
            Path    = $sevenZipPath
        }
    }
    else {
        Write-Verbose "7-Zip not found. Using .NET built-in compression."

        return [PSCustomObject]@{
            Engine  = 'dotnet'
            Version = 'built-in'
            Path    = $null
        }
    }
}
