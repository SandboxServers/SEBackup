# Unattended Authentication and Credential Security

This document explains how SEBackup stores the per-node credentials it uses to
connect to compute nodes, and why that storage works for **unattended scheduled
backups** (the core product value). It also covers the file-permission model and
credential rotation.

It is the supported answer to issue #27: *"DPAPI `Export-Clixml` binds the
encrypted node credential to the saving user+machine, so an S4U scheduled task
cannot decrypt it."*

## TL;DR

- Node credentials are encrypted with **LocalMachine-scope DPAPI** (Windows Data
  Protection API), not user-scope. They are bound to the **C&C machine**, not to
  the user who saved them.
- Therefore an unattended scheduled task on the **same C&C host** — including one
  using **S4U** ("Run whether user is logged on or not", no stored password) — can
  decrypt them and authenticate to nodes. This is what was previously broken.
- Off-machine and non-administrative access is constrained by **per-machine
  entropy** and a **restrictive file ACL** (SYSTEM + Administrators + the saving
  account only; the `Users` group and inherited access are removed).
- Credentials saved by the old `Export-Clixml` format are **migrated
  automatically** the first time they are read, *if* the current account can read
  them; otherwise you get a clear "re-save required" message.

## Why the old approach broke unattended backups

The previous credential store used `Export-Clixml` / `Import-Clixml`. For a
`PSCredential`, that seals the password with DPAPI under
`DataProtectionScope.CurrentUser`. CurrentUser-scope ciphertext can only be
decrypted by the **same Windows user**, and decryption needs that user's **loaded
profile**.

Windows Task Scheduler's **S4U** logon type (what "Run whether user is logged on
or not" uses when you do not store a password) is documented by Microsoft as:

> "When an S4U logon is used, no password is stored by the system and **there is
> no access to either the network or encrypted files**."
> — *TASK_LOGON_TYPE / logonType reference*

No loaded profile + "no access to encrypted files" means the S4U task **cannot**
decrypt a CurrentUser-DPAPI blob, even though an interactive run by the same
operator decrypts it fine. The result: manual backups work, scheduled backups
fail to authenticate.

## How SEBackup fixes it: LocalMachine-scope DPAPI

`Save-SEBCredential` now stores credentials in a small JSON envelope at
`Credentials/{NodeName}.cred`:

```json
{
  "Format": "SEBCredential",
  "Version": 1,
  "Scope": "LocalMachine",
  "UserName": "DOMAIN\\svc_sebackup",
  "ProtectedSecret": "<base64 DPAPI ciphertext of the password>"
}
```

Only the **password** is secret and protected; the username is stored in clear
(it was recoverable from the old Clixml format too, and is not a secret).

The password is protected with:

```text
ProtectedData.Protect(passwordBytes, perMachineEntropy, DataProtectionScope.LocalMachine)
```

