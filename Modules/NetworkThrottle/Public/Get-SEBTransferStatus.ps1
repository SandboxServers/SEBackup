function Get-SEBTransferStatus {
    <#
    .SYNOPSIS
        Gets the status of a running BITS transfer job.

    .DESCRIPTION
        Retrieves the current status of a BITS (Background Intelligent Transfer Service)
        transfer job, including its state, bytes transferred, total bytes, and percentage
        complete.

        Accepts either a BITS job object (as returned by Start-SEBBitsTransfer -Asynchronous)
        or a job ID string.

    .PARAMETER JobId
        The BITS job to query. Accepts either:
        - A BITS job object (from Start-SEBBitsTransfer -Asynchronous)
        - A string job ID (GUID)

    .EXAMPLE
        $job = Start-SEBBitsTransfer -Source "C:\file.zip" -Destination "\\NAS\file.zip" -Asynchronous
        Get-SEBTransferStatus -JobId $job
        # Returns: State=Transferring, BytesTransferred=1048576, BytesTotal=10485760, PercentComplete=10.0

    .EXAMPLE
        Get-SEBTransferStatus -JobId "a1b2c3d4-5678-90ab-cdef-1234567890ab"

    .OUTPUTS
        PSCustomObject
        An object with properties: JobId, State, BytesTransferred, BytesTotal, PercentComplete.
        Returns $null if the job cannot be found.

    .LINK
        Start-SEBBitsTransfer
        Stop-SEBTransfer
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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
        return $null
    }

    try {
        # Resolve the BITS job
        $job = $null
        if ($JobId -is [string]) {
            $job = Get-BitsTransfer -JobId $JobId -ErrorAction Stop
        }
        else {
            # Assume it is a BITS job object; refresh its state
            $job = Get-BitsTransfer -JobId $JobId.JobId -ErrorAction Stop
        }

        if (-not $job) {
            Write-Warning "BITS job not found."
            return $null
        }

        # Calculate percent complete
        $percentComplete = 0.0
        if ($job.BytesTotal -gt 0) {
            $percentComplete = [math]::Round(($job.BytesTransferred / $job.BytesTotal) * 100, 1)
        }

        return [PSCustomObject]@{
            JobId            = $job.JobId
            State            = $job.JobState.ToString()
            BytesTransferred = $job.BytesTransferred
            BytesTotal       = $job.BytesTotal
            PercentComplete  = $percentComplete
        }
    }
    catch {
        Write-Error "Failed to get BITS transfer status: $_"
        return $null
    }
}
