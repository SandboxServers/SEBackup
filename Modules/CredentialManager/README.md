# CredentialManager Module

DPAPI-encrypted credential storage for WinRM/PSRemoting authentication. Credentials are encrypted using Windows Data Protection API and are bound to the user and machine that created them.

## Exported Functions

### Save-SEBCredential

Prompts for credentials and saves them as a DPAPI-encrypted XML file for the specified compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node to store credentials for. |
| Credential | PSCredential | No | prompted | A PSCredential object. If not provided, the user is prompted via `Get-Credential`. |

**Output:** `System.String` -- the path to the saved credential file.

```powershell
Save-SEBCredential -NodeName "GameServer01"
Save-SEBCredential -NodeName "GameServer01" -Credential $cred
```

### Get-SEBCredential

Retrieves a previously saved DPAPI-encrypted credential for a compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node whose credential to retrieve. |

**Output:** `PSCredential` -- the decrypted credential object, or `$null` if not found.

```powershell
$cred = Get-SEBCredential -NodeName "GameServer01"
if ($null -ne $cred) {
    Write-Host "Username: $($cred.UserName)"
}
```

### Remove-SEBCredential

Deletes the stored credential file for a compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node whose credential to remove. |

**Output:** `System.Boolean` -- `$true` if the credential file was removed or did not exist.

```powershell
Remove-SEBCredential -NodeName "GameServer01"
```

### Test-SEBCredential

Tests whether a valid credential file exists for the specified compute node and can be decrypted.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node to test. |

**Output:** `System.Boolean` -- `$true` if a valid credential file exists and is decryptable.

```powershell
if (Test-SEBCredential -NodeName "GameServer01") {
    Write-Host "Credentials are configured."
}
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Resolve-CredentialPath` | Computes the full path to the credential XML file for a given node name: `Credentials/{NodeName}.cred.xml`. |

## Dependencies

None. Uses built-in PowerShell `Export-Clixml` / `Import-Clixml` for DPAPI encryption.

## Important Notes

- DPAPI credentials are **machine-and-user bound**. They can only be decrypted by the same Windows user on the same machine that created them.
- Credential files are stored at `Credentials/{NodeName}.cred.xml` relative to the project root.
- **Never** store plaintext passwords in config files, scripts, or logs.

## Usage Scenarios

**Scenario 1: Initial node setup -- saving credentials**
```powershell
# Prompts for username and password, saves encrypted
Save-SEBCredential -NodeName "GameServer01"
```

**Scenario 2: Automated credential retrieval for remote sessions**
```powershell
$cred = Get-SEBCredential -NodeName "GameServer01"
$session = New-PSSession -ComputerName "192.168.1.101" -Credential $cred
```

**Scenario 3: Verifying credentials are configured for all nodes**
```powershell
$nodes = Get-SEBNodeConfig -All
foreach ($node in $nodes) {
    $name = $node['_NodeName']
    $ok = Test-SEBCredential -NodeName $name
    Write-Host "${name}: $(if ($ok) { 'OK' } else { 'MISSING' })"
}
```
