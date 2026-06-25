function Undo-SEBRestore {
    <#
    .SYNOPSIS
        Reverts the most recent restore by restoring the pre-restore safety backup.

    .DESCRIPTION
        Finds the most recent _prerestore_ directory on the remote node and
        reverts to it by:

        1. Finding the most recent {WorldName}_prerestore_{timestamp} directory.
        2. Stopping the Torch server.
        3. Moving the current world directory aside with a _postrestore_ suffix.
        4. Renaming the _prerestore_ directory back to the original world name.
        5. Starting the Torch server.

        This provides an escape hatch if a restore produces an undesirable state.

    .PARAMETER NodeName
        The name of the compute node hosting the Torch server instance.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance to undo the restore for.

    .EXAMPLE
        $result = Undo-SEBRestore -NodeName 'GameServer01' -InstanceName 'PvPArena'
        if ($result.Success) {
            Write-Host "Undo successful. Previous state restored."
        }

    .OUTPUTS
        PSCustomObject
        An object with: Success (bool), PreRestorePath (string),
        PostRestorePath (string), ErrorMessage (string).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue
    $hasSendNotification = Get-Command -Name 'Send-SEBRestoreNotification' -ErrorAction SilentlyContinue
    $lockAcquired = $false
    $session = $null
    # Track session ownership: New-SEBSession returns a CACHED session if one
    # already exists for the node, so we must only tear down a session WE created
    # -- never one the caller already owned.
    $sessionCreatedByUs = $false

    $result = [PSCustomObject]@{
        Success         = $false
        PreRestorePath  = $null
        PostRestorePath = $null
        ErrorMessage    = $null
    }

    try {
        # ====================================================================
        # STEP 0: Acquire the per-instance lock. This is the SAME lock the backup
        # and restore engines use, so an undo cannot run concurrently with a
        # scheduled backup (or a restore) of the same instance and corrupt the
        # world mid-rename. If the lock can't be acquired, fail BEFORE touching
        # the world.
        # ====================================================================
        $lockResult = New-SEBLockFile -InstanceName $InstanceName
        if (-not $lockResult.Acquired) {
            throw "Could not acquire lock for undo-restore of '$InstanceName': $($lockResult.Reason)"
        }
        $lockAcquired = $true

        if ($hasLogger) {
            Write-SEBLog -Message "=== Starting undo-restore for '$InstanceName' on '$NodeName' ===" -Level INFO -Context $InstanceName
        }

        # Load configs and create session
        $globalConfig = Get-SEBGlobalConfig -Force

        $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
        if ($null -eq $nodeConfig) {
            throw "Failed to load node configuration for '$NodeName'."
        }

        # Determine ownership BEFORE creating: if an open session is already cached
        # for this node, New-SEBSession will hand us that existing one (owned by the
        # caller) rather than make a new one, so we must not remove it in finally.
        $sessionPreexisted = Test-SEBSessionExists -NodeName $NodeName

        $session = New-SEBSession -NodeName $NodeName -NodeConfig ($nodeConfig.ContainsKey('node') ? $nodeConfig['node'] : $nodeConfig)
        if ($null -eq $session) {
            throw "Failed to create PSSession to node '$NodeName'."
        }
        if (-not $sessionPreexisted) {
            $sessionCreatedByUs = $true
        }

        $instanceConfig = Get-SEBInstanceConfig -Session $session -InstanceName $InstanceName
        if ($null -eq $instanceConfig) {
            throw "Failed to read instance config for '$InstanceName' from node '$NodeName'."
        }

        $worldPath = $instanceConfig['world_path']
        if ([string]::IsNullOrWhiteSpace($worldPath)) {
            throw "Instance config does not specify 'world_path'."
        }

        # Find the most recent prerestore directory.
        # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
        $findResult = Invoke-SEBRemoteCommand -Session $session -SessionRef ([ref]$session) -ScriptBlock {
            param($worldDir)

            $worldName = Split-Path -Path $worldDir -Leaf
            $worldParent = Split-Path -Path $worldDir -Parent

            # Find all prerestore directories for this world
            $preRestoreDirs = Get-ChildItem -Path $worldParent -Directory -Filter "${worldName}_prerestore_*" -ErrorAction SilentlyContinue |
                Sort-Object -Property Name -Descending

            if (-not $preRestoreDirs -or $preRestoreDirs.Count -eq 0) {
                return @{ Found = $false; Path = $null; Error = "No prerestore directories found for '$worldName' in '$worldParent'." }
            }

            return @{
                Found = $true
                Path  = $preRestoreDirs[0].FullName
                Name  = $preRestoreDirs[0].Name
                Error = $null
            }
        } -ArgumentList $worldPath -ErrorAction Stop

        if (-not $findResult.Found) {
            throw $findResult.Error
        }

        $result.PreRestorePath = $findResult.Path

        if ($hasLogger) {
            Write-SEBLog -Message "Found prerestore directory: $($findResult.Name)" -Level INFO -Context $InstanceName
        }

        # Stop the Torch server
        if ($hasLogger) {
            Write-SEBLog -Message "Stopping Torch server for undo..." -Level INFO -Context $InstanceName
        }

        $stopResult = Stop-SEBTorchServer `
            -Session        $session `
            -InstanceConfig $instanceConfig `
            -NodeConfig     $nodeConfig

        if (-not $stopResult.Stopped -and $stopResult.Method -ne 'manual') {
            throw "Failed to stop Torch server: $($stopResult.ErrorMessage)"
        }

        # Perform the undo: move current aside, rename prerestore back.
        # Route through the wrapper for retry/logging/reconnect; the block stays node-local.
        $undoResult = Invoke-SEBRemoteCommand -Session $session -SessionRef ([ref]$session) -ScriptBlock {
            param($worldDir, $preRestorePath)

            $worldName = Split-Path -Path $worldDir -Leaf
            $worldParent = Split-Path -Path $worldDir -Parent
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $postRestoreName = "${worldName}_postrestore_${timestamp}"
            $postRestorePath = Join-Path -Path $worldParent -ChildPath $postRestoreName

            # Move current world dir aside (if it exists)
            if (Test-Path -Path $worldDir -PathType Container) {
                try {
                    Rename-Item -Path $worldDir -NewName $postRestoreName -Force -ErrorAction Stop
                }
                catch {
                    return @{
                        Success         = $false
                        PostRestorePath = $null
                        Error           = "Failed to move current world dir aside: $_"
                    }
                }
            }
            else {
                $postRestorePath = $null
            }

            # Rename prerestore back to original world name
            try {
                Rename-Item -Path $preRestorePath -NewName $worldName -Force -ErrorAction Stop
            }
            catch {
                # Attempt rollback: restore the current world
                if ($null -ne $postRestorePath -and (Test-Path -Path $postRestorePath)) {
                    Rename-Item -Path $postRestorePath -NewName $worldName -Force -ErrorAction SilentlyContinue
                }
                return @{
                    Success         = $false
                    PostRestorePath = $postRestorePath
                    Error           = "Failed to rename prerestore directory back: $_"
                }
            }

            return @{
                Success         = $true
                PostRestorePath = $postRestorePath
                Error           = $null
            }
        } -ArgumentList $worldPath, $findResult.Path -ErrorAction Stop

        if (-not $undoResult.Success) {
            throw $undoResult.Error
        }

        $result.PostRestorePath = $undoResult.PostRestorePath

        # Start the Torch server
        if ($hasLogger) {
            Write-SEBLog -Message "Starting Torch server after undo..." -Level INFO -Context $InstanceName
        }

        $startResult = Start-SEBTorchServer `
            -Session        $session `
            -InstanceConfig $instanceConfig `
            -NodeConfig     $nodeConfig

        if (-not $startResult.Started) {
            Write-Warning "Torch server did not start: $($startResult.ErrorMessage)"
        }

        $result.Success = $true

        if ($hasLogger) {
            Write-SEBLog -Message "=== Undo-restore SUCCEEDED for '$InstanceName'. Restored prerestore state. ===" -Level INFO -Context $InstanceName
        }

        # ====================================================================
        # Send restore notification (best-effort; never blocks the undo).
        # ====================================================================
        if ($hasSendNotification -and
            $globalConfig -and $globalConfig.notifications -and $globalConfig.notifications.enabled) {
            try {
                $undoRestorePoint = if ($findResult -and $findResult.Name) { "Undo: $($findResult.Name)" } else { 'Undo' }
                Send-SEBRestoreNotification `
                    -InstanceName $InstanceName `
                    -RestorePoint $undoRestorePoint `
                    -InitiatedBy  'Undo-SEBRestore' `
                    -GlobalConfig $globalConfig
            }
            catch {
                Write-Warning "Undo-SEBRestore: failed to send restore notification: $_"
            }
        }
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message

        if ($hasLogger) {
            Write-SEBLog -Message "=== Undo-restore FAILED for '$InstanceName': $($_.Exception.Message) ===" -Level ERROR -Context $InstanceName
        }
    }
    finally {
        # Always release the lock, even if the undo failed partway through.
        # Only tear down the session if WE created it -- if it was already cached
        # for this node, the caller owns it and we must leave it open.
        if ($sessionCreatedByUs) {
            try {
                Remove-SEBSession -NodeName $NodeName
            }
            catch {
                Write-Warning "Undo-SEBRestore: failed to remove session for '$NodeName': $_"
            }
        }

        if ($lockAcquired) {
            Remove-SEBLockFile -InstanceName $InstanceName | Out-Null
        }
    }

    return $result
}
