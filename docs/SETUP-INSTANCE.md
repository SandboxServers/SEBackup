# Instance Registration Guide

This document covers how to register a Space Engineers Torch server instance with SEBackup so it can be backed up.

## What is an Instance?

An "instance" is a single Space Engineers Torch server running on a compute node. One compute node can run multiple instances (for example, a PvP arena server and a PvE survival server on the same machine).

Each instance has its own:
- Torch installation directory
- World save data
- VRage Remote API port and key
- SEBackup configuration file

## Prerequisites

Before registering an instance, you must have:

1. **C&C server set up** -- `Install.ps1` completed (see [SETUP-CC.md](SETUP-CC.md))
2. **Compute node set up** -- `Setup-Node.ps1` completed for this node (see [SETUP-NODE.md](SETUP-NODE.md))
3. **Torch server installed and running** -- The instance must exist on the compute node
4. **VRage Remote API enabled** -- Torch must have the Remote API configured

### Enabling the VRage Remote API in Torch

The VRage Remote API is how SEBackup tells the game server to save the world before taking a backup snapshot.

1. On the compute node, open your Torch server's configuration file:
   `{TorchInstallPath}\Instance\SpaceEngineers-Dedicated.cfg`

2. Find or add these lines:
   ```xml
   <RemoteApiEnabled>true</RemoteApiEnabled>
   <RemoteApiPort>8080</RemoteApiPort>
   <RemoteApiKey>YourSecretKeyHere</RemoteApiKey>
   ```

3. Set `RemoteApiKey` to any string you choose (e.g., `MyBackupKey2026`). Remember this key -- you will need it during registration.

4. Make sure the port (default 8080) is not used by another instance. If you run multiple instances on the same machine, each needs a unique port (e.g., 8080, 8081, 8082).

5. Restart the Torch server for the changes to take effect.

## Step 1: Run Register-Instance.ps1

On the **C&C machine**, open **PowerShell 7 as Administrator** and run:

```powershell
cd C:\SEBackup
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "PvPArena"
```

### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-NodeName` | The node name used when running `Setup-Node.ps1`. Must match an existing node config. | `GamePC01` |
| `-InstanceName` | A short, unique name for this Torch instance. Letters, numbers, underscores only. No spaces. | `PvPArena` |

### What the Script Asks For

The script will prompt you for information about this Torch instance:

1. **Torch install path** -- The full path on the compute node where Torch is installed.
   Example: `C:\TorchServers\PvPArena`

2. **World save path** -- The full path to the world save data on the compute node. The script will try to detect this automatically based on the Torch install path. If it cannot find it, you will need to provide it manually.
   Example: `C:\TorchServers\PvPArena\Instance\Saves\PvPWorld`

3. **VRage API port** -- The TCP port for the Remote API (default: 8080).

4. **VRage API key** -- The `RemoteApiKey` value from `SpaceEngineers-Dedicated.cfg`.

## What the Script Does

1. **Creates the instance config** -- Generates a TOML config file at `C:\SEBackup\instances\PvPArena.toml` on the compute node.

2. **Tests the VRage API connection** -- Attempts to connect to the VRage Remote API on the compute node to verify the port and key are correct.

3. **Creates an SMB share** -- Sets up a hidden network share (e.g., `SEBackup_PvPArena$`) on the compute node's staging directory. This share is used by the C&C to pull backup archives from the node.

4. **Creates the staging directory** -- Ensures `C:\SEBackup\staging\PvPArena\` exists on the compute node.

5. **Runs a test backup** -- Optionally performs a quick test to make sure the full backup pipeline works for this instance.

## Verifying the Setup

After registration, you can verify everything is working:

### Check the Instance Config

On the **C&C machine**:
```powershell
Import-Module .\SEBackup.psd1
$config = Get-SEBInstanceConfig -NodeName "GamePC01" -InstanceName "PvPArena"
$config
```

This should display the full merged configuration for the instance.

### Test the VRage API

```powershell
Test-SEBVRageAPI -NodeName "GamePC01" -InstanceName "PvPArena"
```

If successful, this confirms the C&C can reach the VRage API and authenticate.

### Test the SMB Share

```powershell
Test-SEBShare -NodeName "GamePC01" -InstanceName "PvPArena"
```

This checks that the staging share is accessible from the C&C.

### Test the Full Connection

```powershell
Test-SEBConnection -NodeName "GamePC01"
```

This performs a comprehensive connectivity check to the node.

## Multiple Instances on the Same Node

If you have multiple Torch servers on the same compute node, register each one separately:

```powershell
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "PvPArena"
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "Survival"
.\Scripts\Register-Instance.ps1 -NodeName "GamePC01" -InstanceName "Creative"
```

Each instance must have:
- A unique `-InstanceName`
- A unique VRage API port (8080, 8081, 8082, etc.)
- Its own Torch installation directory

## Troubleshooting

### "VRage API connection failed"

- Make sure the Torch server is running
- Verify the port number matches what is in `SpaceEngineers-Dedicated.cfg`
- Check that the port is not blocked by a firewall on the compute node:
  ```powershell
  # On the compute node, allow the API port:
  New-NetFirewallRule -Name "VRageAPI-8080" -DisplayName "VRage Remote API" -Protocol TCP -LocalPort 8080 -Action Allow -Direction Inbound
  ```
- Verify the API key matches exactly (case-sensitive)

### "VRage API authentication failed"

- The API key you provided does not match the one in the Torch config
- Open `{TorchInstallPath}\Instance\SpaceEngineers-Dedicated.cfg` and check the `<RemoteApiKey>` value
- Make sure you restart Torch after changing the key

### "Could not create SMB share"

- The SEBackup service account may not have permission to create shares
- Make sure the account is in the Administrators group on the compute node
- Try creating the share manually on the compute node:
  ```powershell
  New-SmbShare -Name "SEBackup_PvPArena$" -Path "C:\SEBackup\staging\PvPArena" -FullAccess "Administrators"
  ```

### "World save path not found"

- The Torch server may not have been started yet (no world save created)
- Start the Torch server, load a world, and then run `Register-Instance.ps1` again
- Or provide the world path manually when prompted

## Disabling an Instance

To temporarily stop backing up an instance without removing its configuration, edit the instance config on the compute node:

```toml
[backup]
enabled = false
```

To re-enable it later, set `enabled = true`.

## What is Next?

After registering all your instances, you are ready to run your first backup:

- [Running Your First Backup](QUICKSTART.md#step-6-run-your-first-backup)
- [Setting Up Scheduled Backups](QUICKSTART.md#step-7-optional-set-up-scheduled-backups)
