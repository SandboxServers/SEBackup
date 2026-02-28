function New-SEBDiscordEmbed {
    <#
    .SYNOPSIS
        Builds a Discord webhook payload with an embed for SEBackup notifications.

    .DESCRIPTION
        Internal helper function that constructs a Discord webhook payload hashtable
        containing a rich embed. The embed includes a color-coded sidebar, title,
        description, optional fields, and a timestamp.

        If a Mention string is provided (e.g., a Discord role or user mention like
        "<@&RoleID>"), it is set as the top-level "content" field so that the mention
        appears above the embed and triggers Discord notifications for the mentioned
        users or roles.

        Color mapping by notification type:
        - Success:  0x2ECC71 (green)
        - Warning:  0xF1C40F (yellow)
        - Failure:  0xE74C3C (red)
        - Restore:  0x3498DB (blue)
        - Info:     0x95A5A6 (gray)

    .PARAMETER Type
        The notification type, which determines the embed color. Must be one of:
        Success, Warning, Failure, Restore, Info.

    .PARAMETER Title
        The title of the Discord embed.

    .PARAMETER Message
        The description/body text of the Discord embed.

    .PARAMETER Fields
        An optional hashtable of key-value pairs to display as inline fields in the
        embed. Keys become field names, values become field values.

    .PARAMETER Mention
        An optional Discord mention string (e.g., "<@&123456789>" for a role mention,
        or "<@123456789>" for a user mention). When provided, this is set as the
        top-level "content" of the webhook payload to trigger Discord notifications.

    .EXAMPLE
        $payload = New-SEBDiscordEmbed -Type Success -Title "Backup Complete" -Message "PvPArena backed up successfully."

    .EXAMPLE
        $fields = @{ "Duration" = "2m 15s"; "Size" = "1.8 GB" }
        $payload = New-SEBDiscordEmbed -Type Failure -Title "Backup Failed" -Message "VSS snapshot error." -Fields $fields -Mention "<@&987654321>"

    .OUTPUTS
        System.Collections.Hashtable
        A hashtable ready for JSON conversion and posting to a Discord webhook.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
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

        [Parameter()]
        [string]$Mention
    )

    # Color mapping (Discord uses decimal color values)
    $colorMap = @{
        'Success' = 0x2ECC71  # Green
        'Warning' = 0xF1C40F  # Yellow
        'Failure' = 0xE74C3C  # Red
        'Restore' = 0x3498DB  # Blue
        'Info'    = 0x95A5A6  # Gray
    }

    # Build the embed object
    $embed = @{
        title       = $Title
        description = $Message
        color       = $colorMap[$Type]
        timestamp   = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }

    # Add fields if provided
    if ($Fields -and $Fields.Count -gt 0) {
        $embedFields = [System.Collections.ArrayList]::new()
        foreach ($key in $Fields.Keys) {
            [void]$embedFields.Add(@{
                name   = $key
                value  = [string]$Fields[$key]
                inline = $true
            })
        }
        $embed['fields'] = @($embedFields)
    }

    # Build the top-level webhook payload
    $payload = @{
        embeds = @($embed)
    }

    # Add mention as content if specified
    if (-not [string]::IsNullOrWhiteSpace($Mention)) {
        $payload['content'] = $Mention
    }

    return $payload
}
