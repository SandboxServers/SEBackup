# Troubleshooting

This document covers common problems and their solutions. If your problem is not listed here, check the log files in `Logs/SEBackup_YYYY-MM-DD.log` for detailed error messages.

---

## WinRM / PowerShell Remoting Issues

### Error: "The WinRM client cannot process the request"

**Cause:** The C&C cannot establish a PowerShell remoting session to the compute node.

**Solutions:**

1. Make sure WinRM is running on the compute node:
   ```powershell
   # On the compute node:
   Get-Service WinRM
   Start-Service WinRM
   ```

2. Make sure the compute node is in the C&C's TrustedHosts:
   ```powershell
   # On the C&C:
   Get-Item WSMan:\localhost\Client\TrustedHosts

   # If empty or missing the node, add it:
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.101" -Force
   ```

3. Make sure PowerShell Remoting is enabled on the compute node:
   ```powershell
   # On the compute node (as Administrator):
   Enable-PSRemoting -Force
   ```

### Error: "The connection to the remote host was refused" (port 5985)

**Cause:** The firewall on the compute node is blocking WinRM connections.

**Solutions:**

1. Check if the WinRM firewall rule exists and is enabled:
   ```powershell
   # On the compute node:
   Get-NetFirewallRule -Name "WINRM-HTTP-In-TCP*" | Format-Table Name, Enabled
   ```

