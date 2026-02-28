function Deploy-SEBRestoredFiles {
    <#
    .SYNOPSIS
        Deploys reconstructed backup files to the world save location on the node.

    .DESCRIPTION
        Handles the atomic-ish deployment of restored files to the Torch server's
        world save directory:

        1. Renames the current world directory to {WorldName}_prerestore_{timestamp}
           as a safety backup (escape hatch for Undo-SEBRestore).
        2. Copies the reconstructed files from the temp working directory to the
           world save location.
        3. Verifies the copy by comparing file counts and spot-checking key files.

        If any step fails, the function attempts to roll back by restoring the
        pre-restore directory.

    .PARAMETER Session
        An active PSSession connected to the target compute node.

    .PARAMETER SourceDir
        The path on the remote node to the reconstructed (temp) directory
        containing the files to deploy.

    .PARAMETER WorldPath
        The path on the remote node to the world save directory (the target
        deployment location).

    .EXAMPLE
        $result = Deploy-SEBRestoredFiles -Session $session `
            -SourceDir 'C:\SEBackup\restore_temp\PvPArena' `
            -WorldPath 'C:\TorchServer\Instance\Saves\PvPWorld'
        if ($result.Deployed) {
            Write-Host "Deployed successfully. Pre-restore backup at: $($result.PreRestorePath)"
        }

    .OUTPUTS
        PSCustomObject
        An object with: Deployed (bool), PreRestorePath (string),
        FilesCopied (int), ErrorMessage (string).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorldPath
    )

    $hasLogger = Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue

    try {
        $deployResult = Invoke-Command -Session $Session -ScriptBlock {
            param($src, $worldDir)

            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $worldName = Split-Path -Path $worldDir -Leaf
            $worldParent = Split-Path -Path $worldDir -Parent
            $preRestoreName = "${worldName}_prerestore_${timestamp}"
            $preRestorePath = Join-Path -Path $worldParent -ChildPath $preRestoreName

            # Step 1: Rename the current world dir as a safety backup
            if (Test-Path -Path $worldDir -PathType Container) {
                try {
                    Rename-Item -Path $worldDir -NewName $preRestoreName -Force -ErrorAction Stop
                }
                catch {
                    return @{
                        Deployed       = $false
                        PreRestorePath = $null
                        FilesCopied    = 0
                        Error          = "Failed to rename current world dir to '$preRestoreName': $_"
                    }
                }
            }
            else {
                $preRestorePath = $null
            }

            # Step 2: Copy reconstructed files to world location
            try {
                # Use robocopy for performance and reliability
                $robocopyArgs = @($src, $worldDir, '/E', '/R:2', '/W:1', '/NP', '/NDL', '/NFL', '/MT:4')
                $null = & robocopy @robocopyArgs
                $robocopyExit = $LASTEXITCODE

                if ($robocopyExit -ge 8) {
                    # Rollback: restore the pre-restore directory
                    if ($null -ne $preRestorePath -and (Test-Path -Path $preRestorePath)) {
                        if (Test-Path -Path $worldDir) {
                            Remove-Item -Path $worldDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        Rename-Item -Path $preRestorePath -NewName $worldName -Force -ErrorAction SilentlyContinue
                    }

                    return @{
                        Deployed       = $false
                        PreRestorePath = $preRestorePath
                        FilesCopied    = 0
                        Error          = "Robocopy failed with exit code $robocopyExit. Rolled back."
                    }
                }
            }
            catch {
                # Rollback
                if ($null -ne $preRestorePath -and (Test-Path -Path $preRestorePath)) {
                    if (Test-Path -Path $worldDir) {
                        Remove-Item -Path $worldDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Rename-Item -Path $preRestorePath -NewName $worldName -Force -ErrorAction SilentlyContinue
                }

                return @{
                    Deployed       = $false
                    PreRestorePath = $preRestorePath
                    FilesCopied    = 0
                    Error          = "Failed to copy files to world dir: $_. Rolled back."
                }
            }

            # Step 3: Verify the copy
            $sourceFiles = @(Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue)
            $destFiles = @(Get-ChildItem -Path $worldDir -Recurse -File -ErrorAction SilentlyContinue)

            $filesCopied = $destFiles.Count

            # Basic verification: file count match
            if ($sourceFiles.Count -ne $destFiles.Count) {
                return @{
                    Deployed       = $false
                    PreRestorePath = $preRestorePath
                    FilesCopied    = $filesCopied
                    Error          = "File count mismatch: source has $($sourceFiles.Count) files, destination has $filesCopied. Deployment may be incomplete."
                }
            }

            # Spot-check: verify Sandbox.sbc exists
            $sandboxPath = Join-Path -Path $worldDir -ChildPath 'Sandbox.sbc'
            if (-not (Test-Path -Path $sandboxPath -PathType Leaf)) {
                return @{
                    Deployed       = $false
                    PreRestorePath = $preRestorePath
                    FilesCopied    = $filesCopied
                    Error          = "Sandbox.sbc not found in deployed world directory. Deployment may be corrupt."
                }
            }

            return @{
                Deployed       = $true
                PreRestorePath = $preRestorePath
                FilesCopied    = $filesCopied
                Error          = $null
            }
        } -ArgumentList $SourceDir, $WorldPath -ErrorAction Stop

        if ($hasLogger) {
            if ($deployResult.Deployed) {
                Write-SEBLog -Message "Files deployed to '$WorldPath': $($deployResult.FilesCopied) files." -Level INFO
            }
            else {
                Write-SEBLog -Message "Deployment failed: $($deployResult.Error)" -Level ERROR
            }
        }

        return [PSCustomObject]@{
            Deployed       = $deployResult.Deployed
            PreRestorePath = $deployResult.PreRestorePath
            FilesCopied    = $deployResult.FilesCopied
            ErrorMessage   = $deployResult.Error
        }
    }
    catch {
        if ($hasLogger) {
            Write-SEBLog -Message "Deployment exception: $_" -Level ERROR
        }

        return [PSCustomObject]@{
            Deployed       = $false
            PreRestorePath = $null
            FilesCopied    = 0
            ErrorMessage   = "Deployment exception: $_"
        }
    }
}
