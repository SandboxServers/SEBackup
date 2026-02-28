function Test-SEBArchiveIntegrity {
    <#
    .SYNOPSIS
        Performs a Level 1 integrity check on a backup archive.

    .DESCRIPTION
        Tests an archive's internal integrity by invoking Test-SEBArchive from the
        CompressionManager module. This is the fastest verification level -- it
        validates the archive's CRC/hash to confirm the file is not corrupted and
        can be decompressed without errors.

        Level 1 verification is suitable for post-compression quick checks and
        periodic health scans of the backup repository.

    .PARAMETER ArchivePath
        The full path to the backup archive file to verify. The archive format
        is determined by the CompressionManager based on file extension.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the integrity
        check is performed on the remote machine where the archive resides.

    .EXAMPLE
        $result = Test-SEBArchiveIntegrity -ArchivePath "C:\SEBackup\Backups\PvPArena\full_20260201_020000.7z"
        if ($result.Passed) { Write-Host "Archive is intact" }

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $result = Test-SEBArchiveIntegrity -ArchivePath "D:\Backups\inc_20260202.7z" -Session $session
        $result.ErrorMessage  # Check for failure details

    .OUTPUTS
        PSCustomObject
        An object with properties: Level, Passed, ArchivePath, CheckedAt, ErrorMessage.

    .LINK
        Test-SEBManifestIntegrity
        Test-SEBChainIntegrity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ArchivePath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $result = [PSCustomObject]@{
        Level        = 1
        Passed       = $false
        ArchivePath  = $ArchivePath
        CheckedAt    = [datetime]::UtcNow
        ErrorMessage = $null
    }

    try {
        Write-Verbose "IntegrityManager: Level 1 check on '$ArchivePath'"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 1 integrity check: $ArchivePath" -Level INFO -Context 'Integrity'
        }

        # Delegate to CompressionManager's Test-SEBArchive
        $testParams = @{
            ArchivePath = $ArchivePath
        }
        if ($Session) {
            $testParams['Session'] = $Session
        }

        $archiveValid = Test-SEBArchive @testParams

        if ($archiveValid) {
            $result.Passed = $true
            Write-Verbose "IntegrityManager: Level 1 PASSED for '$ArchivePath'"

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 1 PASSED: $ArchivePath" -Level INFO -Context 'Integrity'
            }
        }
        else {
            $result.ErrorMessage = "Archive failed internal integrity test."
            Write-Verbose "IntegrityManager: Level 1 FAILED for '$ArchivePath'"

            if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
                Write-SEBLog -Message "Level 1 FAILED: $ArchivePath" -Level ERROR -Context 'Integrity'
            }
        }
    }
    catch {
        $result.ErrorMessage = "Level 1 check error: $_"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Level 1 check error for '$ArchivePath': $_" -Level ERROR -Context 'Integrity'
        }
    }

    return $result
}
