function Find-7ZipPath {
    <#
    .SYNOPSIS
        Locates the 7z.exe executable on a Windows system.

    .DESCRIPTION
        Searches for the 7-Zip command-line executable (7z.exe) in standard
        installation locations on Windows:

        1. Program Files\7-Zip\7z.exe
        2. Program Files (x86)\7-Zip\7z.exe
        3. The system PATH (via Get-Command)

        When a PSSession is provided, the search runs on the remote node.

        Returns the full path to 7z.exe if found, or $null if 7-Zip is not installed.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the 7-Zip search
        runs on the remote machine rather than locally.

    .EXAMPLE
        $path = Find-7ZipPath
        if ($path) { Write-Host "7-Zip found at: $path" }

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        $path = Find-7ZipPath -Session $session

    .OUTPUTS
        System.String or $null
        The full path to 7z.exe, or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $searchScript = {
        # Check standard installation directories
        $candidates = @(
            (Join-Path -Path $env:ProgramFiles -ChildPath '7-Zip\7z.exe')
            (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath '7-Zip\7z.exe')
        )

        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path -Path $candidate -PathType Leaf)) {
                return $candidate
            }
        }

        # Check if 7z is available on PATH
        $pathResult = Get-Command -Name '7z' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($pathResult) {
            return $pathResult.Source
        }

        # Also check for 7z.exe explicitly on PATH
        $pathResult = Get-Command -Name '7z.exe' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($pathResult) {
            return $pathResult.Source
        }

        return $null
    }

    if ($Session) {
        $result = Invoke-Command -Session $Session -ScriptBlock $searchScript -ErrorAction SilentlyContinue
    }
    else {
        $result = & $searchScript
    }

    return $result
}
