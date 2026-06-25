#Requires -Module Pester

# Issue #19 -- edge-case validation coverage for Test-SEBConfig beyond the Issue #14 instance-schema
# tests in Get-SEBInstanceConfig.Tests.ps1. Those pin the instance contract; this file pins the
# GLOBAL and NODE validators and a handful of cross-cutting type/range checks:
#   * missing required sections/keys at each level produce ERRORS (IsValid = $false);
#   * wrong scalar TYPES (string where int expected, etc.) produce ERRORS;
#   * out-of-range numeric values (ports, percentages, chain length) produce ERRORS;
#   * soft issues (missing optional sections, odd-but-tolerated values) produce WARNINGS, not errors.
#
# All inputs are in-memory [hashtable]s passed via -Config (already the hashtable shape the engine
# builds), so these are pure in/out assertions -- no TOML parse, no mocks.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$script:repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # A minimal global config that PASSES, used as the base each negative test perturbs so the
    # assertion isolates the one thing under test.
    function New-ValidGlobalConfig {
        @{
            storage   = @{ cc_backup_root = 'C:\SEBackup\Backups'; nas_backup_path = '\\nas01\Backups' }
            retention = @{ cc_full_count = 5; nas_retention_days = 30 }
            schedule  = @{ enabled = $true; interval_hours = 6; start_time = '02:00'; max_incremental_chain_length = 7 }
            compression    = @{ engine = 'auto'; level_7zip = 5 }
            network        = @{ max_bandwidth_mbps = 100 }
            load_awareness = @{ max_cpu_percent = 80; max_memory_percent = 85; sim_speed_threshold = 0.8 }
            defaults  = @{
                vrage_api = @{ port = 8080; save_timeout_seconds = 120 }
                vss       = @{ mount_base = 'C:\SEBackup\vss_mount' }
            }
        }
    }

    function New-ValidNodeConfig {
        @{ node = @{ hostname = 'gamingpc01'; username = 'SEBackupSvc'; display_name = 'Gaming PC 01' } }
    }
}

Describe 'Test-SEBConfig -Type Global' {

    It 'reports a complete, well-typed global config as valid' {
        $result = Test-SEBConfig -Type Global -Config (New-ValidGlobalConfig)
        $result.IsValid | Should -BeTrue -Because "validator errors: $($result.Errors -join '; ')"
    }

    Context 'missing required keys' {
        It 'errors when the [storage] section is missing entirely' {
            $cfg = New-ValidGlobalConfig
            $cfg.Remove('storage')
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'storage'
        }

        It 'errors when [storage].cc_backup_root is empty' {
            $cfg = New-ValidGlobalConfig
            $cfg.storage.cc_backup_root = ''
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'cc_backup_root'
        }

        It 'warns (not errors) when an optional section like [retention] is absent' {
            $cfg = New-ValidGlobalConfig
            $cfg.Remove('retention')
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeTrue -Because 'retention is optional with defaults'
            ($result.Warnings -join ' ') | Should -Match 'retention'
        }

        It 'warns when [storage].nas_backup_path is not set' {
            $cfg = New-ValidGlobalConfig
            $cfg.storage.Remove('nas_backup_path')
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeTrue
            ($result.Warnings -join ' ') | Should -Match 'nas_backup_path'
        }
    }

    Context 'wrong types' {
        It 'errors when [storage] is a scalar instead of a table' {
            $cfg = New-ValidGlobalConfig
            $cfg.storage = 'not-a-table'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'storage'
        }

        It 'errors when [retention].cc_full_count is a string instead of an integer' {
            $cfg = New-ValidGlobalConfig
            $cfg.retention.cc_full_count = 'five'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'cc_full_count'
        }

        It 'errors when [schedule].enabled is not a boolean' {
            $cfg = New-ValidGlobalConfig
            $cfg.schedule.enabled = 'yes'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'enabled'
        }

        It 'errors when [schedule].interval_hours is not an integer' {
            $cfg = New-ValidGlobalConfig
            $cfg.schedule.interval_hours = '6h'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'interval_hours'
        }

        It 'errors when [network].max_bandwidth_mbps is not an integer' {
            $cfg = New-ValidGlobalConfig
            $cfg.network.max_bandwidth_mbps = 'fast'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'max_bandwidth_mbps'
        }
    }

    Context 'out-of-range values' {
        It 'errors when [defaults.vrage_api].port is above 65535' {
            $cfg = New-ValidGlobalConfig
            $cfg.defaults.vrage_api.port = 70000
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'port'
        }

        It 'errors when [defaults.vrage_api].port is below 1' {
            $cfg = New-ValidGlobalConfig
            $cfg.defaults.vrage_api.port = 0
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'port'
        }

        It 'errors when [defaults.vrage_api].save_timeout_seconds is not positive' {
            $cfg = New-ValidGlobalConfig
            $cfg.defaults.vrage_api.save_timeout_seconds = 0
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'save_timeout_seconds'
        }

        It 'errors when [schedule].max_incremental_chain_length is below 1' {
            $cfg = New-ValidGlobalConfig
            $cfg.schedule.max_incremental_chain_length = 0
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'max_incremental_chain_length'
        }

        It 'errors when [load_awareness].max_cpu_percent exceeds 100' {
            $cfg = New-ValidGlobalConfig
            $cfg.load_awareness.max_cpu_percent = 150
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'max_cpu_percent'
        }

        It 'errors when [load_awareness].max_memory_percent is below 1' {
            $cfg = New-ValidGlobalConfig
            $cfg.load_awareness.max_memory_percent = 0
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'max_memory_percent'
        }

        It 'warns (not errors) when [compression].level_7zip is outside 1-9' {
            $cfg = New-ValidGlobalConfig
            $cfg.compression.level_7zip = 12
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeTrue -Because 'an odd compression level is tolerated with a warning'
            ($result.Warnings -join ' ') | Should -Match 'level_7zip'
        }

        It 'errors when [compression].engine is not one of the allowed engines' {
            $cfg = New-ValidGlobalConfig
            $cfg.compression.engine = 'gzip'
            $result = Test-SEBConfig -Type Global -Config $cfg
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'engine'
        }
    }
}

