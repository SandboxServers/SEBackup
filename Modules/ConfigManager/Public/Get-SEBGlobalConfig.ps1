function Get-SEBGlobalConfig {
    <#
    .SYNOPSIS
        Reads and returns the SEBackup global configuration from global.toml.

    .DESCRIPTION
        Loads the global.toml configuration file and returns its contents as a
        hashtable. The file location is resolved via Resolve-ConfigPaths, which
        looks for Config/global.toml relative to the project root.

        Results are cached in a module-scoped variable with a configurable TTL
        (default 60 seconds). Subsequent calls within the TTL window return the
        cached copy without re-reading the file. Use the -Force switch to bypass
        the cache and reload from disk.

        Any sections or keys missing from the file are filled in from a built-in
        defaults hashtable, ensuring all expected configuration keys are always
        present in the returned object.

    .PARAMETER CacheTTLSeconds
        The number of seconds to cache the parsed configuration before re-reading
        from disk. Defaults to 60. Set to 0 to disable caching.

    .PARAMETER Force
        Bypasses the cache and forces a fresh read from disk regardless of TTL.

    .EXAMPLE
        $config = Get-SEBGlobalConfig
        $config.storage.cc_backup_root

    .EXAMPLE
        # Force a fresh read, ignoring the cache
        $config = Get-SEBGlobalConfig -Force

    .EXAMPLE
        # Use a longer cache window
        $config = Get-SEBGlobalConfig -CacheTTLSeconds 300

    .OUTPUTS
        System.Collections.Hashtable
        The global configuration as a hashtable with all sections populated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [int]$CacheTTLSeconds = 60,

        [Parameter()]
        [switch]$Force
    )

    # Check cache validity unless Force is specified
    if (-not $Force -and $script:CachedGlobalConfig) {
        $elapsed = ([datetime]::UtcNow - $script:CachedGlobalConfigTime).TotalSeconds
        if ($elapsed -lt $CacheTTLSeconds) {
            Write-Verbose "Returning cached global config (age: $([math]::Round($elapsed, 1))s, TTL: ${CacheTTLSeconds}s)"
            return $script:CachedGlobalConfig
        }
    }

    # Resolve paths
    $paths = Resolve-ConfigPaths

    if (-not (Test-Path -Path $paths.GlobalToml -PathType Leaf)) {
        Write-Warning "Global config not found at: $($paths.GlobalToml). Returning defaults only."
        $fileConfig = @{}
    }
    else {
        Write-Verbose "Reading global config from: $($paths.GlobalToml)"
        try {
            $rawToml = Get-Content -Path $paths.GlobalToml -Raw -ErrorAction Stop
            $fileConfig = ConvertFrom-Toml -InputObject $rawToml
            if ($null -eq $fileConfig) {
                $fileConfig = @{}
            }
        }
        catch {
            Write-Error "Failed to parse global.toml: $_"
            return $null
        }
    }

    # Built-in defaults for all expected sections
    $defaults = @{
        storage = @{
            cc_backup_root  = 'C:\SEBackup\Backups'
            nas_backup_path = ''
        }
        retention = @{
            cc_full_count      = 2
            nas_retention_days = 90
        }
        schedule = @{
            enabled                       = $true
            interval_hours                = 6
            full_backup_interval_hours    = 168
            max_incremental_chain_length  = 48
            start_time                    = '02:00'
        }
        compression = @{
            engine      = 'auto'
            level_7zip  = 5
        }
        network = @{
            max_bandwidth_mbps = 100
            robocopy_ipg_ms    = 0
        }
        load_awareness = @{
            enabled                     = $true
            max_cpu_percent             = 80
            max_memory_percent          = 85
            sim_speed_threshold         = 0.8
            check_interval_seconds      = 30
            backoff_multiplier          = 2.0
            max_backoff_minutes         = 60
        }
        notifications = @{
            enabled       = $false
            on_success    = $false
            on_failure    = $true
            on_warning    = $true
            webhook_url   = ''
            method        = 'discord'
        }
        defaults = @{
            vrage_api = @{
                port                 = 8080
                save_timeout_seconds = 120
            }
            vss = @{
                mount_base = 'C:\SEBackup\vss_mount'
            }
        }
    }

    # Deep-merge file config over defaults (file values win)
    $merged = Merge-ConfigOverrides -Default $defaults -Override $fileConfig

    # Update cache
    $script:CachedGlobalConfig = $merged
    $script:CachedGlobalConfigTime = [datetime]::UtcNow
    $script:CacheTTLSeconds = $CacheTTLSeconds

    return $merged
}
