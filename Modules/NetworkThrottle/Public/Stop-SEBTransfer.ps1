function Stop-SEBTransfer {
    <#
    .SYNOPSIS
        Cancels a running BITS transfer job and cleans up resources.

    .DESCRIPTION
        Stops and removes a BITS (Background Intelligent Transfer Service) transfer job.
        This cancels any in-progress transfer and removes the job from the BITS queue,
        cleaning up any temporary files created by BITS.

        Accepts either a BITS job object (as returned by Start-SEBBitsTransfer -Asynchronous)
        or a job ID string.

    .PARAMETER JobId
        The BITS job to cancel. Accepts either:
        - A BITS job object (from Start-SEBBitsTransfer -Asynchronous)
        - A string job ID (GUID)

    .EXAMPLE
        $job = Start-SEBBitsTransfer -Source "C:\file.zip" -Destination "\\NAS\file.zip" -Asynchronous
        Stop-SEBTransfer -JobId $job
        # Cancels the transfer and removes the BITS job.

    .EXAMPLE
        Stop-SEBTransfer -JobId "a1b2c3d4-5678-90ab-cdef-1234567890ab"

    .OUTPUTS
        None

    .LINK
        Start-SEBBitsTransfer
        Get-SEBTransferStatus
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        $JobId
    )

    try {
        Import-Module -Name BitsTransfer -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to import BitsTransfer module: $_"
        return
    }

    try {
        # Resolve the job ID string
        $jobIdString = if ($JobId -is [string]) {
            $JobId
        }
        else {
            $JobId.JobId
        }

        $job = Get-BitsTransfer -JobId $jobIdString -ErrorAction SilentlyContinue

        if (-not $job) {
            Write-Warning "BITS job '$jobIdString' not found. It may have already completed or been removed."
            return
        }

        Write-Verbose "Cancelling BITS job '$jobIdString' (State: $($job.JobState))."

        # Remove the BITS job, which cancels the transfer and cleans up temp files
        Remove-BitsTransfer -BitsJob $job -ErrorAction Stop

        Write-Verbose "BITS job '$jobIdString' has been cancelled and removed."
    }
    catch {
        Write-Error "Failed to stop BITS transfer: $_"
    }
}
