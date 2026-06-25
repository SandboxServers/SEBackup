function Convert-SEBLegacyCredential {
    <#
    .SYNOPSIS
        Migrates a legacy Export-Clixml credential file to the new protected format.

    .DESCRIPTION
        Best-effort, transparent migration for credentials saved before issue #27.
        The legacy store used Export-Clixml, whose password SecureString is sealed
        with CurrentUser-scope DPAPI -- readable only by the user who saved it on
        this machine. This helper attempts to Import-Clixml the legacy
        "{NodeName}.cred.xml" file and, if it deserializes to a PSCredential,
        re-saves it through the new LocalMachine-DPAPI protected store
        ("{NodeName}.cred") via the supplied re-save script block.

        Outcomes:
        - Migrated  : legacy file was readable; a new ".cred" was written AND
          verified to decrypt back to the same credential on this host. Only then
          is the legacy ".cred.xml" deleted, so the readable copy is never removed
          before the replacement is proven recoverable.
        - NotReadable: legacy file exists but could not be decrypted (e.g. it was
          created by a different user), OR the new ".cred" was written but failed
          the decrypt round-trip. In both cases the legacy file is LEFT in place
          and the caller surfaces a clear "re-save required" warning. Nothing
          recoverable is destroyed.
        - None      : no legacy file present.

        Concurrency: the read-back-verify-then-delete sequence runs under a named
        cross-process mutex keyed on the node, because Get-SEBCredential is now
        called from several unsynchronised contexts (New-SEBSession,
        Test-SEBConnection, multiple per-instance backups of the same node). If
        another process won the race and already produced the new ".cred" while we
        waited on the mutex, that is treated as success (Migrated) by re-reading the
        freshly written file -- not as a sharing-violation failure.

        Mutex unavailable (fail-safe): if the cross-process mutex cannot be CREATED
        (e.g. the account lacks the SeCreateGlobalPrivilege for the "Global\"
        namespace) or cannot be ACQUIRED within the timeout, the destructive
        re-save/verify/delete is SKIPPED entirely -- running it without exclusion
        could race a second process into a double write/delete. In that case the
        legacy file is read READ-ONLY and returned (Status='NotReadable', Credential
        set if readable) so the caller can still authenticate this run; nothing is
        written and nothing is deleted. This preserves the "never throws / never
        loses the only readable copy" contract.

        This never throws; failures are reported through the returned status so the
        calling Get/Test path can continue. Internal; not exported.

    .PARAMETER NodeName
        The node whose legacy credential should be migrated.

    .PARAMETER SaveAction
        A script block that persists a PSCredential in the NEW protected format for
        the node. It receives the PSCredential as its only argument. Injected by
        the caller (Save-SEBCredential's serialization path) to avoid a circular
        dependency and to keep all writing logic in one place. Must return $true on
        success.

    .OUTPUTS
        System.Collections.Hashtable
        @{ Status = 'Migrated' | 'NotReadable' | 'None'; Credential = <PSCredential or $null> }

    .EXAMPLE
        $result = Convert-SEBLegacyCredential -NodeName 'Node01' -SaveAction {
            param($cred) Write-SEBProtectedCredentialFile -NodeName 'Node01' -Credential $cred
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNull()]
        [scriptblock]$SaveAction
    )

    $legacyFile = Resolve-CredentialPath -NodeName $NodeName -Legacy
    $newFile = Resolve-CredentialPath -NodeName $NodeName

    if (-not (Test-Path -LiteralPath $legacyFile)) {
        return @{ Status = 'None'; Credential = $null }
    }

    # Serialize the whole re-save/verify/delete across processes. Get-SEBCredential
    # (which calls this) runs from several unsynchronised callers, so two backups of
    # the same node could otherwise both re-save and delete concurrently. The mutex
    # name is derived from the node and must be a legal mutex name (Resolve has
    # already validated NodeName, so it is filename-safe).
    $mutexName = "Global\SEBackup.CredMigrate.$NodeName"
    $mutex = $null
    $acquired = $false
    try {
        # Creating/opening the named mutex can FAIL on a locked-down host -- e.g. the
        # caller lacks the SeCreateGlobalPrivilege needed for the "Global\" namespace,
        # or a name collision yields an UnauthorizedAccessException. Treat that exactly
        # like a failure to acquire: we must NOT run the destructive re-save/verify/delete
        # sequence without exclusion, but we must also honor the "never throws" contract.
        try {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        }
        catch {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
                "Could not create the cross-process migration mutex for node '$NodeName' " +
                "($_); skipping the legacy re-save to avoid an unsynchronised write/delete. " +
                "Returning the legacy credential as-is if it is readable.")
            return (Get-SafeReadableLegacyCredential -LegacyFile $legacyFile)
        }

        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        }
        catch [System.Threading.AbandonedMutexException] {
            # A previous holder crashed; we now own it. Safe to proceed.
            $acquired = $true
        }
        catch {
            # WaitOne can also throw (e.g. AbandonedMutexException is handled above, but
            # an unexpected wait failure must not escape). Treat as "not acquired".
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
                "Waiting on the migration mutex for node '$NodeName' failed ($_); " +
                "skipping the legacy re-save to avoid an unsynchronised write/delete.")
            $acquired = $false
        }

        # If exclusion could not be guaranteed (timed out, or wait failed), do NOT enter
        # the re-save/verify/delete path -- a second process could be doing the same thing.
        # Return the readable legacy credential (so the caller can still authenticate this
        # run) WITHOUT writing or deleting anything. Nothing races; nothing is lost.
        if (-not $acquired) {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
                "Could not acquire the cross-process migration mutex for node '$NodeName' " +
                "within the timeout; skipping the legacy re-save to avoid an unsynchronised " +
                "write/delete. Returning the legacy credential as-is if it is readable.")
            return (Get-SafeReadableLegacyCredential -LegacyFile $legacyFile)
        }

        # If another process already produced the new file (won the race), treat it
        # as migrated by reading it back, rather than racing a second delete/write.
        if (Test-Path -LiteralPath $newFile) {
            $existing = $null
            try {
                $raw = Get-Content -LiteralPath $newFile -Raw -ErrorAction Stop
                $existing = ($raw | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { ConvertFrom-SEBProtectedCredential -Envelope $_ })
            }
            catch { $existing = $null }
            if ($existing -is [PSCredential]) {
                Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Migration of node '$NodeName' was completed concurrently by another process; using the existing protected credential."
                return @{ Status = 'Migrated'; Credential = $existing }
            }
        }

        # Try to read the legacy Clixml credential. This only succeeds for the same
        # user that saved it (CurrentUser DPAPI), which is the whole reason #27 exists.
        $legacyCred = $null
        try {
            $legacyCred = Import-Clixml -LiteralPath $legacyFile -ErrorAction Stop
        }
        catch {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message (
                "Legacy credential '$legacyFile' could not be read for migration " +
                "(likely saved by a different user): $_")
            return @{ Status = 'NotReadable'; Credential = $null }
        }

        if ($legacyCred -isnot [PSCredential]) {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Legacy credential file '$legacyFile' did not contain a PSCredential; leaving it in place."
            return @{ Status = 'NotReadable'; Credential = $null }
        }

        # Re-save in the new format using the injected writer.
        try {
            $saved = & $SaveAction $legacyCred
            if (-not $saved) {
                Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migration of '$NodeName' failed while writing the new protected credential; legacy file left intact."
                return @{ Status = 'NotReadable'; Credential = $legacyCred }
            }
        }
        catch {
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migration of '$NodeName' threw while writing the new protected credential; legacy file left intact: $_"
            return @{ Status = 'NotReadable'; Credential = $legacyCred }
        }

        # VERIFY BEFORE DELETE: confirm the just-written .cred actually decrypts back
        # to the same credential on THIS host before destroying the only other
        # readable copy. If the entropy that protected it cannot be reproduced (e.g.
        # MachineGuid fallback divergence), keep the legacy file and report failure.
        if (-not (Test-SEBProtectedCredentialReadBack -Path $newFile -Expected $legacyCred)) {
            Write-SEBLog -Level ERROR -Context 'CredentialManager' -Message (
                "Migration of node '$NodeName' wrote a new protected credential that did NOT " +
                "verify on read-back; KEEPING the legacy file '$legacyFile' so nothing is lost. " +
                "Re-save on this host with Save-SEBCredential -NodeName '$NodeName'.")
            # Remove the unverifiable new file so a later read does not surface it as
            # an undecryptable .cred that masks the still-readable legacy copy.
            Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
            return @{ Status = 'NotReadable'; Credential = $legacyCred }
        }

        # Replacement verified -- now it is safe to remove the legacy file.
        try {
            Remove-Item -LiteralPath $legacyFile -Force -ErrorAction Stop
            Write-SEBLog -Level INFO -Context 'CredentialManager' -Message "Migrated credential for node '$NodeName' from legacy Clixml to LocalMachine-DPAPI protected format (verified on read-back); removed '$legacyFile'."
        }
        catch {
            # The new file is valid and verified; failing to delete the old one is non-fatal.
            Write-SEBLog -Level WARN -Context 'CredentialManager' -Message "Migrated '$NodeName' to the new format but could not remove the legacy file '$legacyFile': $_"
        }

        return @{ Status = 'Migrated'; Credential = $legacyCred }
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() }
                catch {
                    # Best-effort release during cleanup; a failure here (e.g. the
                    # mutex was already released/abandoned) must not mask the real
                    # result. Log at DEBUG rather than swallow silently.
                    Write-SEBLog -Level DEBUG -Context 'CredentialManager' -Message "Releasing migration mutex for node '$NodeName' failed (non-fatal): $_" -NoConsole
                }
            }
            $mutex.Dispose()
        }
    }
}
