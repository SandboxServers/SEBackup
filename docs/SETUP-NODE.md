# Compute Node Setup Guide

This document covers how to prepare a compute node (a machine running Space Engineers Torch servers) to work with SEBackup.

## What is a Compute Node?

A "compute node" is any Windows machine that is running one or more Space Engineers dedicated servers via the Torch server wrapper. SEBackup connects to these machines remotely from the C&C server to perform backup operations.

Each compute node needs:
- PowerShell 7 installed
- WinRM/PowerShell Remoting enabled
- An administrator account that SEBackup can use
- The SEBackup NodeAgent (installed automatically by the setup script)

## Prerequisites

On the **compute node** (the machine running your Torch servers):

1. **Windows 10, 11, or Server 2016+**
2. **PowerShell 7** installed (https://aka.ms/powershell-release?tag=stable)
3. **Administrator access**
4. **Torch server** installed and running

On the **C&C machine:**

1. SEBackup installed and `Install.ps1` completed (see [SETUP-CC.md](SETUP-CC.md))
2. Network connectivity to the compute node (same LAN or VPN)

## Step 1: Prepare the Compute Node

Log into the **compute node** and open **PowerShell 7 as Administrator**.

### Enable PowerShell Remoting

```powershell
Enable-PSRemoting -Force
```

This command:
- Starts the WinRM service
- Sets the WinRM service to start automatically
- Creates a firewall rule allowing WinRM connections
- Configures the PowerShell session endpoint

### Verify the WinRM Service

```powershell
Get-Service WinRM
```

It should show `Status: Running`.

### Open the Firewall (if needed)

If your compute node has a third-party firewall (not just Windows Defender Firewall), make sure TCP port **5985** is open for inbound connections from the C&C machine's IP address.

For Windows Defender Firewall, `Enable-PSRemoting` should have created the rule. You can verify:

```powershell
Get-NetFirewallRule -Name "WINRM-HTTP-In-TCP*" | Format-Table Name, Enabled, Direction, Action
```

### Create a Dedicated Service Account (Recommended)

While you can use an existing admin account, we recommend creating a dedicated account for SEBackup:

```powershell
# Create a local user for SEBackup
$password = Read-Host "Enter password for SEBackup service account" -AsSecureString
New-LocalUser -Name "SEBackup" -Password $password -FullName "SEBackup Service" -Description "Used by SEBackup for remote backup operations"

# Add to Administrators group (required for VSS operations)
Add-LocalGroupMember -Group "Administrators" -Member "SEBackup"
```

> **Why Administrator?** SEBackup needs admin privileges on the compute node to create VSS shadow copies, access all Torch files, and manage SMB shares. A standard user account will not work.

## Step 2: Run Setup-Node.ps1 from the C&C

Go to the **C&C machine** and open **PowerShell 7 as Administrator**.

```powershell
cd C:\SEBackup
.\Scripts\Setup-Node.ps1 -NodeName "GamePC01" -Hostname "192.168.1.101"
```

### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-NodeName` | A short, friendly name for this node. Used as the identifier throughout SEBackup. Letters, numbers, and underscores only. No spaces. | `GamePC01` |
| `-Hostname` | The IP address or hostname of the compute node. Must be reachable from the C&C. | `192.168.1.101` or `gamingpc01.local` |

### What the Script Does

1. **Prompts for credentials** -- Asks you for the username and password of an administrator account on the compute node. These are saved encrypted in `Credentials/GamePC01.cred.xml` using DPAPI.

2. **Creates a node config file** -- Generates `Config/nodes/GamePC01.toml` with the node's hostname and connection details.

3. **Tests the connection** -- Attempts to establish a PSRemoting session to the compute node to verify everything works.

4. **Installs the NodeAgent** -- Copies the SEBackup NodeAgent to the compute node and runs `Install-NodeAgent.ps1`, which:
   - Creates `C:\SEBackup\instances\` on the node
   - Creates `C:\SEBackup\staging\` on the node
   - Creates `C:\SEBackup\logs\` on the node
   - Installs the PSToml module on the node (if not already present)
   - Checks for 7-Zip installation

5. **Prints a summary** -- Shows what was set up and any warnings.

## Troubleshooting Node Setup

### "Access is denied"

- Make sure the username you entered has Administrator privileges on the compute node
- Make sure the password is correct
- If the compute node is on a domain, use the format `DOMAIN\Username`

### "The WinRM client cannot process the request"

- Make sure WinRM is running on the compute node: `Get-Service WinRM`
- Make sure the C&C has the node in TrustedHosts:
  ```powershell
  # On the C&C:
  Get-Item WSMan:\localhost\Client\TrustedHosts
  ```
- If empty, add the node:
  ```powershell
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101" -Force
  ```

### "The connection to the remote host was refused"

- Firewall is blocking port 5985. On the compute node:
  ```powershell
  Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC"
  ```
- Or create the rule manually:
  ```powershell
  New-NetFirewallRule -Name "SEBackup-WinRM" -DisplayName "SEBackup WinRM" -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound
  ```

### "The network path was not found"

- The IP address or hostname is wrong, or the machine is offline
- Try pinging the node from the C&C: `Test-Connection 192.168.1.101`

### "PowerShell remoting is not enabled on the remote machine"

- Log into the compute node and run: `Enable-PSRemoting -Force`

### PSToml fails to install on the node

- The compute node may not have internet access. You can manually install PSToml:
  ```powershell
  # On a machine with internet, download PSToml:
  Save-Module -Name PSToml -Path C:\Temp\Modules
  # Copy the C:\Temp\Modules\PSToml folder to the compute node
  # Place it in: C:\Program Files\PowerShell\Modules\PSToml
  ```

## Multiple Nodes

Repeat Step 2 for each compute node, using a unique `-NodeName` for each:

```powershell
.\Scripts\Setup-Node.ps1 -NodeName "GamePC01" -Hostname "192.168.1.101"
.\Scripts\Setup-Node.ps1 -NodeName "GamePC02" -Hostname "192.168.1.102"
.\Scripts\Setup-Node.ps1 -NodeName "DediBox"  -Hostname "10.0.0.50"
```

## What is Next?

After setting up your compute nodes, register each Torch server instance:

- [Registering Torch Instances](SETUP-INSTANCE.md)
