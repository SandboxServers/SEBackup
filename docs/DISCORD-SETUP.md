# Discord Notification Setup

This guide shows you how to set up Discord webhook notifications for SEBackup, so you get alerts when backups succeed, fail, or encounter warnings.

## What You Will Get

SEBackup sends color-coded embed messages to a Discord channel:

- **Green** -- Backup completed successfully (instance name, duration, file count, archive size)
- **Red** -- Backup failed (instance name, error message, suggested action)
- **Yellow** -- Warning (load deferral, skipped instance, non-fatal issue)
- **Blue** -- Restore completed (instance name, restore point, file count)

## Step 1: Create a Discord Webhook

You need a Discord server where you have permission to manage webhooks (you must be a server admin or have the "Manage Webhooks" permission).

1. Open Discord and go to the server where you want backup alerts.

2. Right-click on the channel where you want the notifications to appear (e.g., `#server-alerts` or `#backups`).

3. Click **Edit Channel**.

4. In the left sidebar, click **Integrations**.

5. Click **Webhooks**.

6. Click **New Webhook**.

7. Give it a name like `SEBackup` and optionally set an avatar.

8. Click **Copy Webhook URL**. The URL looks like this:
   ```
   https://discord.com/api/webhooks/1234567890123456789/abcdefghijklmnop-QRSTUVWXYZ_1234567890
   ```

9. Click **Save Changes**.

*Screenshots will be added here in a future update.*

## Step 2: Configure SEBackup

Open `Config\global.toml` on your C&C machine and edit the `[notifications]` section:

```toml
[notifications]
# Turn on notifications
enabled = true

# Choose which events trigger a notification:
on_success = true    # Backup completed successfully
on_failure = true    # Backup failed (strongly recommended)
on_warning = true    # Non-fatal warnings

# Paste your Discord webhook URL here:
webhook_url = "https://discord.com/api/webhooks/1234567890123456789/abcdefghijklmnop-QRSTUVWXYZ_1234567890"

# Notification method (currently only Discord is supported)
method = "discord"
```

Save the file.

## Step 3: Test the Notification

Run a test to make sure it works:

```powershell
Import-Module .\SEBackup.psd1
Test-SEBNotificationConfig
```

This sends a test message to your Discord channel. If you see the message appear, everything is working.

If it does not work:
- Double-check the webhook URL (it must be the full URL, including `https://`)
- Make sure `enabled = true` in the config
- Check that the webhook has not been deleted in Discord
- Look at the SEBackup log for error details

## Step 4: You are Done

From now on, SEBackup will send notifications to your Discord channel based on the events you enabled. No further configuration is needed.

## Reducing Notification Noise

If you are running frequent backups (e.g., every 4-6 hours across multiple instances), success notifications can get noisy. Consider:

```toml
[notifications]
on_success = false   # Only notify on problems
on_failure = true    # Always know about failures
on_warning = true    # Know about load deferrals, skipped instances
```

This way you only hear from SEBackup when something needs your attention.

## Using a Separate Channel

We recommend creating a dedicated channel for backup notifications (e.g., `#backup-alerts`) rather than using a general-purpose channel. This keeps backup noise out of your main discussion channels and makes it easy to check backup status at a glance.

## Multiple Webhooks

SEBackup currently supports a single webhook URL. If you need notifications in multiple channels or servers, you can use a Discord bot or a webhook relay service to forward messages.

## Webhook Security

- Your webhook URL is stored in `global.toml` on the C&C machine in plaintext. Make sure only authorized users have access to the C&C machine and config files.
- If your webhook URL is compromised, anyone can send messages to your channel. Delete the webhook in Discord and create a new one.
- The `global.toml` file is listed in `.gitignore` to prevent accidental commits of webhook URLs to version control.

## Notification Message Format

SEBackup sends Discord embed messages with the following structure:

**Backup Success:**
```
SEBackup - Backup Complete
Instance:  PvPArena (GamePC01)
Type:      Incremental
Duration:  2m 34s
Files:     47 changed (3 added, 44 modified)
Size:      12.4 MB
Chain:     #7 of 48
```

**Backup Failure:**
```
SEBackup - Backup FAILED
Instance:  PvPArena (GamePC01)
Error:     VSS shadow copy creation failed: Insufficient storage
Action:    Check disk space on GamePC01 (C: drive)
```

**Warning:**
```
SEBackup - Warning
Instance:  PvPArena (GamePC01)
Warning:   Backup deferred - CPU at 92% (threshold: 80%)
Action:    Will retry in 60 seconds with backoff
```
