function Test-SEBConfig {
    <#
    .SYNOPSIS
        Validates an SEBackup configuration for required fields, types, and values.

    .DESCRIPTION
        Performs structural and semantic validation on a configuration hashtable or
        TOML file. Checks that required fields are present, values have the expected
        types, and paths look syntactically valid.

        Supports three configuration types:
        - Global:   Validates the global.toml structure (storage, retention, schedule, etc.)
        - Node:     Validates a node configuration (hostname, username, display_name)
        - Instance: Validates an instance configuration (instance name, torch paths, VRage API)

        Returns a validation result object containing:
        - IsValid:   Boolean indicating whether the config passed all checks
        - Errors:    Array of critical issues that must be fixed
        - Warnings:  Array of non-critical issues or recommendations

    .PARAMETER Type
        The type of configuration to validate. Must be one of: Global, Node, Instance.

    .PARAMETER Path
        The filesystem path to a TOML file to validate. The file is read, parsed,
        and then validated. Cannot be combined with -Config.

    .PARAMETER Config
        A hashtable containing the configuration to validate. Use this when you
        already have a parsed configuration in memory. Cannot be combined with -Path.

    .EXAMPLE
        # Validate a TOML file on disk
        $result = Test-SEBConfig -Type Global -Path 'C:\SEBackup\Config\global.toml'
        if (-not $result.IsValid) { $result.Errors | ForEach-Object { Write-Host "ERROR: $_" } }

    .EXAMPLE
        # Validate an in-memory config
        $config = Get-SEBGlobalConfig
        $result = Test-SEBConfig -Type Global -Config $config
        Write-Host "Valid: $($result.IsValid), Warnings: $($result.Warnings.Count)"

    .EXAMPLE
        # Validate a node config file
        $result = Test-SEBConfig -Type Node -Path './Config/nodes/gamingpc01.toml'
        $result.Errors
        $result.Warnings

    .OUTPUTS
        System.Management.Automation.PSCustomObject
        An object with properties: IsValid (bool), Errors (string[]), Warnings (string[]).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByPath')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Global', 'Node', 'Instance')]
        [string]$Type,

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'ByConfig')]
        [hashtable]$Config
    )

    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Load from file if -Path was provided
    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            $errors.Add("Config file not found: $Path")
            return [PSCustomObject]@{
                IsValid  = $false
                Errors   = $errors.ToArray()
                Warnings = $warnings.ToArray()
            }
        }

        try {
            $rawToml = Get-Content -Path $Path -Raw -ErrorAction Stop
            $Config = ConvertFrom-Toml -InputObject $rawToml
            if ($null -eq $Config) {
                $errors.Add("TOML file parsed to null: $Path")
                return [PSCustomObject]@{
                    IsValid  = $false
                    Errors   = $errors.ToArray()
                    Warnings = $warnings.ToArray()
                }
            }
            # Normalize the parsed config to a hashtable tree. ConvertFrom-Toml's nested tables are
            # ordered dictionaries (and depending on the host/PSToml load context the top level may
            # be a hashtable while its children are still OrderedDictionary), but the Test-*Config
            # helpers gate nested sections with "-is [hashtable]". Deep-convert unconditionally
            # (the converter is a no-op for values already hashtables) so a perfectly valid file no
            # longer fails with "[instance] must be a table/section, got: OrderedDictionary".
            $Config = Convert-PSObjectToHashtable -InputObject $Config
        }
        catch {
            $errors.Add("Failed to parse TOML file '$Path': $_")
            return [PSCustomObject]@{
                IsValid  = $false
                Errors   = $errors.ToArray()
                Warnings = $warnings.ToArray()
            }
        }
    }

    # Dispatch to type-specific validation
    switch ($Type) {
        'Global'   { Test-GlobalConfig -Config $Config -Errors $errors -Warnings $warnings }
        'Node'     { Test-NodeConfig -Config $Config -Errors $errors -Warnings $warnings }
        'Instance' { Test-InstanceConfig -Config $Config -Errors $errors -Warnings $warnings }
    }

    return [PSCustomObject]@{
        IsValid  = ($errors.Count -eq 0)
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}

#region Private validation helpers

