function Resolve-DestinationDirectory {
    <#
    .SYNOPSIS
        Resolves the directory a leaf-file copy should target from a -Destination value.

    .DESCRIPTION
        robocopy's destination argument is always a directory. A caller's -Destination,
        however, may be an existing directory, a full file path, a path with a trailing
        separator, or a bare filename. [System.IO.Path]::GetDirectoryName returns an empty
        string for a bare filename and the parent for a file path, neither of which is safe
        to hand to New-Item/robocopy unguarded. This helper normalizes all of those into a
        concrete directory path, falling back to the current location when no directory
        component is present.

    .PARAMETER Destination
        The destination value supplied to Copy-SEBThrottled.

    .OUTPUTS
        System.String. The directory path robocopy should copy into.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination
    )

    # An existing directory, or a path that ends with a separator, is itself the target dir.
    if ((Test-Path -Path $Destination -PathType Container) -or
        $Destination.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or
        $Destination.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        return $Destination.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    # Otherwise treat -Destination as a file path and take its parent. A bare filename has no
    # parent (GetDirectoryName returns ''), so fall back to the current location.
    $dir = [System.IO.Path]::GetDirectoryName($Destination)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = (Get-Location).Path
    }
    return $dir
}
