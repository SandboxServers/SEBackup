function Remove-SEBLockFile {
    <#
    .SYNOPSIS
        Removes the lock file for a backup instance.

    .DESCRIPTION
        Deletes the lock file at Data/lockfiles/{InstanceName}.lock, releasing
        the lock and allowing other backup processes to acquire it. This function
        is designed to be safe to call in finally blocks -- it never throws and
        logs any errors as warnings.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose lock to release.

    .EXAMPLE
        Remove-SEBLockFile -InstanceName 'PvPArena'

    .OUTPUTS
        System.Boolean
        $true if the lock file was successfully removed or did not exist,
        $false if removal failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName
    )

    $projectRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
    $lockFilePath = Join-Path -Path $projectRoot -ChildPath 'Data' -AdditionalChildPath 'lockfiles', "${InstanceName}.lock"

    if (-not (Test-Path -Path $lockFilePath -PathType Leaf)) {
        Write-Verbose "Lock file for '$InstanceName' does not exist. Nothing to remove."
        return $true
    }

    try {
        Remove-Item -Path $lockFilePath -Force -ErrorAction Stop
        Write-Verbose "Lock file removed for '$InstanceName': $lockFilePath"
        return $true
    }
    catch {
        $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
        if ($hasLogger) {
            Write-SEBLog -Message "Failed to remove lock file for '$InstanceName': $_" -Level WARN -Context $InstanceName
        }
        Write-Warning "Failed to remove lock file for '$InstanceName': $_"
        return $false
    }
}
