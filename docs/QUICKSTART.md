# SEBackup Quick Start Guide

This guide takes you from "I just downloaded this" to "my first backup is done" in about 15-20 minutes.

## What You Need Before Starting

Before you begin, make sure you have these things ready:

1. **A Windows PC or server** that will act as your "Command & Control" (C&C) machine. This is where SEBackup runs and where backups are stored. It does NOT need to be the same machine running your game servers.

2. **At least one Windows PC or server** running Space Engineers via Torch. This is your "compute node." It can be the same machine as the C&C if you only have one server.

3. **Administrator access** to all machines involved.

4. **Network connectivity** between the C&C and all compute nodes. They need to be able to talk to each other over the local network.

5. **PowerShell 7** installed on ALL machines (C&C and every compute node).

> **Don't have PowerShell 7?** Download it here: https://aka.ms/powershell-release?tag=stable
>
> Run the MSI installer and accept defaults. When it asks about PATH, say yes. When it is done, you can open "PowerShell 7" from the Start menu. It is a separate program from "Windows PowerShell" (version 5.1) that comes with Windows.

## Step 1: Download SEBackup

On your **C&C machine**, pick a location for the SEBackup project. We recommend `C:\SEBackup\` but it can go anywhere.

**Option A: Clone with Git (if you have Git installed)**
```powershell
cd C:\
git clone https://github.com/SandboxServers/SEBackup.git
cd SEBackup
```

**Option B: Download ZIP**
1. Go to https://github.com/SandboxServers/SEBackup
2. Click the green "Code" button, then "Download ZIP"
3. Extract the ZIP to `C:\SEBackup\`
4. Open PowerShell 7 and navigate there:
```powershell
cd C:\SEBackup
```

## Step 2: Run the Installer on the C&C Machine

Open **PowerShell 7 as Administrator** (right-click, "Run as Administrator") and run:

```powershell
cd C:\SEBackup
.\Install.ps1
```

This script will:
- Verify you have PowerShell 7
- Install the PSToml module (used for reading config files)
- Optionally install 7Zip4Powershell (for faster compression)
- Create required directories (`Config/nodes/`, `Credentials/`, `Logs/`, `Data/lockfiles/`)
- Copy example config files
- Check that WinRM is working

Watch for any red "FAIL" messages. If everything shows green "OK," you are good to proceed.

> **Troubleshooting:** If you get an error about "running scripts is disabled," run this first:
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```

## Step 3: Edit the Global Configuration

Open the global config file in your favorite text editor:

```powershell
notepad Config\global.toml
```

The most important settings to change right now are:

### Storage Paths

```toml
[storage]
# Where backups will be stored on the C&C machine.
# Make sure this drive has enough free space (at least 2x your world sizes).
cc_backup_root = "C:\\SEBackup\\Backups"

# Optional: UNC path to a NAS for long-term storage.
# Leave empty if you don't have a NAS.
nas_backup_path = ""
```

### Schedule (optional, can change later)

```toml
[schedule]
# How often to run incremental backups (hours).
# 6 hours is a good default.
interval_hours = 6
```

Save and close the file. You can fine-tune other settings later. See [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) for the full list.

## Step 4: Set Up Each Compute Node

For each machine running Torch servers, you need to:

### 4a. Enable PowerShell Remoting on the Compute Node

Log into the **compute node** (the machine running your Torch server), open **PowerShell 7 as Administrator**, and run:

```powershell
Enable-PSRemoting -Force
```

This allows the C&C machine to connect remotely.

### 4b. Allow the C&C to Connect

Still on the **compute node**, if the C&C and compute node are NOT on the same Active Directory domain (most home/small setups are not), you need to also run:

```powershell
# No special steps needed on the node for TrustedHosts.
# But you DO need to open the firewall for WinRM if it isn't already:
Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC"
```

Now go back to the **C&C machine** and tell it to trust the compute node:

```powershell
# Replace with your compute node's IP address or hostname
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101" -Force
```

