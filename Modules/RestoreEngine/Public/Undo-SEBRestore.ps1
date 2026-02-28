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

    $result = [PSCustomObject]@{
        Success         = $false
        PreRestorePath  = $null
        PostRestorePath = $null
        ErrorMessage    = $null
    }

    try {
        if ($hasLogger) {
            Write-SEBLog -Message "=== Starting undo-restore for '$InstanceName' on '$NodeName' ===" -Level INFO -Context $InstanceName
        }

        # Load configs and create session
        $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName
        if ($null -eq $nodeConfig) {
            throw "Failed to load node configuration for '$NodeName'."
        }

        $session = New-SEBSession -NodeName $NodeName -NodeConfig ($nodeConfig.ContainsKey('node') ? $nodeConfig['node'] : $nodeConfig)
        if ($null -eq $session) {
            throw "Failed to create PSSession to node '$NodeName'."
        }

        $instanceConfig = Get-SEBInstanceConfig -Session $session -InstanceName $InstanceName
        if ($null -eq $instanceConfig) {
            throw "Failed to read instance config for '$InstanceName' from node '$NodeName'."
        }

        $worldPath = $instanceConfig['world_path']
        if ([string]::IsNullOrWhiteSpace($worldPath)) {
            throw "Instance config does not specify 'world_path'."
        }

        # Find the most recent prerestore directory
        $findResult = Invoke-Command -Session $session -ScriptBlock {
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

        # Perform the undo: move current aside, rename prerestore back
        $undoResult = Invoke-Command -Session $session -ScriptBlock {
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
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message

        if ($hasLogger) {
            Write-SEBLog -Message "=== Undo-restore FAILED for '$InstanceName': $($_.Exception.Message) ===" -Level ERROR -Context $InstanceName
        }
    }

    return $result
}