function Test-GlobalConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [System.Collections.Generic.List[string]]$Errors,
        [System.Collections.Generic.List[string]]$Warnings
    )

    # --- [storage] section ---
    if (-not $Config.ContainsKey('storage')) {
        $Errors.Add("[storage] section is missing.")
    }
    else {
        $storage = $Config.storage
        if (-not ($storage -is [hashtable])) {
            $Errors.Add("[storage] must be a table/section, got: $($storage.GetType().Name)")
        }
        else {
            if ([string]::IsNullOrWhiteSpace($storage.cc_backup_root)) {
                $Errors.Add("[storage].cc_backup_root is required and must not be empty.")
            }
            elseif ($storage.cc_backup_root -notmatch '^[A-Za-z]:\\' -and $storage.cc_backup_root -notmatch '^\\\\') {
                $Warnings.Add("[storage].cc_backup_root does not look like a valid Windows path: $($storage.cc_backup_root)")
            }

            if (-not $storage.ContainsKey('nas_backup_path')) {
                $Warnings.Add("[storage].nas_backup_path is not set. NAS offloading will be disabled.")
            }
        }
    }

    # --- [retention] section ---
    if (-not $Config.ContainsKey('retention')) {
        $Warnings.Add("[retention] section is missing. Defaults will be used.")
    }
    else {
        $retention = $Config.retention
        if ($retention -is [hashtable]) {
            if ($retention.ContainsKey('cc_full_count') -and $retention.cc_full_count -isnot [int] -and $retention.cc_full_count -isnot [long]) {
                $Errors.Add("[retention].cc_full_count must be an integer, got: $($retention.cc_full_count.GetType().Name)")
            }
            if ($retention.ContainsKey('nas_retention_days') -and $retention.nas_retention_days -isnot [int] -and $retention.nas_retention_days -isnot [long]) {
                $Errors.Add("[retention].nas_retention_days must be an integer, got: $($retention.nas_retention_days.GetType().Name)")
            }
        }
    }

    # --- [schedule] section ---
    if (-not $Config.ContainsKey('schedule')) {
        $Warnings.Add("[schedule] section is missing. Scheduling will use defaults.")
    }
    else {
        $schedule = $Config.schedule
        if ($schedule -is [hashtable]) {
            if ($schedule.ContainsKey('enabled') -and $schedule.enabled -isnot [bool]) {
                $Errors.Add("[schedule].enabled must be a boolean.")
            }
            if ($schedule.ContainsKey('interval_hours') -and $schedule.interval_hours -isnot [int] -and $schedule.interval_hours -isnot [long]) {
                $Errors.Add("[schedule].interval_hours must be an integer.")
            }
            if ($schedule.ContainsKey('start_time') -and $schedule.start_time -is [string]) {
                if ($schedule.start_time -notmatch '^\d{1,2}:\d{2}$') {
                    $Warnings.Add("[schedule].start_time should be in HH:mm format, got: $($schedule.start_time)")
                }
            }
            if ($schedule.ContainsKey('max_incremental_chain_length')) {
                $val = $schedule.max_incremental_chain_length
                if ($val -is [int] -or $val -is [long]) {
                    if ($val -lt 1) {
                        $Errors.Add("[schedule].max_incremental_chain_length must be at least 1.")
                    }
                }
            }
        }
    }

    # --- [compression] section ---
    if ($Config.ContainsKey('compression') -and $Config.compression -is [hashtable]) {
        $compression = $Config.compression
        if ($compression.ContainsKey('engine')) {
            $validEngines = @('auto', '7zip', 'dotnet')
            if ($compression.engine -notin $validEngines) {
                $Errors.Add("[compression].engine must be one of: $($validEngines -join ', '). Got: $($compression.engine)")
            }
        }
        if ($compression.ContainsKey('level_7zip')) {
            $level = $compression.level_7zip
            if (($level -is [int] -or $level -is [long]) -and ($level -lt 1 -or $level -gt 9)) {
                $Warnings.Add("[compression].level_7zip should be between 1 (fastest) and 9 (best). Got: $level")
            }
        }
    }

    # --- [network] section ---
    if ($Config.ContainsKey('network') -and $Config.network -is [hashtable]) {
        $network = $Config.network
        if ($network.ContainsKey('max_bandwidth_mbps') -and $network.max_bandwidth_mbps -isnot [int] -and $network.max_bandwidth_mbps -isnot [long]) {
            $Errors.Add("[network].max_bandwidth_mbps must be an integer.")
        }
    }

    # --- [load_awareness] section ---
    if ($Config.ContainsKey('load_awareness') -and $Config.load_awareness -is [hashtable]) {
        $la = $Config.load_awareness
        if ($la.ContainsKey('max_cpu_percent')) {
            $val = $la.max_cpu_percent
            if (($val -is [int] -or $val -is [long] -or $val -is [double]) -and ($val -lt 1 -or $val -gt 100)) {
                $Errors.Add("[load_awareness].max_cpu_percent must be between 1 and 100. Got: $val")
            }
        }
        if ($la.ContainsKey('max_memory_percent')) {
            $val = $la.max_memory_percent
            if (($val -is [int] -or $val -is [long] -or $val -is [double]) -and ($val -lt 1 -or $val -gt 100)) {
                $Errors.Add("[load_awareness].max_memory_percent must be between 1 and 100. Got: $val")
            }
        }
        if ($la.ContainsKey('sim_speed_threshold')) {
            $val = $la.sim_speed_threshold
            if (($val -is [double] -or $val -is [float]) -and ($val -le 0.0 -or $val -gt 1.0)) {
                $Warnings.Add("[load_awareness].sim_speed_threshold is typically between 0.0 and 1.0. Got: $val")
            }
        }
    }

    # --- [defaults] section ---
    if ($Config.ContainsKey('defaults') -and $Config.defaults -is [hashtable]) {
        $defaults = $Config.defaults
        if ($defaults.ContainsKey('vrage_api') -and $defaults.vrage_api -is [hashtable]) {
            $vrageApi = $defaults.vrage_api
            if ($vrageApi.ContainsKey('port')) {
                $port = $vrageApi.port
                if (($port -is [int] -or $port -is [long]) -and ($port -lt 1 -or $port -gt 65535)) {
                    $Errors.Add("[defaults.vrage_api].port must be between 1 and 65535. Got: $port")
                }
            }
            if ($vrageApi.ContainsKey('save_timeout_seconds')) {
                $timeout = $vrageApi.save_timeout_seconds
                if (($timeout -is [int] -or $timeout -is [long]) -and $timeout -lt 1) {
                    $Errors.Add("[defaults.vrage_api].save_timeout_seconds must be positive. Got: $timeout")
                }
            }
        }
        if ($defaults.ContainsKey('vss') -and $defaults.vss -is [hashtable]) {
            $vss = $defaults.vss
            if ([string]::IsNullOrWhiteSpace($vss.mount_base)) {
                $Warnings.Add("[defaults.vss].mount_base is empty. VSS mount path will need to be configured.")
            }
        }
    }
}

