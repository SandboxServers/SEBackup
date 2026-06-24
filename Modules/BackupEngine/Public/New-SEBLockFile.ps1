function New-SEBLockFile {
    <#
    .SYNOPSIS
        Creates a lock file for a backup instance to prevent concurrent runs.

    .DESCRIPTION
        Creates a lock file at Data/lockfiles/{InstanceName}.lock containing the
        current process ID, timestamp, and hostname. Before creating the lock, checks
        if a lock file already exists:

        - If the existing lock is stale (older than StaleThresholdHours), it is
          automatically broken and replaced with a new lock.
        - If the existing lock is fresh, the function returns a failure result
          indicating the instance is already locked.

        The lock file is a JSON file with the following structure:
        {
            "pid": 12345,
            "hostname": "DESKTOP-ABC123",
            "timestamp": "2026-02-27T10:30:00.0000000Z",
            "instance": "PvPArena"
        }

    .PARAMETER InstanceName
        The name of the Space Engineers server instance to lock.

    .PARAMETER StaleThresholdHours
        The number of hours after which a lock is considered stale and can be
        automatically broken. Defaults to 4 hours.

    .EXAMPLE
        $lockResult = New-SEBLockFile -InstanceName 'PvPArena'
        if ($lockResult.Acquired) {
            Write-Host "Lock acquired at $($lockResult.LockFilePath)"
        } else {
            Write-Warning "Lock not acquired: $($lockResult.Reason)"
        }

    .OUTPUTS
        PSCustomObject
        An object with properties: Acquired (bool), LockFilePath (string),
        Reason (string), StaleLockBroken (bool).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter()]
        [ValidateRange(1, 48)]
        [int]$StaleThresholdHours = 4
    )

    $projectRoot = Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent
    $lockDir = Join-Path -Path $projectRoot -ChildPath 'Data' -AdditionalChildPath 'lockfiles'
    $lockFilePath = Join-Path -Path $lockDir -ChildPath "${InstanceName}.lock"

    $staleBroken = $false

    # Ensure lockfiles directory exists
    if (-not (Test-Path -Path $lockDir -PathType Container)) {
        New-Item -Path $lockDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # Check for existing lock file
    if (Test-Path -Path $lockFilePath -PathType Leaf) {
        try {
            $existingLock = Get-Content -Path $lockFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
            $lockAge = ([datetime]::UtcNow - [datetime]::Parse($existingLock.timestamp)).TotalHours

            if ($lockAge -ge $StaleThresholdHours) {
                # Stale lock - break it
                $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
                if ($hasLogger) {
                    Write-SEBLog -Message "Breaking stale lock for '$InstanceName' (age: $([math]::Round($lockAge, 1))h, PID: $($existingLock.pid), host: $($existingLock.hostname))" -Level WARN -Context $InstanceName
                }
                Write-Warning "Breaking stale lock for '$InstanceName' (age: $([math]::Round($lockAge, 1))h)"
                Remove-Item -Path $lockFilePath -Force -ErrorAction Stop
                $staleBroken = $true
            }
            else {
                # Fresh lock - cannot proceed
                return [PSCustomObject]@{
                    Acquired        = $false
                    LockFilePath    = $lockFilePath
                    Reason          = "Instance '$InstanceName' is locked by PID $($existingLock.pid) on $($existingLock.hostname) since $($existingLock.timestamp) ($([math]::Round($lockAge, 1))h ago). Lock is not stale (threshold: ${StaleThresholdHours}h)."
                    StaleLockBroken = $false
                }
            }
        }
        catch {
            # Lock file is corrupt or unreadable - remove and proceed
            Write-Warning "Lock file for '$InstanceName' is corrupt or unreadable. Removing: $_"
            Remove-Item -Path $lockFilePath -Force -ErrorAction SilentlyContinue
            $staleBroken = $true
        }
    }

    # Create the new lock file
    $lockData = @{
        pid       = $PID
        hostname  = [System.Environment]::MachineName
        timestamp = [datetime]::UtcNow.ToString('o')
        instance  = $InstanceName
    }

    # Create the lock file ATOMICALLY: FileMode.CreateNew fails if the file already exists,
    # so if two runs race past the stale-check above, exactly one wins. A Test-Path-then-write
    # would let both believe they acquired the lock.
    try {
        $lockJson = $lockData | ConvertTo-Json -Depth 2
        $fs = [System.IO.File]::Open($lockFilePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockJson)
            $fs.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $fs.Dispose()
        }
    }
    catch [System.IO.IOException] {
        # Another process created the lock between our check and our create.
        return [PSCustomObject]@{
            Acquired        = $false
            LockFilePath    = $lockFilePath
            Reason          = "Instance '$InstanceName' lock was acquired by another process concurrently."
            StaleLockBroken = $staleBroken
        }
    }
    catch {
        return [PSCustomObject]@{
            Acquired        = $false
            LockFilePath    = $lockFilePath
            Reason          = "Failed to create lock file: $_"
            StaleLockBroken = $staleBroken
        }
    }

    return [PSCustomObject]@{
        Acquired        = $true
        LockFilePath    = $lockFilePath
        Reason          = $null
        StaleLockBroken = $staleBroken
    }
}