If you have multiple nodes, separate them with commas:
```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101,192.168.1.102" -Force
```

### 4c. Run the Node Setup Script

On the **C&C machine**, run:

```powershell
.\Scripts\Setup-Node.ps1 -NodeName "GamePC01" -Hostname "192.168.1.101"
```

Replace `GamePC01` with a short, friendly name for this machine (no spaces, letters and numbers only). Replace `192.168.1.101` with the actual IP address or hostname of the compute node.

The script will:
- Ask you for the administrator username and password for that node
- Save the credentials securely (encrypted with DPAPI)
- Create a node config file in `Config/nodes/GamePC01.toml`
- Connect to the node and install the SEBackup NodeAgent
- Create the required directories on the node

> **Troubleshooting:** If the connection fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for WinRM help.

## Step 5: Register Each Torch Server Instance

For each Torch server running on a compute node, you need to register it with SEBackup.

On the **C&C machine**, run:

```powershell
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "PvPArena"
```

Replace `GamePC01` with the node name from step 4. Replace `PvPArena` with a short name for this Torch server instance (no spaces).

The script will ask you for:
- **Torch install path** -- Where Torch.Server.exe lives on the compute node (e.g., `C:\TorchServers\PvPArena`)
- **World save path** -- Where the world save data is (the script can usually find this automatically)
- **VRage API port** -- The remote API port configured in Torch (default: 8080)
- **VRage API key** -- The security key from your Torch server's `SpaceEngineers-Dedicated.cfg`

> **Where to find the VRage API key:** On the compute node, open the file:
> `{TorchInstallPath}\Instance\SpaceEngineers-Dedicated.cfg`
>
> Look for the line:
> ```xml
> <RemoteApiKey>YourKeyHere</RemoteApiKey>
> ```
>
> If there is no key or it is empty, you can set one to any string (like `MyBackupKey`), save the file, and restart Torch.

## Step 6: Run Your First Backup

On the **C&C machine**, run:

```powershell
.\Scripts\Invoke-Backup.ps1 -All
```

This will:
1. Connect to each registered compute node
2. Trigger a VRage API world save on each Torch instance
3. Create a VSS shadow copy on the node
4. Generate file manifests
5. Compress and transfer the backup to the C&C
6. Verify the backup integrity
7. Optionally copy to NAS

The first backup is always a **full backup** (all files). Subsequent runs will be **incremental** (only changed files), which will be much faster.

Watch the colored output:
- **Cyan** = informational progress messages
- **Yellow** = warnings (usually non-fatal)
- **Red** = errors (something failed)
- **Green** = success

## Step 7 (Optional): Set Up Scheduled Backups

To have SEBackup run automatically on a schedule:

```powershell
.\Scripts\Register-Schedule.ps1 -Action Register
```

This creates a Windows Scheduled Task that runs backups at the interval specified in your `global.toml` (default: every 6 hours).

To check the schedule status:
```powershell
.\Scripts\Register-Schedule.ps1 -Action Status
```

To remove the scheduled task:
```powershell
.\Scripts\Register-Schedule.ps1 -Action Unregister
```

## Step 8 (Optional): Set Up Discord Notifications

If you want backup status alerts in Discord:

1. Create a Discord webhook URL (see [DISCORD-SETUP.md](DISCORD-SETUP.md))
2. Edit `Config\global.toml`:
```toml
[notifications]
enabled     = true
on_success  = true
on_failure  = true
on_warning  = true
webhook_url = "https://discord.com/api/webhooks/YOUR/WEBHOOK/URL"
method      = "discord"
```

## You Are Done

Your backups are now configured and running. Here are some things you might want to do next:

- **Check backup history:** Look in your `cc_backup_root` directory (default: `C:\SEBackup\Backups\`)
- **Read the logs:** Check `Logs\SEBackup_YYYY-MM-DD.log` for detailed operation logs
- **Learn about restoring:** See [BACKUP-RESTORE.md](BACKUP-RESTORE.md)
- **Tune your settings:** See [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md)
- **Having problems?** See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
