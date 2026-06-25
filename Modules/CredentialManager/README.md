# CredentialManager Module

Credential storage for WinRM/PSRemoting authentication. Node passwords are encrypted with the Windows Data Protection API (DPAPI) using **LocalMachine scope** plus per-machine entropy, and the credential files are locked down with a restrictive ACL. Because the protection is bound to the **machine** (not to the saving user), unattended scheduled tasks on the same C&C host — including S4U "run whether logged on or not" tasks — can decrypt the credentials and authenticate. See [docs/UNATTENDED-AUTH.md](../../docs/UNATTENDED-AUTH.md) for the full design, ACL model, and rotation guidance.

> Credentials are stored in the protected `Credentials/{NodeName}.cred` format. Credentials saved by the older `Export-Clixml` `.cred.xml` format are migrated automatically the first time they are read, if the current account can read them.

## Exported Functions

### Save-SEBCredential

Prompts for credentials (if not supplied) and saves them for the specified compute node as a LocalMachine-DPAPI protected `.cred` file with a hardened ACL.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node to store credentials for. |
| Credential | PSCredential | No | prompted | A PSCredential object. If not provided, the user is prompted via `Get-Credential`. |

**Output:** None. The credential is written to `Credentials/{NodeName}.cred`.

```powershell
Save-SEBCredential -NodeName "GameServer01"
Save-SEBCredential -NodeName "GameServer01" -Credential $cred
```

### Get-SEBCredential

Retrieves a previously saved LocalMachine-DPAPI protected credential for a compute node.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The name of the compute node whose credential to retrieve. |

**Output:** `PSCredential` -- the decrypted credential. Throws if the credential is missing or cannot be decrypted on this host.

```powershell
$cred = Get-SEBCredential -NodeName "GameServer01"
Write-Host "Username: $($cred.UserName)"
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

**Output:** `System.Boolean` -- `$true` only if a protected, machine-decryptable `.cred` exists; `$false` if missing, undecryptable, or legacy-only (re-save required).

```powershell
if (Test-SEBCredential -NodeName "GameServer01") {
    Write-Host "Credentials are configured."
}
```

### Update-SEBCredential

Rotates / re-encrypts a node's stored credential through the current protection backend and re-applies the ACL. With no `-Credential`, the existing credential is re-encrypted in place (username + password preserved); with `-Credential`, the stored secret is replaced. Supports `-WhatIf` / `-Confirm`.

| Parameter | Type | Required | Default | Description |
|-----------|------|:--------:|---------|-------------|
| NodeName | string | Yes | -- | The node whose credential to rotate. |
| Credential | PSCredential | No | existing | Replacement credential. If omitted, the existing credential is re-encrypted in place. |

**Output:** None. The credential is re-written to disk.

```powershell
Update-SEBCredential -NodeName "GameServer01"                    # re-encrypt in place
Update-SEBCredential -NodeName "GameServer01" -Credential $new   # replace the secret
```

## Private Functions

| Function | Purpose |
|----------|---------|
| `Resolve-CredentialPath` | Computes the credential file path for a node: `Credentials/{NodeName}.cred` (or `.cred.xml` with `-Legacy`). Validates the node name against path traversal. |
| `Protect-SEBSecret` / `Unprotect-SEBSecret` | The backend seam: wrap LocalMachine-scope DPAPI Protect/Unprotect with per-machine entropy. A future gMSA/certificate/SecretManagement backend replaces only these. |
| `Get-SEBSecretEntropy` | Derives stable per-machine entropy (SHA-256 of an app salt + `MachineGuid`) for the DPAPI `optionalEntropy`. |
| `ConvertTo-SEBProtectedCredential` / `ConvertFrom-SEBProtectedCredential` | Serialize a PSCredential to / from the protected JSON envelope. |
| `Write-SEBProtectedCredentialFile` | The single write path: envelope → JSON file → restrictive ACL. |
| `Set-SEBCredentialAcl` | Locks down the file/dir to SYSTEM + Administrators + the saving account; removes inherited/`Users` access. Idempotent. |
| `Convert-SEBLegacyCredential` | Best-effort migration of a legacy `.cred.xml` to the new format. |
| `Test-SEBProtectedCredentialReadBack` | Round-trip-verifies a just-written `.cred` decrypts on this host (and matches an expected credential) before any destructive legacy delete. |

## Dependencies

None beyond the in-box .NET `System.Security.Cryptography.ProtectedData` (present in PowerShell 7 on Windows) and `System.Security.AccessControl`. No new module dependencies.

## Important Notes

- Node passwords are protected with **LocalMachine-scope DPAPI** — bound to the **machine**, not the saving user — so unattended (S4U) scheduled tasks on the same host can decrypt them. A `.cred` file copied to a different machine will **not** decrypt there (different DPAPI master key and different per-machine entropy).
- Credential files are stored at `Credentials/{NodeName}.cred` relative to the project root and are ACL-restricted to SYSTEM, Administrators, and the saving account.
- **Never** store plaintext passwords in config files, scripts, or logs. Only the DPAPI ciphertext (Base64) is written to disk.

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
