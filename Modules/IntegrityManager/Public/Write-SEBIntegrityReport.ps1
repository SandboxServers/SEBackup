function Write-SEBIntegrityReport {
    <#
    .SYNOPSIS
        Writes or updates the integrity report for a server instance.

    .DESCRIPTION
        Serializes the provided report object to JSON and writes it to the
        instance's integrity report file at:

            {BackupRoot}\{InstanceName}\integrity_report.json

        If the instance directory does not exist, it is created automatically.
        Any existing report file is overwritten with the new content.

        This function is typically called after running Test-SEBChainIntegrity
        or a batch of integrity checks, to persist the results for later
        retrieval via Get-SEBIntegrityReport.

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose integrity
        report to write.

    .PARAMETER BackupRoot
        The root path of the backup storage directory (e.g., C:\SEBackup\Backups).

    .PARAMETER Report
        The report object to serialize and write. This can be any PowerShell
        object; it will be converted to JSON with a depth of 10 for nested
        structures.

    .EXAMPLE
        $report = @{
            last_checked   = [datetime]::UtcNow.ToString('o')
            chain_results  = @($chainResult)
            overall_status = 'passed'
        }
        Write-SEBIntegrityReport -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups" -Report $report

    .EXAMPLE
        # Run a chain check and persist the results
        $chainResult = Test-SEBChainIntegrity -InstanceName "Creative01" -BackupRoot "D:\Backups"
        $report = @{
            last_checked   = [datetime]::UtcNow.ToString('o')
            chain_results  = @($chainResult)
            overall_status = if ($chainResult.Passed) { 'passed' } else { 'failed' }
        }
        Write-SEBIntegrityReport -InstanceName "Creative01" -BackupRoot "D:\Backups" -Report $report

    .OUTPUTS
        None

    .LINK
        Get-SEBIntegrityReport
        Test-SEBChainIntegrity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter(Mandatory, Position = 2)]
        [ValidateNotNull()]
        [object]$Report
    )

    # $InstanceName becomes a directory segment, and this function CREATES that directory and WRITES a
    # file under it -- a write boundary. Guard it through the shared Test-SEBSafeName validator
    # (issue #28) so a crafted name cannot create/overwrite a file outside the backup root. Write-Error
    # + return matches this function's existing error-reporting contract (it does not throw).
    if (-not (Test-SEBSafeName -Name $InstanceName)) {
        Write-Error "Invalid InstanceName '$InstanceName': path separators, traversal, rooted paths, wildcards, and invalid filename characters are not allowed."
        return
    }

    $instanceDir = Join-Path -Path $BackupRoot -ChildPath $InstanceName
    $reportPath = Join-Path -Path $instanceDir -ChildPath 'integrity_report.json'

    try {
        # Ensure the instance directory exists
        if (-not (Test-Path -Path $instanceDir -PathType Container)) {
            Write-Verbose "IntegrityManager: Creating instance directory '$instanceDir'"
            New-Item -Path $instanceDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        # Serialize and write the report
        $json = $Report | ConvertTo-Json -Depth 10 -ErrorAction Stop
        Set-Content -Path $reportPath -Value $json -Encoding UTF8 -Force -ErrorAction Stop

        Write-Verbose "IntegrityManager: Wrote integrity report to '$reportPath'"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Integrity report written for instance '$InstanceName'" -Level INFO -Context 'Integrity'
        }
    }
    catch {
        $errorMsg = "Failed to write integrity report to '$reportPath': $_"
        Write-Error $errorMsg

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message $errorMsg -Level ERROR -Context 'Integrity'
        }
    }
}
