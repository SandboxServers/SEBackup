# C&C Server Setup Guide

This document covers how to set up the SEBackup Command & Control (C&C) server. The C&C server is the central machine that orchestrates backups across all your compute nodes.

## What is the C&C Server?

The C&C (Command & Control) server is the machine where SEBackup runs from. It:

- Stores the SEBackup code and configuration files
- Connects to your compute nodes via WinRM/PowerShell Remoting
- Triggers backup operations on remote nodes
- Receives completed backup archives from nodes
- Optionally forwards backups to a NAS for long-term storage
- Runs the scheduler for automatic backups
- Sends Discord notifications

The C&C does NOT need to be a powerful machine. It does not run game servers. A basic Windows PC or a small VM will work fine.

## Requirements

- **Operating System:** Windows 10, Windows 11, or Windows Server 2016+
- **PowerShell:** 7.0 or later
- **Network:** Must be able to reach all compute nodes on TCP port 5985 (WinRM HTTP)
- **Disk Space:** Enough to store your backup archives (depends on your world sizes and retention policy)
- **Administrator Access:** Required for initial setup

## Step 1: Install PowerShell 7

If you do not already have PowerShell 7 installed:

1. Go to https://aka.ms/powershell-release?tag=stable
2. Download the MSI installer for your system (usually `PowerShell-7.x.x-win-x64.msi`)
3. Run the installer and accept the defaults
4. When asked about PATH, make sure it is enabled

After installation, you can open "PowerShell 7" from the Start menu. It is a blue/black icon, separate from the older "Windows PowerShell" (which has a light blue icon).

> **How to tell which version you have:** Open a PowerShell window and type:
> ```powershell
> $PSVersionTable.PSVersion
> ```
> It should show 7.x.x.

## Step 2: Download SEBackup

Choose a location on the C&C machine. We recommend `C:\SEBackup\` for simplicity.

**With Git:**
```powershell
cd C:\
git clone https://github.com/SandboxServers/SEBackup.git
```

**Without Git:**
1. Download the ZIP from GitHub
2. Extract it to `C:\SEBackup\`

## Step 3: Run Install.ps1

Open PowerShell 7 **as Administrator** and run:

```powershell
cd C:\SEBackup
.\Install.ps1
```

The installer will:

1. **Check PowerShell version** -- Makes sure you have 7.0+.
2. **Install PSToml** -- The TOML configuration parser. This is required and installs automatically from the PowerShell Gallery.
3. **Offer to install 7Zip4Powershell** -- Optional module for faster compression. If you skip it, SEBackup will use the built-in .NET compression, which is slightly slower but works fine.
4. **Create directories** -- Sets up `Config/nodes/`, `Credentials/`, `Logs/`, `Data/lockfiles/`.
5. **Copy example configs** -- Creates `Config/global.toml` from the example if it does not already exist.
6. **Test WinRM** -- Checks if the WinRM service is running and if TrustedHosts is configured.

If you see any red "FAIL" messages, address them before proceeding. Yellow "WARNING" messages are informational and usually not blockers.

## Step 4: Configure global.toml

Open `Config\global.toml` in a text editor:

```powershell
notepad Config\global.toml
```

### Essential Settings

At minimum, review and set these:

```toml
[storage]
# Where backups will be stored locally. Make sure this path exists and
# the drive has plenty of free space.
cc_backup_root = "C:\\SEBackup\\Backups"

# Optional NAS path. Leave empty if you don't have one.
nas_backup_path = ""
```

### Settings You Might Want to Change

```toml
[schedule]
# How often to run incremental backups.
# 6 = every 6 hours (4 times a day). Good for active servers.
# 12 = every 12 hours (twice a day). Good for low-activity servers.
interval_hours = 6

[notifications]
# Set to true and add a webhook URL to get Discord alerts.
enabled = false
webhook_url = ""
```

See [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) for every setting explained.

## Step 5: Configure WinRM

The C&C needs to be able to connect to your compute nodes via PowerShell Remoting (WinRM).

### Start the WinRM Service

```powershell
Start-Service WinRM
Set-Service WinRM -StartupType Automatic
```

### Add Compute Nodes to TrustedHosts

If your machines are NOT on an Active Directory domain (most home setups), you need to explicitly trust each compute node:

```powershell
# Single node:
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101" -Force

# Multiple nodes (comma-separated):
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101,192.168.1.102,192.168.1.103" -Force

# Or trust all machines on your subnet (less secure but convenient):
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.*" -Force
```

### Verify Connectivity

Test that you can reach a compute node:

```powershell
Test-WSMan -ComputerName 192.168.1.101
```

If this fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for WinRM debugging steps.

## Step 6: Ensure NAS Access (Optional)

If you configured a `nas_backup_path` in `global.toml`, make sure the C&C machine can access it:

```powershell
# Test access to a UNC path:
Test-Path "\\NAS01\Backups\SpaceEngineers"

# Or test a mapped drive:
Test-Path "Z:\SEBackups"
```

If the NAS requires authentication, you may need to save credentials:

```powershell
# Map a network drive with credentials (persists across reboots):
New-PSDrive -Name Z -PSProvider FileSystem -Root "\\NAS01\Backups" -Credential (Get-Credential) -Persist
```

## What is Next?

Your C&C server is ready. Now you need to set up your compute nodes:

- [Setting up Compute Nodes](SETUP-NODE.md)
- [Registering Torch Instances](SETUP-INSTANCE.md)
- [Running Your First Backup](QUICKSTART.md#step-6-run-your-first-backup)
