function Send-SEBBackupNotification {
    <#
    .SYNOPSIS
        Sends a Discord notification for a backup event with formatted details.

    .DESCRIPTION
        Convenience wrapper around Send-SEBNotification for backup events. Determines
        the notification type (Success, Warning, or Failure) from the backup result
        object, formats the fields nicely for display, and sends the notification
        only if the corresponding notification flag is enabled in the global config.

        Notification gating by config flags:
        - Success results: sent only if notifications.on_success is $true
        - Warning results: sent only if notifications.on_warning is $true
        - Failure results: sent only if notifications.on_failure is $true

        Fields displayed in the embed:
        - Type: Full / Incremental
        - Duration: formatted as Xm Ys
        - Size: formatted as human-readable (KB, MB, GB)
        - Files Changed: count

    .PARAMETER InstanceName
        The name of the Space Engineers server instance that was backed up.

    .PARAMETER BackupResult
        An object describing the backup outcome. Expected properties:
        - Type (string): "Full" or "Incremental"
        - Duration (TimeSpan or seconds as double): how long the backup took
        - ArchiveSize (long): archive size in bytes
        - FilesChanged (int): number of files changed
        - Success (bool): whether the backup succeeded
        - ErrorMessage (string, optional): error details if the backup failed

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig).

    .EXAMPLE
        $result = [PSCustomObject]@{
            Type         = "Full"
            Duration     = 135.5
            ArchiveSize  = 1932735283
            FilesChanged = 12
            Success      = $true
            ErrorMessage = $null
        }
        Send-SEBBackupNotification -InstanceName "PvPArena" -BackupResult $result -GlobalConfig $config

    .EXAMPLE
        $result = [PSCustomObject]@{
            Type         = "Incremental"
            Duration     = 45.2
            ArchiveSize  = 0
            FilesChanged = 0
            Success      = $false
            ErrorMessage = "VSS snapshot timed out"
        }
        Send-SEBBackupNotification -InstanceName "Creative01" -BackupResult $result -GlobalConfig $config

    .OUTPUTS
        None

    .LINK
        Send-SEBNotification
        Send-SEBRestoreNotification
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $BackupResult,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    try {
        $notifConfig = $GlobalConfig['notifications']
        if (-not $notifConfig -or -not $notifConfig['enabled']) {
            Write-Verbose "Notifications disabled. Skipping backup notification for '$InstanceName'."
            return
        }

        # Determine notification type from the backup result
        $notifType = if (-not $BackupResult.Success) {
            'Failure'
        }
        elseif ($BackupResult.ErrorMessage -and $BackupResult.Success) {
            # Succeeded but with warnings
            'Warning'
        }
        else {
            'Success'
        }

        # Check whether this notification type should be sent
        $sendMap = @{
            'Success' = 'on_success'
            'Warning' = 'on_warning'
            'Failure' = 'on_failure'
        }

        $configKey = $sendMap[$notifType]
        if (-not $notifConfig[$configKey]) {
            Write-Verbose "Notification type '$notifType' is disabled (notifications.$configKey = false). Skipping."
            return
        }

        # Format duration
        $durationFormatted = 'N/A'
        if ($null -ne $BackupResult.Duration) {
            $totalSeconds = if ($BackupResult.Duration -is [timespan]) {
                $BackupResult.Duration.TotalSeconds
            }
            else {
                [double]$BackupResult.Duration
            }
            $minutes = [math]::Floor($totalSeconds / 60)
            $seconds = [math]::Round($totalSeconds % 60)
            if ($minutes -gt 0) {
                $durationFormatted = "${minutes}m ${seconds}s"
            }
            else {
                $durationFormatted = "${seconds}s"
            }
        }

        # Format archive size
        $sizeFormatted = 'N/A'
        if ($null -ne $BackupResult.ArchiveSize -and $BackupResult.ArchiveSize -gt 0) {
            $bytes = [long]$BackupResult.ArchiveSize
            if ($bytes -ge 1GB) {
                $sizeFormatted = '{0:N1} GB' -f ($bytes / 1GB)
            }
            elseif ($bytes -ge 1MB) {
                $sizeFormatted = '{0:N1} MB' -f ($bytes / 1MB)
            }
            elseif ($bytes -ge 1KB) {
                $sizeFormatted = '{0:N1} KB' -f ($bytes / 1KB)
            }
            else {
                $sizeFormatted = "$bytes B"
            }
        }

        # Build fields
        $fields = @{
            'Type'          = if ($BackupResult.Type) { $BackupResult.Type } else { 'Unknown' }
            'Duration'      = $durationFormatted
            'Size'          = $sizeFormatted
            'Files Changed' = if ($null -ne $BackupResult.FilesChanged) { [string]$BackupResult.FilesChanged } else { 'N/A' }
        }

        # Build title and message
        $title = switch ($notifType) {
            'Success' { "Backup Complete: $InstanceName" }
            'Warning' { "Backup Warning: $InstanceName" }
            'Failure' { "Backup Failed: $InstanceName" }
        }

        $message = switch ($notifType) {
            'Success' { "$($BackupResult.Type) backup of **$InstanceName** completed successfully." }
            'Warning' { "$($BackupResult.Type) backup of **$InstanceName** completed with warnings." }
            'Failure' {
                $errMsg = if ($BackupResult.ErrorMessage) { $BackupResult.ErrorMessage } else { 'Unknown error' }
                "$($BackupResult.Type) backup of **$InstanceName** failed: $errMsg"
            }
        }

        Send-SEBNotification -Type $notifType -Title $title -Message $message -Fields $fields -GlobalConfig $GlobalConfig
    }
    catch {
        # Notifications must never block the backup pipeline
        Write-Warning "Send-SEBBackupNotification: Unexpected error: $_"
    }
}
