# NotificationManager Module

Discord webhook notification system for backup and restore operations. Sends color-coded embed messages with operation details including duration, archive size, file count, and warnings.

## Exported Functions

### Send-SEBNotification

Sends a generic notification message to the configured Discord webhook.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| Message | string | Yes | -- | The notification message text. |
| Level | string | No | `Info` | Notification level: `Info`, `Warning`, `Error`, `Success`. |
| WebhookUrl | string | No | from config | Discord webhook URL. If omitted, read from global config. |

**Output:** `PSCustomObject` with `Sent` (bool), `StatusCode` (int), `ErrorMessage` (string).

```powershell
Send-SEBNotification -Message "System maintenance starting" -Level Warning
Send-SEBNotification -Message "All backups complete" -Level Success
```

### Send-SEBBackupNotification

Sends a detailed backup result notification to Discord with a formatted embed containing operation metrics.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| BackupResult | PSCustomObject | Yes | -- | The result object from `Invoke-SEBBackup`. |
| GlobalConfig | hashtable | Yes | -- | The global configuration containing notification settings. |

**Output:** `PSCustomObject` with `Sent` (bool), `StatusCode` (int), `ErrorMessage` (string).

The embed includes: instance name, node, backup type, duration, archive size, file count, chain info, integrity status, and any warnings. Color coding: green for success, red for failure, yellow for warnings.

```powershell
$backupResult = Invoke-SEBBackup -NodeName "GameServer01" -InstanceName "PvPArena"
Send-SEBBackupNotification -BackupResult $backupResult -GlobalConfig $globalConfig
```

### Send-SEBRestoreNotification

Sends a restore operation notification to Discord with formatted details.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| RestoreResult | PSCustomObject | Yes | -- | The result object from `Invoke-SEBRestore`. |
| GlobalConfig | hashtable | Yes | -- | The global configuration containing notification settings. |

**Output:** `PSCustomObject` with `Sent` (bool), `StatusCode` (int), `ErrorMessage` (string).

```powershell
$restoreResult = Invoke-SEBRestore -NodeName "GameServer01" -InstanceName "PvPArena" `
    -RestorePoint "PvPArena_FULL_20260227.json" -Force
Send-SEBRestoreNotification -RestoreResult $restoreResult -GlobalConfig $globalConfig
```

### Test-SEBNotificationConfig

Validates that notification settings are properly configured and sends a test message to verify webhook connectivity.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| GlobalConfig | hashtable | No | from config | The global configuration to validate. |

**Output:** `PSCustomObject` with `Valid` (bool), `WebhookReachable` (bool), `ErrorMessage` (string).

```powershell
$test = Test-SEBNotificationConfig
if ($test.Valid -and $test.WebhookReachable) {
    Write-Host "Discord notifications are configured and working."
}
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `New-SEBDiscordEmbed` | Builds a Discord embed object (hashtable) with title, description, color, fields, and footer. Handles the Discord webhook JSON payload format including rate-limit retry logic. |

## Dependencies

None (uses built-in `Invoke-RestMethod` for HTTP POST to Discord webhooks).

## Configuration

Notification settings come from the `[notifications]` section of `global.toml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable or disable all notifications. |
| `webhook_url` | string | -- | Discord webhook URL. |
| `on_success` | bool | `true` | Send notification on successful backup. |
| `on_failure` | bool | `true` | Send notification on failed backup. |
| `on_warning` | bool | `true` | Send notification when backup completes with warnings. |
| `mention_on_failure` | string | -- | Discord role or user mention for failures (e.g., `<@&12345>`). |

## Usage Scenarios

**Scenario 1: Automatic notification after backup (handled by BackupEngine)**
```powershell
# This is called automatically by Invoke-SEBBackup:
if ($globalConfig.notifications.enabled) {
    Send-SEBBackupNotification -BackupResult $result -GlobalConfig $globalConfig
}
```

**Scenario 2: Manual alert for system events**
```powershell
Send-SEBNotification -Message "Server GameServer01 is unreachable. Backups suspended." -Level Error
```

**Scenario 3: Testing webhook configuration**
```powershell
$test = Test-SEBNotificationConfig -GlobalConfig (Get-SEBGlobalConfig -Force)
if (-not $test.WebhookReachable) {
    Write-Error "Discord webhook is not reachable: $($test.ErrorMessage)"
}
```