Describe 'Test-SEBConfig -Type Node' {

    It 'reports a complete node config as valid' {
        $result = Test-SEBConfig -Type Node -Config (New-ValidNodeConfig)
        $result.IsValid | Should -BeTrue -Because "validator errors: $($result.Errors -join '; ')"
    }

    It 'errors when the [node] section is missing' {
        $result = Test-SEBConfig -Type Node -Config @{ something = 'else' }
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'node'
    }

    It 'errors when [node] is a scalar instead of a table' {
        $result = Test-SEBConfig -Type Node -Config @{ node = 'gamingpc01' }
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'node'
    }

    It 'errors when [node].hostname is empty' {
        $cfg = New-ValidNodeConfig
        $cfg.node.hostname = ''
        $result = Test-SEBConfig -Type Node -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'hostname'
    }

    It 'errors when [node].username is empty' {
        $cfg = New-ValidNodeConfig
        $cfg.node.username = ''
        $result = Test-SEBConfig -Type Node -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'username'
    }

    It 'accepts a dotted IP address as a hostname without warning' {
        $cfg = New-ValidNodeConfig
        $cfg.node.hostname = '192.168.1.50'
        $result = Test-SEBConfig -Type Node -Config $cfg
        $result.IsValid | Should -BeTrue
        ($result.Warnings -join ' ') | Should -Not -Match 'hostname'
    }

    It 'warns on a hostname that looks neither like DNS nor an IP' {
        $cfg = New-ValidNodeConfig
        $cfg.node.hostname = 'bad host name!'
        $result = Test-SEBConfig -Type Node -Config $cfg
        # Still "valid" (hostname is present) but the operator is nudged.
        $result.IsValid | Should -BeTrue
        ($result.Warnings -join ' ') | Should -Match 'hostname'
    }

    It 'warns (not errors) when [node].display_name is absent' {
        $cfg = New-ValidNodeConfig
        $cfg.node.Remove('display_name')
        $result = Test-SEBConfig -Type Node -Config $cfg
        $result.IsValid | Should -BeTrue
        ($result.Warnings -join ' ') | Should -Match 'display_name'
    }
}

Describe 'Test-SEBConfig -Type Instance (edge cases)' {

    It 'errors when the [instance] section is missing' {
        $cfg = @{
            world_path = 'C:\W\Saves\X'
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 8080; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'instance'
    }

    It 'errors when [instance].name is empty' {
        $cfg = @{
            instance   = @{ name = ''; display_name = 'X' }
            world_path = 'C:\W\Saves\X'
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 8080; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'name'
    }

    It 'errors when world_path is missing (the required top-level key)' {
        $cfg = @{
            instance   = @{ name = 'X'; display_name = 'X' }
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 8080; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'world_path'
    }

    It 'errors when share_name is missing (the required transfer key)' {
        $cfg = @{
            instance   = @{ name = 'X'; display_name = 'X' }
            world_path = 'C:\W\Saves\X'
            vrage_api  = @{ port = 8080; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'share_name'
    }

    It 'errors when [vrage_api].port is above the upper bound' {
        $cfg = @{
            instance   = @{ name = 'X'; display_name = 'X' }
            world_path = 'C:\W\Saves\X'
            staging_path = 'D:\stage\X'
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 99999; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'port'
    }

    It 'errors when [vrage_api].port is below the lower bound (port = 0)' {
        # Symmetric with the upper-bound case above (and with the Global port lower-bound test):
        # the Instance validator rejects port < 1 just as it rejects port > 65535.
        $cfg = @{
            instance   = @{ name = 'X'; display_name = 'X' }
            world_path = 'C:\W\Saves\X'
            staging_path = 'D:\stage\X'
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 0; security_key = 'k' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'port'
    }

    It 'errors when [backup].enabled is not a boolean' {
        $cfg = @{
            instance   = @{ name = 'X'; display_name = 'X' }
            world_path = 'C:\W\Saves\X'
            staging_path = 'D:\stage\X'
            share_name = 'SEBackup_X$'
            vrage_api  = @{ port = 8080; security_key = 'k' }
            backup     = @{ enabled = 'yes' }
        }
        $result = Test-SEBConfig -Type Instance -Config $cfg
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'enabled'
    }
}

Describe 'Test-SEBConfig -Path file handling' {

    It 'errors cleanly (does not throw) when the file does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("nope_" + [guid]::NewGuid().ToString('n') + '.toml')
        $result = Test-SEBConfig -Type Global -Path $missing
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'not found'
    }
}