`LocalMachine` scope binds the ciphertext to the **machine's** DPAPI master key
rather than a user profile. Any full-trust process on that machine can call
`Unprotect` — which is exactly what lets the unattended S4U/SYSTEM task read the
credential. (Microsoft's own guidance: *"LocalMachine … is usually used in
server-specific applications that run on a server where untrusted users are not
allowed access."* That is precisely the C&C host model.)

### The two hardening layers around LocalMachine scope

Because LocalMachine scope means "any local process can decrypt", SEBackup adds
two boundaries:

1. **Per-machine entropy.** The `optionalEntropy` argument to Protect/Unprotect is
   derived (SHA-256) from a fixed application salt **plus** this machine's
   cryptographic `MachineGuid`
   (`HKLM:\SOFTWARE\Microsoft\Cryptography\MachineGuid`). Consequences:
   - A `.cred` file copied to a **different machine cannot be decrypted there** —
     both the DPAPI master key and the MachineGuid differ.
   - Code that does not know the application salt cannot trivially reproduce the
     entropy.
   The MachineGuid is stable across reboots and readable by SYSTEM and by any
   local process, so it works under S4U where there is no user profile.

2. **Restrictive file ACL.** The `Credentials` directory and every `.cred` file
   are locked down (see below) so only SYSTEM, Administrators, and the saving
   account can even read the bytes.

> Note on DPAPI semantics: the `scope` argument passed to `Unprotect` is
> *advisory*. The true scope is recorded inside the blob, so a LocalMachine blob
> decrypts regardless of the scope value passed. The real, testable security
> properties are therefore "decrypts under LocalMachine (machine key)" and "fails
> with the wrong entropy / on a different machine", which the unit tests assert.

## File-permission (ACL) model

`Set-SEBCredentialAcl` applies this to the `Credentials` directory and each
`.cred` file:

- **Inheritance disabled and inherited rules dropped**
  (`SetAccessRuleProtection($true, $false)`), removing any `Users` /
  `Authenticated Users` access inherited from parent folders.
- **FullControl granted to exactly three trustees** (by well-known SID, so it is
  locale-independent):
  - `SYSTEM` (`S-1-5-18`) — for services and SYSTEM-run tasks.
  - `Administrators` (`S-1-5-32-544`).
  - the **account that saved the credential** (so the operator keeps access). This
    is skipped if it is already SYSTEM/Administrators, to avoid a duplicate entry.
- Directory grants are **inheritable**, so new `.cred` files inherit the lockdown.

The owner is intentionally left unchanged (reassigning the owner to
`Administrators` requires `SeRestorePrivilege` and is unnecessary — the DACL is
the protection). Re-applying the ACL to an already-hardened file is a no-op, which
avoids needing `SeSecurityPrivilege` during rotation from a non-elevated shell.

If ACL hardening fails (e.g. unusual filesystem), the credential is still
encrypted; the failure is logged via `Write-SEBLog -Level ERROR` rather than
silently ignored or fatally thrown.

## Setting up an unattended scheduled task

`Register-SEBScheduledTask` registers the backup task with:

- **LogonType S4U** under the current user, **RunLevel Highest**.
- This requires the principal to have the **"Log on as a batch job"** right
  (Administrators and Backup Operators have it by default).

The critical requirement for credentials to decrypt under the task:

> **Save the node credentials on the SAME C&C host the scheduled task runs on.**

Because the protection is machine-bound (not user-bound), it does **not** matter
that the S4U task runs without a loaded profile or stored password — it can still
decrypt. It also does not matter whether the task's user differs from the operator
who saved the credentials, as long as that user is an Administrator (so the ACL
grants access) on the same machine.

Recommended flow:

```powershell
# On the C&C host, as an administrator:
Save-SEBCredential -NodeName 'GameServer01'      # prompts; stores LocalMachine-DPAPI .cred
Register-SEBScheduledTask                          # S4U, highest privileges
```

If you provision the C&C on a new machine, re-save (or rotate) the credentials
there — a `.cred` copied from the old machine will not decrypt on the new one by
design.

## Credential rotation: `Update-SEBCredential`

`Update-SEBCredential` re-writes a node credential through the current protection
backend and re-applies the ACL. Two modes:

```powershell
# 1) Re-encrypt in place (preserves username + password). Use after the entropy
#    salt version changes, after migrating from the legacy store, or to refresh
#    the file ACL. Requires the existing blob to still be readable on this host.
Update-SEBCredential -NodeName 'GameServer01'

# 2) Replace the secret (e.g. the node's password changed). The existing blob does
#    not need to be readable for this path.
$new = Get-Credential -UserName 'svc_sebackup' -Message 'New password'
Update-SEBCredential -NodeName 'GameServer01' -Credential $new
```

`Update-SEBCredential` supports `-WhatIf` / `-Confirm` (rotation is treated as a
Medium-impact change).

## Migration from the legacy `Export-Clixml` store

When `Get-SEBCredential` finds no `{NodeName}.cred` but a legacy
`{NodeName}.cred.xml` exists:

- **If the current account can read the legacy file** (it was the saving user), it
  is transparently re-saved as a `.cred` in the new protected format, the legacy
  file is deleted, and the credential is returned. Callers are unaffected.
- **If it cannot be read** (it was saved by a different user — the very situation
  that blocks unattended use), the legacy file is **left untouched** and a clear
  error/warning instructs you to re-save it on this host:

  ```powershell
  Save-SEBCredential -NodeName 'GameServer01'
  ```

`Test-SEBCredential` and `Remove-SEBCredential` handle the legacy format too:
`Test-SEBCredential` returns `$false` for a legacy-only node — a CurrentUser `.cred.xml`
does not decrypt under an S4U task, so it reports "re-save required" rather than a
false-green readiness — and `Remove-SEBCredential` deletes both the `.cred` and any
leftover `.cred.xml`.

## Threat model summary

| Threat | Mitigation |
| --- | --- |
| Unattended S4U task cannot decrypt (the #27 bug) | LocalMachine-scope DPAPI — machine-bound, no profile needed |
| `.cred` file copied to another machine | Different DPAPI master key **and** different MachineGuid entropy → decryption fails |
| Non-admin local user reads the file | ACL grants only SYSTEM + Administrators + saving account; `Users` removed |
| Plaintext password on disk | Never written; only the DPAPI ciphertext (Base64) is stored |
| Stale legacy credential silently trusted | Legacy files migrated when readable; flagged "re-save required" when not |

## Swapping the backend later

The encryption is isolated behind two private functions in the
`CredentialManager` module: `Protect-SEBSecret` and `Unprotect-SEBSecret` (with
entropy from `Get-SEBSecretEntropy`). A future backend — a group Managed Service
Account (gMSA), a certificate, or `Microsoft.PowerShell.SecretManagement` — can
replace just those functions without touching `Save-/Get-/Update-/Remove-/Test-
SEBCredential`, their callers, or the file format negotiation. This was a
deliberate seam to satisfy the "pluggable secret backend" acceptance item while
keeping zero new module dependencies today.

## What is verified vs. deferred

The unit tests (`Tests/CredentialManager/CredentialManager.Tests.ps1`) assert, on
the build host:

- Save → Get round-trips the password exactly.
- The on-disk blob is not the plaintext and decrypts under LocalMachine scope.
- Decryption fails with the wrong entropy (the per-machine binding).
- The ACL is protected with SYSTEM + Administrators present and `Users` absent.
- `Update-SEBCredential` rotates (both modes) and honors `-WhatIf`.
- Legacy `.cred.xml` files are migrated when readable.

**Deferred to the live test-node phase:** a true end-to-end check that an actual
S4U "run whether logged on or not" scheduled task on the C&C host decrypts a
stored credential and authenticates to a real compute node. That requires a
registered task and a reachable node and cannot be exercised in a single-host unit
test; LocalMachine scope + the ACL are asserted here as the proxy.
