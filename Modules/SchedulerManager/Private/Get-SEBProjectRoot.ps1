function Get-SEBProjectRoot {
    <#
    .SYNOPSIS
        Resolves the SEBackup project root directory.

    .DESCRIPTION
        Determines the project root directory by navigating two levels up from
        the SchedulerManager module location. The module is expected to reside
        at {ProjectRoot}/Modules/SchedulerManager/, so the project root is
        resolved as ../../ relative to $PSScriptRoot.

    .OUTPUTS
        System.String
        The absolute path to the SEBackup project root directory.

    .EXAMPLE
        $root = Get-SEBProjectRoot
        # Returns something like "C:\SEBackup"

    .NOTES
        This is a private helper function used internally by the
        SchedulerManager module. It is not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $moduleDir = $PSScriptRoot
    # Module lives at {ProjectRoot}/Modules/SchedulerManager/Private/
    # so we go up three levels: Private -> SchedulerManager -> Modules -> ProjectRoot
    $projectRoot = (Resolve-Path -Path (Join-Path -Path $moduleDir -ChildPath '..\..\..')).Path

    if (-not (Test-Path -Path $projectRoot)) {
        throw "Unable to resolve SEBackup project root. Expected path '$projectRoot' does not exist."
    }

    return $projectRoot
}
