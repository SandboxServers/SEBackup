function Test-SEBSafeName {
    <#
    .SYNOPSIS
        Validates that a name is safe to use as a single filesystem path segment.

    .DESCRIPTION
        Node names, instance names, lock-file stems, and manifest-supplied archive names are
        all interpolated into filesystem paths somewhere in SEBackup (e.g.
        Join-Path $BackupRoot $InstanceName, "<InstanceName>.lock", "<NodeName>.toml"). A value
        that contains a path separator, a '..' traversal sequence, a drive/UNC root, a PowerShell
        wildcard metacharacter, or any character the OS forbids in a filename can escape the
        intended directory (path traversal / zip-slip) or be treated as a glob that matches an
        unintended file.

        This is the single, canonical validator that name->path boundaries in the codebase share so
        the rejection rules stay defined in one place (used by, among others, Get-SEBInstanceConfig,
        Get-SEBNodeConfig, New-SEBLockFile, Get-SEBRestorePoints, Get-SEBBackupHistory,
        Get-SEBLatestManifest, Get-SEBManifestChain, Add-SEBMetric, Test-SEBChainIntegrity,
        Resolve-SEBChainArchivePath, and the integrity-report read/write pair). It rejects a name
        when ANY of the following is true:

        - It contains a path separator: '\' or '/'.
        - It contains the traversal sequence '..'.
        - It consists entirely of dots ('.', '...', etc.). '.' is the current-directory reference,
          which collapses under Join-Path ('Join-Path $Root ''.''' resolves back to $Root) and would
          bypass the per-instance directory boundary; an all-dots name is likewise not a real segment.
        - It is a rooted path according to [System.IO.Path]::IsPathRooted (e.g. 'C:\x', '\\srv\s').
        - It contains a PowerShell wildcard metacharacter: '*', '?', '[', or ']'.
        - It contains any character returned by [System.IO.Path]::GetInvalidFileNameChars().

        It deliberately ALLOWS otherwise-legitimate names that merely contain '.', '-', '_', or
        spaces (for example 'PvP.Arena' or 'My Server'), because the config layer, the backup engine,
        and the lock layer all accept such names. (Only a name that is ENTIRELY dots is rejected, per
        the rule above; an embedded dot in a real name is fine.) A null, empty, or whitespace-only
        value is rejected.

        By default the function returns a [bool] so callers can branch on the result. When -Throw
        is supplied, it instead throws a clear, descriptive error on an invalid name (and returns
        $true on a valid one), so a call site can use whichever style fits -- a returned result
        object versus a terminating parameter-binding/validation error.

    .PARAMETER Name
        The candidate name to validate. This is expected to be a single path SEGMENT (a node
        name, instance name, or bare filename), never a multi-segment path.

    .PARAMETER Throw
        When specified, throw a terminating error describing why the name is unsafe instead of
        returning $false. On a safe name the function returns $true regardless of this switch.

    .EXAMPLE
        if (-not (Test-SEBSafeName -Name $InstanceName)) {
            return [PSCustomObject]@{ Acquired = $false; Reason = 'Invalid instance name.' }
        }
        # Boolean style: branch on the result and return a structured failure.

    .EXAMPLE
        Test-SEBSafeName -Name $NodeName -Throw | Out-Null
        # Throwing style: abort immediately with a descriptive error if the name is unsafe.

    .EXAMPLE
        [ValidateScript({ Test-SEBSafeName -Name $_ -Throw })]
        [string]$InstanceName
        # Use directly inside a [ValidateScript] so binding fails on an unsafe value.

    .OUTPUTS
        System.Boolean
        $true when the name is safe to use as a single path segment; $false otherwise (unless
        -Throw is specified, in which case an unsafe name throws and a safe name returns $true).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Name,

        [Parameter()]
        [switch]$Throw
    )

    # Build the human-readable reason as we test, so the -Throw message and any logging stay
    # specific about WHY a name was rejected.
    $reason = $null

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $reason = 'it is null, empty, or whitespace.'
    }
    elseif ($Name -match '[\\/]') {
        $reason = 'it contains a path separator.'
    }
    elseif ($Name.Contains('..')) {
        $reason = "it contains the '..' traversal sequence."
    }
    elseif ($Name -match '^\.+$') {
        # A name made up entirely of dots ('.', '...', etc.) is a relative directory reference,
        # not a real segment. '.' in particular collapses under Join-Path: Join-Path $Root '.'
        # resolves back to $Root, bypassing the intended per-instance subdirectory boundary, so a
        # backup/restore could read or write the shared root instead of its own folder. (The plain
        # '..' case is already caught above; this rejects the single-dot and all-dot variants too.)
        $reason = "it is a relative directory reference ('.' or all dots), which is not a valid path segment."
    }
    elseif ([System.IO.Path]::IsPathRooted($Name)) {
        $reason = 'it is a rooted/absolute path.'
    }
    elseif ($Name -match '[\*\?\[\]]') {
        $reason = 'it contains a wildcard metacharacter (* ? [ ]).'
    }
    elseif ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $reason = 'it contains an invalid filename character.'
    }

    if ($null -ne $reason) {
        if ($Throw) {
            throw "Invalid name '$Name': $reason Path separators, traversal, rooted paths, wildcards, and invalid filename characters are not allowed."
        }
        return $false
    }

    return $true
}
