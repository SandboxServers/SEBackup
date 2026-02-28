function Get-SEBNodeMetrics {
    <#
    .SYNOPSIS
        Retrieves current node metrics (CPU, memory, disk) from a remote server.

    .DESCRIPTION
        Collects raw performance metrics from a remote game server node without
        comparing them against any thresholds. This function is designed for
        display purposes in the GUI dashboard and diagnostics panel.

        Metrics collected:
        - CPU: Per-processor load percentage and average across all processors.
        - Memory: Total physical memory, free physical memory, used percentage.
        - Disk: For each logical disk, total size, free space, and used percentage.

        All data is gathered via CIM (WMI) queries over the provided PSSession.

    .PARAMETER Session
        An open PSSession to the remote game server node.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $metrics = Get-SEBNodeMetrics -Session $session
        Write-Host "CPU: $($metrics.Cpu.AveragePercent)%"
        Write-Host "Memory: $($metrics.Memory.UsedPercent)% used ($($metrics.Memory.AvailableMB)MB free)"
        $metrics.Disks | Format-Table DriveLetter, TotalGB, FreeGB, UsedPercent

    .EXAMPLE
        $metrics = Get-SEBNodeMetrics -Session $session
        # Display in a GUI data grid
        $metricsGrid.ItemsSource = @($metrics)

    .OUTPUTS
        PSCustomObject
        An object with properties:
        - Cpu: { AveragePercent, Processors (array of per-CPU load) }
        - Memory: { TotalMB, AvailableMB, UsedPercent }
        - Disks: Array of { DriveLetter, TotalGB, FreeGB, UsedPercent }
        - CollectedAt: UTC timestamp of when metrics were gathered.

    .LINK
        Test-SEBNodeLoad
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $result = [PSCustomObject]@{
        Cpu         = $null
        Memory      = $null
        Disks       = @()
        CollectedAt = [datetime]::UtcNow
    }

    try {
        # Gather all metrics in a single remote invocation for efficiency
        $remoteMetrics = Invoke-Command -Session $Session -ScriptBlock {
            $metrics = @{}

            # --- CPU ---
            try {
                $cpuData = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
                $loadValues = @($cpuData | Select-Object -ExpandProperty LoadPercentage)
                $avgLoad = if ($loadValues.Count -gt 0) {
                    ($loadValues | Measure-Object -Average).Average
                } else { 0 }

                $metrics['Cpu'] = @{
                    AveragePercent = [math]::Round($avgLoad, 1)
                    Processors     = $loadValues
                }
            }
            catch {
                $metrics['Cpu'] = @{
                    AveragePercent = -1
                    Processors     = @()
                    Error          = $_.ToString()
                }
            }

            # --- Memory ---
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
                $freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
                $usedPercent = if ($totalMB -gt 0) {
                    [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1)
                } else { 0 }

                $metrics['Memory'] = @{
                    TotalMB      = $totalMB
                    AvailableMB  = $freeMB
                    UsedPercent  = $usedPercent
                }
            }
            catch {
                $metrics['Memory'] = @{
                    TotalMB     = 0
                    AvailableMB = 0
                    UsedPercent = -1
                    Error       = $_.ToString()
                }
            }

            # --- Disks ---
            try {
                $diskData = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
                $disks = foreach ($disk in $diskData) {
                    $totalGB = [math]::Round($disk.Size / 1GB, 1)
                    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
                    $usedPct = if ($totalGB -gt 0) {
                        [math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 1)
                    } else { 0 }

                    @{
                        DriveLetter = $disk.DeviceID
                        TotalGB     = $totalGB
                        FreeGB      = $freeGB
                        UsedPercent = $usedPct
                    }
                }
                $metrics['Disks'] = @($disks)
            }
            catch {
                $metrics['Disks'] = @()
            }

            return $metrics
        } -ErrorAction Stop

        # Map remote results to structured output objects
        if ($remoteMetrics.Cpu) {
            $result.Cpu = [PSCustomObject]@{
                AveragePercent = $remoteMetrics.Cpu.AveragePercent
                Processors     = $remoteMetrics.Cpu.Processors
            }
        }

        if ($remoteMetrics.Memory) {
            $result.Memory = [PSCustomObject]@{
                TotalMB     = $remoteMetrics.Memory.TotalMB
                AvailableMB = $remoteMetrics.Memory.AvailableMB
                UsedPercent = $remoteMetrics.Memory.UsedPercent
            }
        }

        if ($remoteMetrics.Disks) {
            $result.Disks = foreach ($disk in $remoteMetrics.Disks) {
                [PSCustomObject]@{
                    DriveLetter = $disk.DriveLetter
                    TotalGB     = $disk.TotalGB
                    FreeGB      = $disk.FreeGB
                    UsedPercent = $disk.UsedPercent
                }
            }
        }

        Write-Verbose "LoadMonitor: Collected metrics -- CPU=$($result.Cpu.AveragePercent)%, Memory=$($result.Memory.UsedPercent)% used, Disks=$($result.Disks.Count)"
    }
    catch {
        Write-Warning "LoadMonitor: Failed to collect node metrics: $_"

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Failed to collect node metrics: $_" -Level ERROR -Context 'LoadMonitor'
        }
    }

    return $result
}