function Test-NodeConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [System.Collections.Generic.List[string]]$Errors,
        [System.Collections.Generic.List[string]]$Warnings
    )

    if (-not $Config.ContainsKey('node')) {
        $Errors.Add("[node] section is missing.")
        return
    }

    $node = $Config.node
    if (-not ($node -is [hashtable])) {
        $Errors.Add("[node] must be a table/section, got: $($node.GetType().Name)")
        return
    }

    # Required fields
    if ([string]::IsNullOrWhiteSpace($node.hostname)) {
        $Errors.Add("[node].hostname is required and must not be empty.")
    }
    else {
        # Basic hostname/IP validation
        $hostname = $node.hostname
        $isIp = $hostname -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
        $isDns = $hostname -match '^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$'
        if (-not $isIp -and -not $isDns) {
            $Warnings.Add("[node].hostname does not look like a valid hostname or IP address: $hostname")
        }
    }

    if ([string]::IsNullOrWhiteSpace($node.username)) {
        $Errors.Add("[node].username is required and must not be empty.")
    }

    if ([string]::IsNullOrWhiteSpace($node.display_name)) {
        $Warnings.Add("[node].display_name is not set. The node name will be used for display purposes.")
    }
}

function Test-InstanceConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [System.Collections.Generic.List[string]]$Errors,
        [System.Collections.Generic.List[string]]$Warnings
    )

    # The instance schema validated here is the canonical one the SEBackup engine reads:
    # the operational values are FLAT top-level keys (world_path, staging_path, share_name,
    # run_mode) plus a nested [vrage_api] table (port / security_key), with [instance] holding
    # identity metadata. Legacy layouts ([paths]/[smb]/[vss], [vrage_api].key) are accepted with
    # a warning -- Get-SEBInstanceConfig normalizes them onto the canonical keys at load time.

    # --- [instance] section (identity metadata) ---
    if (-not $Config.ContainsKey('instance')) {
        $Errors.Add("[instance] section is missing.")
    }
    else {
        $instance = $Config.instance
        if (-not ($instance -is [hashtable])) {
            $Errors.Add("[instance] must be a table/section, got: $($instance.GetType().Name)")
        }
        else {
            if ([string]::IsNullOrWhiteSpace($instance.name)) {
                $Errors.Add("[instance].name is required and must not be empty.")
            }
            if ([string]::IsNullOrWhiteSpace($instance.display_name)) {
                $Warnings.Add("[instance].display_name is not set. The instance name will be used.")
            }
        }
    }

    # --- world_path (top-level, required) ---
    # Accept the legacy [paths].world_save location with a migration warning.
    $worldPath = $null
    if ($Config.ContainsKey('world_path')) {
        $worldPath = $Config['world_path']
    }
    elseif ($Config.ContainsKey('paths') -and $Config.paths -is [hashtable] -and -not [string]::IsNullOrWhiteSpace($Config.paths.world_save)) {
        $worldPath = $Config.paths.world_save
        $Warnings.Add("World path found under legacy [paths].world_save. Re-register this instance (or move it to a top-level 'world_path') so it matches the current schema.")
    }

    if ([string]::IsNullOrWhiteSpace($worldPath)) {
        $Errors.Add("'world_path' is required (top-level key) and must not be empty. It is the world save folder the engine snapshots and restores.")
    }
    elseif ($worldPath -notmatch '^[A-Za-z]:\\') {
        $Warnings.Add("'world_path' does not look like an absolute Windows path: $worldPath")
    }

    # --- share_name (top-level, required for archive transfer) ---
    $shareName = $null
    if ($Config.ContainsKey('share_name')) {
        $shareName = $Config['share_name']
    }
    elseif ($Config.ContainsKey('smb') -and $Config.smb -is [hashtable] -and -not [string]::IsNullOrWhiteSpace($Config.smb.share_name)) {
        $shareName = $Config.smb.share_name
        $Warnings.Add("Share name found under legacy [smb].share_name. Re-register this instance (or move it to a top-level 'share_name') so it matches the current schema.")
    }

    if ([string]::IsNullOrWhiteSpace($shareName)) {
        $Errors.Add("'share_name' is required (top-level key). The C&C pulls finished archives from this SMB share on the node.")
    }

    # --- staging_path (top-level, optional; defaults to C:\SEBackup\staging) ---
    if (-not $Config.ContainsKey('staging_path') -and
        -not ($Config.ContainsKey('paths') -and $Config.paths -is [hashtable] -and $Config.paths.ContainsKey('staging_local'))) {
        $Warnings.Add("'staging_path' is not set. The engine will default to 'C:\\SEBackup\\staging'.")
    }

    # --- run_mode (top-level, optional; defaults to service) ---
    $runMode = if ($Config.ContainsKey('run_mode')) {
        $Config['run_mode']
    }
    elseif ($Config.ContainsKey('instance') -and $Config.instance -is [hashtable]) {
        $Config.instance.run_mode
    }
    else { $null }
    if (-not [string]::IsNullOrWhiteSpace($runMode) -and $runMode -notin @('service', 'console')) {
        $Warnings.Add("'run_mode' should be 'service' or 'console'. Got: $runMode")
    }

    # --- [vrage_api] section ---
    if ($Config.ContainsKey('vrage_api') -and $Config.vrage_api -is [hashtable]) {
        $vrageApi = $Config.vrage_api
        if ($vrageApi.ContainsKey('port')) {
            $port = $vrageApi.port
            if (($port -is [int] -or $port -is [long]) -and ($port -lt 1 -or $port -gt 65535)) {
                $Errors.Add("[vrage_api].port must be between 1 and 65535. Got: $port")
            }
        }
        if ($vrageApi.ContainsKey('key') -and -not $vrageApi.ContainsKey('security_key')) {
            $Warnings.Add("[vrage_api].key is the legacy key name. The engine reads [vrage_api].security_key -- rename it (or re-register the instance).")
        }
        if ($vrageApi.ContainsKey('security_key') -and [string]::IsNullOrWhiteSpace($vrageApi.security_key)) {
            $Warnings.Add("[vrage_api].security_key is empty. The pre-backup world save and post-restore API ping will be skipped.")
        }
    }
    else {
        $Warnings.Add("[vrage_api] section is not set. Global defaults will be used and no security key will be available.")
    }

    # --- [backup] section (optional metadata) ---
    if ($Config.ContainsKey('backup') -and $Config.backup -is [hashtable]) {
        $backup = $Config.backup
        if ($backup.ContainsKey('enabled') -and $backup.enabled -isnot [bool]) {
            $Errors.Add("[backup].enabled must be a boolean.")
        }
        if ($backup.ContainsKey('priority') -and $backup.priority -is [string]) {
            $validPriorities = @('low', 'normal', 'high')
            if ($backup.priority -notin $validPriorities) {
                $Warnings.Add("[backup].priority should be one of: $($validPriorities -join ', '). Got: $($backup.priority)")
            }
        }
    }
}

#endregion
