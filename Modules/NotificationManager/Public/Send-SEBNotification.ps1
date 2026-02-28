function Send-SEBNotification {
    <#
    .SYNOPSIS
        Sends a Discord webhook notification with a color-coded embed.

    .DESCRIPTION
        Core notification function for the SEBackup system. Builds a Discord embed using
        the specified type, title, message, and optional fields, then sends it to the
        configured Discord webhook URL.

        Color mapping by type:
        - Success:  Green  (0x2ECC71)
        - Warning:  Yellow (0xF1C40F)
        - Failure:  Red    (0xE74C3C)
        - Restore:  Blue   (0x3498DB)
        - Info:     Gray   (0x95A5A6)

        If the global configuration includes a "failure_mention" value and the notification
        type is Failure, the mention string is prepended to the webhook content to trigger
        Discord notifications for the mentioned role or user.

        Handles HTTP 429 (rate limited) responses by respecting the Retry-After header,
        retrying up to 3 times.

        This function NEVER throws or blocks the calling pipeline. Notification failures
        are logged as warnings and silently swallowed so that backup operations are not
        interrupted by notification issues.

    .PARAMETER Type
        The notification type. Determines the embed color and whether failure mentions
        are applied. Must be one of: Success, Warning, Failure, Restore, Info.

    .PARAMETER Title
        The title of the notification embed.

    .PARAMETER Message
        The body/description text of the notification embed.

    .PARAMETER Fields
        An optional hashtable of key-value pairs to display as inline fields in the
        Discord embed. Keys become field names, values become field values.

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig). Must contain
        a "notifications" section with at least "webhook_url". May also contain
        "failure_mention" for @-mentioning roles/users on failures.

    .EXAMPLE
        $config = Get-SEBGlobalConfig
        Send-SEBNotification -Type Success -Title "Backup Complete" -Message "All good." -GlobalConfig $config

    .EXAMPLE
        $fields = @{ "Duration" = "3m 22s"; "Archive Size" = "2.1 GB" }
        Send-SEBNotification -Type Failure -Title "Backup Failed" -Message "VSS error." -Fields $fields -GlobalConfig $config

    .OUTPUTS
        None
        This function produces no output. Errors are logged as warnings.

    .LINK
        Send-SEBBackupNotification
        Send-SEBRestoreNotification
        Test-SEBNotificationConfig
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Warning', 'Failure', 'Restore', 'Info')]
        [string]$Type,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [hashtable]$Fields,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    try {
        # Extract notification settings from config
        $notifConfig = $GlobalConfig['notifications']
        if (-not $notifConfig) {
            Write-Warning "Send-SEBNotification: No 'notifications' section in global config. Skipping."
            return
        }

        # Check if notifications are enabled
        $enabled = $notifConfig['enabled']
        if (-not $enabled) {
            Write-Verbose "Notifications are disabled in configuration. Skipping."
            return
        }

        # Validate webhook URL
        $webhookUrl = $notifConfig['webhook_url']
        if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
            Write-Warning "Send-SEBNotification: No webhook_url configured. Skipping."
            return
        }

        # Determine if we need to add a failure mention
        $mention = $null
        if ($Type -eq 'Failure') {
            $failureMention = $notifConfig['failure_mention']
            if (-not [string]::IsNullOrWhiteSpace($failureMention)) {
                $mention = $failureMention
            }
        }

        # Build the Discord embed payload
        $embedParams = @{
            Type    = $Type
            Title   = $Title
            Message = $Message
        }
        if ($Fields) {
            $embedParams['Fields'] = $Fields
        }
        if ($mention) {
            $embedParams['Mention'] = $mention
        }

        $payload = New-SEBDiscordEmbed @embedParams
        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress

        # Send with retry logic for rate limiting (HTTP 429)
        $maxRetries = 3
        $attempt = 0

        while ($attempt -lt $maxRetries) {
            $attempt++
            Write-Verbose "Sending Discord notification (attempt $attempt/$maxRetries): $Title"

            try {
                $response = Invoke-WebRequest -Uri $webhookUrl -Method Post -Body $jsonBody `
                    -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop

                # Success - Discord returns 204 No Content on success
                Write-Verbose "Discord notification sent successfully (HTTP $($response.StatusCode))."
                return
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                if ($statusCode -eq 429 -and $attempt -lt $maxRetries) {
                    # Rate limited - respect Retry-After header
                    $retryAfter = 5  # Default backoff in seconds
                    try {
                        $retryHeader = $_.Exception.Response.Headers['Retry-After']
                        if ($retryHeader) {
                            $retryAfter = [math]::Ceiling([double]$retryHeader)
                        }
                    }
                    catch {
                        # Use default backoff if header parsing fails
                    }

                    Write-Warning "Send-SEBNotification: Rate limited (HTTP 429). Retrying in ${retryAfter}s (attempt $attempt/$maxRetries)."
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                else {
                    # Non-retryable error or final retry
                    Write-Warning "Send-SEBNotification: Failed to send notification (HTTP $statusCode): $_"
                    return
                }
            }
        }

        Write-Warning "Send-SEBNotification: Exhausted all $maxRetries retry attempts. Notification not sent."
    }
    catch {
        # Catch-all: notification failures must NEVER propagate
        Write-Warning "Send-SEBNotification: Unexpected error: $_"
    }
}
