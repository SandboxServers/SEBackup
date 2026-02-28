function Start-SEBBitsTransfer {
    <#
    .SYNOPSIS
        Starts a BITS (Background Intelligent Transfer Service) file transfer.

    .DESCRIPTION
        Initiates a BITS transfer from source to destination. BITS provides bandwidth
        throttling, automatic retry, and the ability to resume interrupted transfers.

        When the -Asynchronous switch is used, the function returns a BITS job object
        immediately, allowing the caller to monitor progress via Get-SEBTransferStatus
        and complete or cancel the transfer as needed.

        Without -Asynchronous, the function blocks until the transfer completes. This
        is the default behavior used by Copy-SEBThrottled.

        Handles the case where the BITS service is not available by throwing a clear
        error message.

    .PARAMETER Source
        The source file path to transfer. Supports local and UNC paths.

    .PARAMETER Destination
        The destination path for the transferred file. Supports local and UNC paths.

    .PARAMETER Priority
        The BITS job priority level. Controls how aggressively BITS uses available
        bandwidth. Valid values: Foreground, High, Normal, Low.
        Defaults to "Low" to minimize impact on other network traffic.

    .PARAMETER Credential
        An optional PSCredential for authenticating to remote (UNC) paths.

    .PARAMETER Asynchronous
        When specified, starts the transfer in the background and returns the BITS
        job object immediately. The caller is responsible for monitoring the transfer
        and completing it when done.

    .EXAMPLE
        Start-SEBBitsTransfer -Source "C:\Backup\archive.7z" -Destination "\\NAS\Backups\archive.7z"
        # Synchronous transfer, blocks until complete.

    .EXAMPLE
        $job = Start-SEBBitsTransfer -Source "C:\Backup\archive.7z" -Destination "\\NAS\Backups\archive.7z" -Asynchronous
        # Returns immediately with a BITS job object for monitoring.

    .EXAMPLE
        $cred = Get-Credential
        Start-SEBBitsTransfer -Source "\\Server\Share\data.zip" -Destination "C:\Local\" -Credential $cred

    .OUTPUTS
        Microsoft.BackgroundIntelligentTransfer.Management.BitsJob
        When -Asynchronous is specified, returns the BITS job object.

        None
        When synchronous (default), returns nothing on success.

    .LINK
        Get-SEBTransferStatus
        Stop-SEBTransfer
        Copy-SEBThrottled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [Parameter()]
        [ValidateSet('Foreground', 'High', 'Normal', 'Low')]
        [string]$Priority = 'Low',

        [Parameter()]
        [PSCredential]$Credential,

        [Parameter()]
        [switch]$Asynchronous
    )

    # Verify BITS is available before attempting the transfer
    if (-not (Test-BITSAvailable)) {
        throw "BITS service is not available or not running. Cannot start BITS transfer. " +
              "Ensure the Background Intelligent Transfer Service (BITS) is installed and started."
    }

    # Import the BitsTransfer module
    try {
        Import-Module -Name BitsTransfer -ErrorAction Stop
    }
    catch {
        throw "Failed to import BitsTransfer module: $_"
    }

    # Build the parameter set
    $bitsParams = @{
        Source      = $Source
        Destination = $Destination
        Priority    = $Priority
        ErrorAction = 'Stop'
    }

    if ($Credential) {
        $bitsParams['Credential'] = $Credential
    }

    if ($Asynchronous) {
        $bitsParams['Asynchronous'] = $true
    }

    Write-Verbose "Starting BITS transfer: '$Source' -> '$Destination' (Priority: $Priority, Async: $Asynchronous)"

    try {
        $job = Start-BitsTransfer @bitsParams

        if ($Asynchronous) {
            Write-Verbose "BITS job started asynchronously. JobId: $($job.JobId)"
            return $job
        }
        else {
            Write-Verbose "BITS transfer completed successfully."
        }
    }
    catch {
        Write-Error "BITS transfer failed: $_"
        throw
    }
}