2. If the rule does not exist or is disabled:
   ```powershell
   # Enable existing rule:
   Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC"

   # Or create a new rule:
   New-NetFirewallRule -Name "SEBackup-WinRM" -DisplayName "SEBackup WinRM Inbound" `
       -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound
   ```

3. If using a third-party firewall (e.g., ESET, Kaspersky, Bitdefender), you need to create a rule in that firewall's interface to allow TCP 5985 inbound.

### Error: "Access is denied"

**Cause:** The username or password is wrong, or the account does not have Administrator privileges.

**Solutions:**

1. Verify the credentials are correct by testing manually:
   ```powershell
   # On the C&C:
   $cred = Get-Credential
   Test-WSMan -ComputerName 192.168.1.101 -Credential $cred
   ```

2. Make sure the account is in the Administrators group on the compute node:
   ```powershell
   # On the compute node:
   Get-LocalGroupMember -Group "Administrators"
   ```

3. Re-save the credentials:
   ```powershell
   # On the C&C:
   Save-SEBCredential -NodeName "GamePC01"
   ```

### Error: "The network path was not found"

**Cause:** The C&C cannot reach the compute node on the network.

**Solutions:**

1. Ping the compute node from the C&C:
   ```powershell
   Test-Connection -ComputerName 192.168.1.101 -Count 4
   ```

2. If ping fails:
   - Verify the IP address is correct
   - Check that both machines are on the same network/VPN
   - Check for firewall rules blocking ICMP or all traffic

3. If ping works but WinRM does not, it is a firewall or WinRM configuration issue (see above).

### Error: "Connecting to remote server failed with the following error message: The client cannot connect to the destination specified in the request"

**Cause:** This usually means PowerShell 7 is not configured for remoting on the node, even though Windows PowerShell 5.1 might be.

**Solution:**
```powershell
# On the compute node, in PowerShell 7 (not Windows PowerShell):
Enable-PSRemoting -Force
```

PowerShell 7 has its own session endpoint that is separate from Windows PowerShell's.

---

## VSS (Volume Shadow Copy) Issues

### Error: "The Volume Shadow Copy Service is not running"

**Cause:** The VSS service is stopped or disabled on the compute node.

**Solution:**
```powershell
# On the compute node:
Start-Service VSS
Set-Service VSS -StartupType Manual
```

The VSS service runs on-demand (start type "Manual" is correct). It starts when a shadow copy is requested and stops after.

### Error: "Insufficient storage available to create shadow copy"

**Cause:** Not enough free space on the volume for the VSS shadow copy.

**Solutions:**

1. Free up disk space on the volume where game data lives.

2. Check how much space existing shadow copies are using:
   ```powershell
   # On the compute node:
   vssadmin list shadowstorage
   ```

3. Increase the shadow storage limit:
   ```powershell
   vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10GB
   ```

4. Delete old orphaned shadow copies:
   ```powershell
   vssadmin delete shadows /for=C: /oldest
   ```

### Error: "VSS shadow copy creation timed out"

**Cause:** Another application (antivirus, Windows Update, SQL Server) is holding a VSS writer lock.

**Solutions:**

1. Check VSS writer status:
   ```powershell
   # On the compute node:
   vssadmin list writers
   ```
   Look for writers in "Failed" or "Waiting for completion" state.

2. Restart the VSS service:
   ```powershell
   Restart-Service VSS
   ```

3. If a specific writer is stuck, restart the service it belongs to (e.g., restart the Windows Search service if the "Search" writer is stuck).

### Orphaned Shadow Copies

If SEBackup crashes or is interrupted during a backup, shadow copies may be left behind. These consume disk space.

**Solution:**
```powershell
Import-Module .\SEBackup.psd1
Clear-SEBOrphanShadowCopies -NodeName "GamePC01"
```

Or manually on the compute node:
```powershell
vssadmin list shadows
vssadmin delete shadows /shadow={shadow-copy-id}
```

---

## VRage Remote API Issues

### Error: "VRage API connection failed" or "Connection refused"

**Cause:** The VRage Remote API is not running or is on a different port.

**Solutions:**

1. Make sure the Torch server is running.

2. Verify the API port in the Torch config:
   ```
   {TorchInstallPath}\Instance\SpaceEngineers-Dedicated.cfg
   ```
   Look for `<RemoteApiPort>8080</RemoteApiPort>`.

3. Make sure the API is enabled:
   ```xml
   <RemoteApiEnabled>true</RemoteApiEnabled>
   ```

4. Check that the port is not blocked by a firewall:
   ```powershell
   # On the compute node:
   Test-NetConnection -ComputerName localhost -Port 8080
   ```

5. If the port is in use by another application, change the Torch port to something else and update the instance config.

### Error: "VRage API authentication failed" (401/403)

**Cause:** The API key in the SEBackup instance config does not match the key in the Torch server config.

**Solutions:**

1. Check the key in the Torch server config:
   ```
   {TorchInstallPath}\Instance\SpaceEngineers-Dedicated.cfg
   ```
   Look for `<RemoteApiKey>`.

2. Compare it with the key in the SEBackup instance config:
   ```
   C:\SEBackup\instances\{instance}.toml
   ```
   Under `[vrage_api]`, `security_key = "..."`.

3. The keys must match exactly (they are case-sensitive).

4. If you change the key in the Torch config, restart the Torch server.

### Error: "World save timed out"

**Cause:** The world save took longer than the configured timeout.

**Solutions:**

1. Increase the timeout in the instance config:
   ```toml
   [vrage_api]
   save_timeout_seconds = 300
   ```

2. Very large worlds (1GB+ save files) may need 300-600 seconds.

3. Check if the server is experiencing performance issues (low sim speed). Saving is slower when the server is lagging.

---

## SMB Share Issues

### Error: "Share access denied" or "The network path was not found"

**Cause:** The C&C cannot access the SMB share on the compute node.

**Solutions:**

1. Verify the share exists on the compute node:
   ```powershell
   # On the compute node:
   Get-SmbShare -Name "SEBackup_PvPArena$"
   ```

2. Check share permissions:
   ```powershell
   Get-SmbShareAccess -Name "SEBackup_PvPArena$"
   ```
   The SEBackup service account should have Full Access.

3. Test from the C&C:
   ```powershell
   # Using the SEBackup credential:
   $cred = Get-SEBCredential -NodeName "GamePC01"
   Test-Path "\\192.168.1.101\SEBackup_PvPArena$" -Credential $cred
   ```

4. Recreate the share:
   ```powershell
   # On the compute node:
   New-SmbShare -Name "SEBackup_PvPArena$" -Path "C:\SEBackup\staging\PvPArena" -FullAccess "Administrators"
   ```

---

## BITS Transfer Issues

### Error: "BITS service is not running"

**Cause:** The Background Intelligent Transfer Service is stopped.

**Solution:**
```powershell
Start-Service BITS
Set-Service BITS -StartupType Automatic
```

### Error: "BITS transfer failed"

**Cause:** Various -- network interruption, disk full, permissions.

**Solutions:**

1. SEBackup automatically falls back to robocopy or Copy-Item if BITS fails.

2. Check the BITS job queue for stuck jobs:
   ```powershell
   Get-BitsTransfer -AllUsers
   ```

3. Clear stuck jobs:
   ```powershell
   Get-BitsTransfer -AllUsers | Remove-BitsTransfer
   ```

---

## Compression Issues

### Error: "7-Zip not found"

**Cause:** 7-Zip is not installed on the compute node and the compression engine is set to `"7zip"`.

**Solutions:**

1. Install 7-Zip on the compute node: https://www.7-zip.org/download.html

2. Or change the compression engine in `global.toml`:
   ```toml
   [compression]
   engine = "auto"    # Falls back to .NET if 7-Zip is missing
   # or
   engine = "dotnet"  # Always uses .NET compression
   ```

### Error: "Compression failed: out of memory"

**Cause:** The compression level is too high for the available memory, or the archive is very large.

**Solution:** Lower the compression level:
```toml
[compression]
level_7zip = 3   # Lower = less memory, faster, larger output
```

---

## Credential Issues

### Error: "Credential file not found"

**Cause:** The DPAPI credential file for the node does not exist.

**Solution:**
```powershell
Save-SEBCredential -NodeName "GamePC01"
```

### Error: credential "could not be decrypted" / "re-save it on THIS host"

**Cause:** Node credentials are protected with **LocalMachine-scope DPAPI** — bound to the **machine**, not the user (see [UNATTENDED-AUTH.md](UNATTENDED-AUTH.md)). They decrypt for any process (including an unattended scheduled task) on the **same C&C host**, but a `.cred` file copied from a **different machine** cannot be decrypted (different DPAPI master key and per-machine entropy).

**Solution:** Re-save (or rotate) the credentials on the host where SEBackup runs:
```powershell
Save-SEBCredential -NodeName "GamePC01"
# or, to rotate/re-encrypt:
Update-SEBCredential -NodeName "GamePC01"
```

Unlike the old behavior, you do **not** need to save credentials as the same user the scheduled task runs as — machine-scope protection means the S4U "run whether logged on or not" task decrypts them regardless, as long as it runs on the same host and the running account is an Administrator. If you moved the C&C to a new machine, re-save there.

### Warning: "legacy credential … could not be read" / "re-save required"

**Cause:** A credential saved by the older `Export-Clixml` (`.cred.xml`) format is sealed with **CurrentUser**-scope DPAPI and can only be read by the user who saved it. SEBackup migrates such files to the new machine-scoped format automatically **when the current account can read them**; if it cannot (e.g. it was saved by a different user), the legacy file is left in place and flagged.

**Solution:** Re-save the credential on this host so it is stored in the machine-readable protected format:
```powershell
Save-SEBCredential -NodeName "GamePC01"
```

---

## General Issues

### Nothing happens when I run a backup

1. Check if any instances are registered:
   ```powershell
   Get-SEBAllInstanceConfigs
   ```

2. Check if instances are enabled:
   ```powershell
   # In the instance config:
   # [backup]
   # enabled = true
   ```

3. Check the log file for errors:
   ```powershell
   Get-Content "Logs\SEBackup_$(Get-Date -Format 'yyyy-MM-dd').log" -Tail 50
   ```

### Backups are very slow

1. Check network bandwidth settings:
   ```toml
   [network]
   max_bandwidth_mbps = 0   # 0 = unlimited, try this first
   robocopy_ipg_ms = 0
   ```

2. Use 7-Zip instead of .NET compression (faster for large worlds):
   ```toml
   [compression]
   engine = "7zip"
   level_7zip = 3   # Lower level = faster
   ```

3. Check if the compute node is overloaded (high CPU/memory preventing the backup from running efficiently).

### Log files are getting huge

SEBackup automatically rotates log files daily and cleans up files older than 30 days. If logs are growing too fast, reduce the log verbosity by avoiding `-Verbose` flags in scripts.
