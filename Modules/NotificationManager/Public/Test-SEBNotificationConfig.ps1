function Test-SEBNotificationConfig {
    <#
    .SYNOPSIS
        Tests the Discord webhook configuration by sending a test message.

    .DESCRIPTION
        Validates the notification configuration by sending a test embed to the configured
        Discord webhook URL. This allows administrators to verify that:
        - The webhook URL is correct and reachable
        - The bot/webhook has permission to post in the target channel
        - The embed formatting looks correct

        Returns $true if the test message was sent successfully, $false otherwise.
        Unlike other notification functions, this one does report errors clearly so
        the administrator can diagnose configuration issues.

    .PARAMETER GlobalConfig
        The global configuration hashtable (from Get-SEBGlobalConfig). Must contain
        a "notifications" section with a valid "webhook_url".

    .EXAMPLE
        $config = Get-SEBGlobalConfig
        if (Test-SEBNotificationConfig -GlobalConfig $config) {
            Write-Host "Webhook is working!"
        } else {
            Write-Host "Webhook test failed. Check the URL and permissions."
        }

    .OUTPUTS
        System.Boolean
        $true if the test notification was sent successfully; $false otherwise.

    .LINK
        Send-SEBNotification
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    try {
        $notifConfig = $GlobalConfig['notifications']
        if (-not $notifConfig) {
            Write-Warning "Test-SEBNotificationConfig: No 'notifications' section found in global config."
            return $false
        }

        $webhookUrl = $notifConfig['webhook_url']
        if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
            Write-Warning "Test-SEBNotificationConfig: No webhook_url configured."
            return $false
        }

        # Build a test notification payload
        $payload = New-SEBDiscordEmbed -Type Info -Title 'SEBackup Test Notification' `
            -Message 'This is a test notification from the SEBackup system. If you can see this, your Discord webhook is configured correctly.'

        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress

        Write-Verbose "Sending test notification to webhook URL..."

        $response = Invoke-WebRequest -Uri $webhookUrl -Method Post -Body $jsonBody `
            -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop

        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            Write-Verbose "Test notification sent successfully (HTTP $($response.StatusCode))."
            return $true
        }
        else {
            Write-Warning "Test-SEBNotificationConfig: Unexpected HTTP status: $($response.StatusCode)"
            return $false
        }
    }
    catch {
        Write-Warning "Test-SEBNotificationConfig: Failed to send test notification: $_"
        return $false
    }
}
