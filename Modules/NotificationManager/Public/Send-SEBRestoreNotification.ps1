function Send-SEBRestoreNotification {
    <#
    .SYNOPSIS
        Sends a Discord notification for a restore event.

    .DESCRIPTION
        Sends a color-coded restore notification to the configured Discord webhook.
        Uses the "Restore" type (blue embed) and includes details about the instance
        being restored, the restore point, and who initiated the restore.

        Only sends if the global configuration has notifications.on_restore set to $true
        (or notifications.enabled is $true and on_restore is not explicitly disabled).

    .PARAMETER InstanceName
        The name of the Space Engineers server instance being restored.

    .PARAMETER RestorePoint
        A string identifying the restore point (e.g., a timestamp or backup label).

    .PARAMETER InitiatedBy
        A string identifying who or what initiated the restore operation.
        Defaults to "CLI" if not specified.

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig).

    .EXAMPLE
        Send-SEBRestoreNotification -InstanceName "PvPArena" -RestorePoint "2026-02-27_Full" -GlobalConfig $config

    .EXAMPLE
        Send-SEBRestoreNotification -InstanceName "Creative01" -RestorePoint "2026-02-26_Inc_3" -InitiatedBy "Admin:JohnDoe" -GlobalConfig $config

    .OUTPUTS
        None

    .LINK
        Send-SEBNotification
        Send-SEBBackupNotification
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RestorePoint,

        [Parameter()]
        [string]$InitiatedBy = 'CLI',

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    try {
        $notifConfig = $GlobalConfig['notifications']
        if (-not $notifConfig -or -not $notifConfig['enabled']) {
            Write-Verbose "Notifications disabled. Skipping restore notification for '$InstanceName'."
            return
        }

        # Check if restore notifications are enabled
        # Default to $true if on_restore is not explicitly set but notifications are enabled
        # Skip only when on_restore is explicitly the boolean false. Absent means "default on";
        # comparing a generic falsey value would wrongly disable on e.g. 0 or an empty string.
        $onRestore = $notifConfig['on_restore']
        if ($onRestore -is [bool] -and -not $onRestore) {
            Write-Verbose "Restore notifications are disabled (notifications.on_restore = false). Skipping."
            return
        }

        $title = "Restore Initiated: $InstanceName"
        $message = "A restore operation has been initiated for **$InstanceName**."

        $fields = @{
            'Instance'      = $InstanceName
            'Restore Point' = $RestorePoint
            'Initiated By'  = $InitiatedBy
        }

        Send-SEBNotification -Type Restore -Title $title -Message $message -Fields $fields -GlobalConfig $GlobalConfig
    }
    catch {
        # Notifications must never block the restore pipeline
        Write-Warning "Send-SEBRestoreNotification: Unexpected error: $_"
    }
}
