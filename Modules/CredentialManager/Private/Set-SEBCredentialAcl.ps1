function Set-SEBCredentialAcl {
    <#
    .SYNOPSIS
        Applies a restrictive ACL to a credential file or the Credentials directory.

    .DESCRIPTION
        Locks down a credential store path so only SYSTEM, the local Administrators
        group, and the account that created it can read it. This is the access
        boundary that compensates for LocalMachine-scope DPAPI: because any local
        process could otherwise call Unprotect, the file ACL is what actually keeps
        non-administrative local users out of the encrypted node credentials.

        What it does (grounded in the FileSystem provider Set-Acl behavior):
        1. Disables inheritance and DROPS inherited rules via
           SetAccessRuleProtection($true, $false) -- this removes any inherited
           "Users" / "Authenticated Users" access the path picked up from its
           parent.
        2. Removes every remaining explicit rule, then grants FullControl to:
             - SYSTEM            (S-1-5-18, LocalSystemSid)            -> services / SYSTEM-run tasks
             - Administrators    (S-1-5-32-544, BuiltinAdministratorsSid)
             - the current user  (so the operator who saved it keeps access)
           SIDs are used directly (not names) so the rules are language- and
           locale-independent. The current-user SID is skipped if it is already
           SYSTEM or a covered well-known group, to avoid a duplicate ACE.
        3. For a directory, the grants are made inheritable (ContainerInherit +
           ObjectInherit) so newly written "*.cred" files inherit the lockdown.

        Idempotency: if the path is already protected with EXACTLY the desired
        trustee set, the function returns success WITHOUT rewriting the ACL. This
        matters for rotation/re-save: rewriting the security descriptor of an
        already-protected file from a non-elevated shell requires the
        SeSecurityPrivilege ("Manage auditing and security log") right and would
        otherwise fail. Skipping the redundant write keeps Update-SEBCredential
        working unelevated while leaving the lockdown intact.

        Owner is intentionally NOT changed: setting the owner to Administrators
        requires SeRestorePrivilege and fails for a normal admin shell; the ACL
        itself provides the protection regardless of owner.

        Errors are logged via Write-SEBLog and the function returns $false rather
        than throwing; it does NOT decide the consequence -- the CALLER does. The
        credential-write path (Write-SEBProtectedCredentialFile) treats a $false here
        as FATAL: it discards the temp credential file and refuses to publish it,
        rather than leave ciphertext on disk that non-admin local users could read.
        (Other callers, e.g. Resolve-CredentialPath hardening the directory, treat it
        as best-effort.) Internal; not exported.

    .PARAMETER Path
        The credential file or Credentials directory to harden.

    .OUTPUTS
        System.Boolean
        $true if the ACL is in the desired hardened state (already or after
        applying); $false if hardening failed.

    .EXAMPLE
        Set-SEBCredentialAcl -Path 'C:\SEBackup\Credentials\Node01.cred'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Cannot set ACL: path does not exist: $Path"
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $isDirectory = $item.PSIsContainer

        # Well-known trustees, built from SID values so they work on any locale.
        $systemSid = [System.Security.Principal.SecurityIdentifier]::new(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $adminsSid = [System.Security.Principal.SecurityIdentifier]::new(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

        # Desired trustee SID set (deduped: the current user may BE SYSTEM/Admins).
        $desiredSids = [System.Collections.Generic.HashSet[string]]::new()
        [void]$desiredSids.Add($systemSid.Value)
        [void]$desiredSids.Add($adminsSid.Value)
        if ($currentSid.Value -ne $systemSid.Value -and $currentSid.Value -ne $adminsSid.Value) {
            [void]$desiredSids.Add($currentSid.Value)
        }

        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop

        # Fast path: if the DACL is already protected and grants exactly the desired
        # FullControl trustees, do nothing. Avoids a needless security-descriptor
        # write (which needs SeSecurityPrivilege on an already-protected file).
        # For a DIRECTORY the shape check is necessary-but-insufficient: the grants
        # must ALSO be inheritable (ContainerInherit|ObjectInherit, PropagationFlags
        # None) or newly written .cred files would not inherit the lockdown. A dir
        # protected with the right trustees but NON-inheritable ACEs must fall
        # through to the rewrite, so we verify inheritance flags too.
        $containerInherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
        $objectInherit = [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $requiredInherit = $containerInherit -bor $objectInherit
        if ($acl.AreAccessRulesProtected) {
            $presentSids = [System.Collections.Generic.HashSet[string]]::new()
            $matchesShape = $true
            foreach ($rule in $acl.Access) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                    $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
                    $matchesShape = $false
                    break
                }
                if ($isDirectory) {
                    # Every grant must carry both inheritance flags and no propagation flags.
                    if ((($rule.InheritanceFlags -band $requiredInherit) -ne $requiredInherit) -or
                        ($rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None)) {
                        $matchesShape = $false
                        break
                    }
                }
                [void]$presentSids.Add($rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value)
            }
            if ($matchesShape -and $presentSids.SetEquals($desiredSids)) {
                Write-SEBLog -Level DEBUG -Context 'CredentialManager' -Message "Credential path already hardened; leaving ACL unchanged: $Path" -NoConsole
                return $true
            }
        }

        # Protect the DACL and discard inherited ACEs (the $false = do NOT preserve).
        $acl.SetAccessRuleProtection($true, $false)

        # Clear any explicit rules so we define the access set from scratch.
        foreach ($rule in @($acl.Access)) {
            if ($null -ne $rule) {
                [void]$acl.RemoveAccessRule($rule)
            }
        }

        $inheritance = if ($isDirectory) {
            $requiredInherit
        }
        else {
            [System.Security.AccessControl.InheritanceFlags]::None
        }
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow = [System.Security.AccessControl.AccessControlType]::Allow

        foreach ($sidValue in $desiredSids) {
            $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
            $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid, $fullControl, $inheritance, $propagation, $allow)
            $acl.AddAccessRule($accessRule)
        }

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        Write-SEBLog -Level DEBUG -Context 'CredentialManager' -Message "Applied restrictive ACL (SYSTEM + Administrators + current user, inheritance removed) to: $Path" -NoConsole
        return $true
    }
    catch {
        Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message "Failed to apply restrictive ACL to '$Path': $_"
        return $false
    }
}
