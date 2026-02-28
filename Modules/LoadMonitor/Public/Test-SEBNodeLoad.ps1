function Test-SEBNodeLoad {
    <#
    .SYNOPSIS
        Checks if a remote node is under acceptable load for a backup operation.

    .DESCRIPTION
        Evaluates the current load on a remote game server node by checking three
        metrics against configurable thresholds:

        1. Player count -- retrieved via Get-SEBServerInfo from the VRage Remote
           API. A high player count indicates an active server that should not be
           burdened with a backup operation.
        2. CPU usage -- queried via Get-CimInstance Win32_Processor on the remote
           node. Sustained high CPU indicates the server is already under pressure.
        3. Available memory -- queried via Get-CimInstance Win32_OperatingSystem
           on the remote node. Low available memory increases the risk of backup
           operations causing performance issues.

        Thresholds are read from the global configuration's [load_awareness]
        section. If load_awareness.enabled is $false, the function always returns
        CanProceed = $true without performing any checks.

    .PARAMETER Session
        An open PSSession to the remote game server node.

    .PARAMETER InstanceConfig
        A hashtable containing the instance configuration. Must include vrage_api
        settings (hostname, port, security_key) for player count queries.

    .PARAMETER GlobalConfig
        A hashtable containing the global configuration. Must include the
        load_awareness section with threshold values.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $instanceCfg = Get-SEBInstanceConfig -InstanceName "PvPArena"
        $globalCfg = Get-SEBGlobalConfig
        $loadCheck = Test-SEBNodeLoad -Session $session -InstanceConfig $instanceCfg -GlobalConfig $globalCfg
        if ($loadCheck.CanProceed) {
            Write-Host "Node is clear for backup"
        } else {
            $loadCheck.Reasons | ForEach-Object { Write-Warning $_ }
        }

    .EXAMPLE
        # When load awareness is disabled, always proceeds
        $globalCfg = @{ load_awareness = @{ enabled = $false } }
        $result = Test-SEBNodeLoad -Session $session -InstanceConfig $cfg -GlobalConfig $globalCfg
        $result.CanProceed  # Always $true

    .OUTPUTS
        PSCustomObject
        An object with properties: CanProceed (bool), PlayerCount (int),
        CpuPercent (double), AvailableMemoryMB (long), Reasons (string[]).

    .LINK
        Wait-SEBNodeLoad
        Get-SEBNodeMetrics
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [hashtable]$InstanceConfig,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig
    )

    $result = [PSCustomObject]@{
        CanProceed       = $true
        PlayerCount      = 0
        CpuPercent       = 0.0
        AvailableMemoryMB = 0
        Reasons          = @()
    }

    # Check if load awareness is enabled
    $loadConfig = $GlobalConfig['load_awareness']
    if (-not $loadConfig -or -not $loadConfig['enabled']) {
        Write-Verbose "LoadMonitor: Load awareness is disabled, proceeding without checks."
        return $result
    }

    $reasons = [System.Collections.Generic.List[string]]::new()

    # --- Thresholds ---
    $maxCpuPercent    = if ($loadConfig['max_cpu_percent'])    { [double]$loadConfig['max_cpu_percent'] }    else { 80.0 }
    $maxMemoryPercent = if ($loadConfig['max_memory_percent']) { [double]$loadConfig['max_memory_percent'] } else { 85.0 }
    $maxPlayerCount   = if ($loadConfig['max_player_count'])   { [int]$loadConfig['max_player_count'] }     else { 0 }

    # --- 1. Player count via VRage API ---
    try {
        $playerCount = Get-SEBPlayerCount -InstanceConfig $InstanceConfig
        $result.PlayerCount = $playerCount

        if ($maxPlayerCount -gt 0 -and $playerCount -gt $maxPlayerCount) {
            $reasons.Add("Player count ($playerCount) exceeds threshold ($maxPlayerCount)")
        }

        Write-Verbose "LoadMonitor: Player count = $playerCount (threshold: $maxPlayerCount)"
    }
    catch {
        Write-Verbose "LoadMonitor: Failed to retrieve player count, defaulting to 0: $_"
        $result.PlayerCount = 0
    }

    # --- 2. CPU usage via CIM on the remote node ---
    try {
        $cpuPercent = Invoke-Command -Session $Session -ScriptBlock {
            $cpuSamples = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                Select-Object -ExpandProperty LoadPercentage
            if ($cpuSamples -is [array]) {
                ($cpuSamples | Measure-Object -Average).Average
            }
            else {
                [double]$cpuSamples
            }
        } -ErrorAction Stop

        $result.CpuPercent = [math]::Round($cpuPercent, 1)

        if ($cpuPercent -gt $maxCpuPercent) {
            $reasons.Add("CPU usage ($([math]::Round($cpuPercent, 1))%) exceeds threshold ($maxCpuPercent%)")
        }

        Write-Verbose "LoadMonitor: CPU usage = $([math]::Round($cpuPercent, 1))% (threshold: $maxCpuPercent%)"
    }
    catch {
        Write-Warning "LoadMonitor: Failed to retrieve CPU usage from remote node: $_"
    }

    # --- 3. Available memory via CIM on the remote node ---
    try {
        $memoryInfo = Invoke-Command -Session $Session -ScriptBlock {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            [PSCustomObject]@{
                TotalVisibleMemoryKB   = $os.TotalVisibleMemorySize
                FreePhysicalMemoryKB   = $os.FreePhysicalMemory
            }
        } -ErrorAction Stop

        $totalMemoryMB = [math]::Round($memoryInfo.TotalVisibleMemoryKB / 1024, 0)
        $freeMemoryMB = [math]::Round($memoryInfo.FreePhysicalMemoryKB / 1024, 0)
        $memoryUsedPercent = if ($totalMemoryMB -gt 0) {
            [math]::Round((($totalMemoryMB - $freeMemoryMB) / $totalMemoryMB) * 100, 1)
        } else { 0 }

        $result.AvailableMemoryMB = $freeMemoryMB

        if ($memoryUsedPercent -gt $maxMemoryPercent) {
            $reasons.Add("Memory usage ($memoryUsedPercent%) exceeds threshold ($maxMemoryPercent%). Available: ${freeMemoryMB}MB of ${totalMemoryMB}MB")
        }

        Write-Verbose "LoadMonitor: Memory usage = $memoryUsedPercent%, available = ${freeMemoryMB}MB (threshold: $maxMemoryPercent%)"
    }
    catch {
        Write-Warning "LoadMonitor: Failed to retrieve memory info from remote node: $_"
    }

    # --- Determine overall result ---
    if ($reasons.Count -gt 0) {
        $result.CanProceed = $false
        $result.Reasons = $reasons.ToArray()

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Node load check FAILED: $($reasons -join '; ')" -Level WARN -Context 'LoadMonitor'
        }
    }
    else {
        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Node load check PASSED: CPU=$($result.CpuPercent)%, Memory available=$($result.AvailableMemoryMB)MB, Players=$($result.PlayerCount)" -Level INFO -Context 'LoadMonitor'
        }
    }

    return $result
}
