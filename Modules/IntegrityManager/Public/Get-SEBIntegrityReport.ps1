function Get-SEBIntegrityReport {
    <#
    .SYNOPSIS
        Reads the integrity report for a server instance from disk.

    .DESCRIPTION
        Loads and returns the integrity report JSON file for the specified
        Space Engineers server instance. The report is stored at:

            {BackupRoot}\{InstanceName}\integrity_report.json

        If no report file exists, the function returns $null. This allows
        callers to distinguish between "no report has been generated" and
        "a report was generated and contains data".

    .PARAMETER InstanceName
        The name of the Space Engineers server instance whose integrity
        report to read.

    .PARAMETER BackupRoot
        The root path of the backup storage directory (e.g., C:\SEBackup\Backups).
        The integrity report is located under the instance's subdirectory within
        this root.

    .EXAMPLE
        $report = Get-SEBIntegrityReport -InstanceName "PvPArena" -BackupRoot "C:\SEBackup\Backups"
        if ($report) {
            Write-Host "Last check: $($report.last_checked)"
        } else {
            Write-Host "No integrity report found."
        }

    .EXAMPLE
        $report = Get-SEBIntegrityReport -InstanceName "Creative01" -BackupRoot "D:\Backups"
        $report.chain_results | Format-Table

    .OUTPUTS
        PSCustomObject or $null
        The deserialized integrity report object, or $null if no report exists.

    .LINK
        Write-SEBIntegrityReport
        Test-SEBChainIntegrity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot
    )

    $reportPath = Join-Path -Path $BackupRoot -ChildPath $InstanceName |
        Join-Path -ChildPath 'integrity_report.json'

    Write-Verbose "IntegrityManager: Looking for integrity report at '$reportPath'"

    if (-not (Test-Path -Path $reportPath -PathType Leaf)) {
        Write-Verbose "IntegrityManager: No integrity report found for instance '$InstanceName'"
        return $null
    }

    try {
        $reportRaw = Get-Content -Path $reportPath -Raw -ErrorAction Stop
        $report = $reportRaw | ConvertFrom-Json -ErrorAction Stop

        Write-Verbose "IntegrityManager: Loaded integrity report for instance '$InstanceName'"
        return $report
    }
    catch {
        Write-Warning "IntegrityManager: Failed to read integrity report at '$reportPath': $_"
        return $null
    }
}
