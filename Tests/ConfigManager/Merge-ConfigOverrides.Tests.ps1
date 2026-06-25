#Requires -Module Pester

# Issue #19 -- unit coverage for the global<-node<-instance deep-merge primitive.
#
# Merge-ConfigOverrides is the engine ConfigManager uses to layer overrides onto defaults
# (Get-SEBInstanceConfig merges the instance config over the global [defaults] table, and the
# node layer over that). The contract that the higher layers rely on:
#   * nested tables are merged RECURSIVELY (a deeper override key wins while its unrelated
#     siblings survive) -- they are NOT replaced wholesale;
#   * a scalar override replaces the default scalar;
#   * a key present only in the override is added; a key present only in the default survives;
#   * a TYPE MISMATCH (table-vs-scalar either way) takes the override verbatim -- no merge;
#   * neither input hashtable is mutated (the result is a fresh tree).
#
# This is pure hashtable-in / hashtable-out, so the Private function is dot-sourced directly and
# exercised with in-memory tables -- no module import, no mocks.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . "$repoRoot/Modules/ConfigManager/Private/Merge-ConfigOverrides.ps1"
}

Describe 'Merge-ConfigOverrides' {

    Context 'scalar overrides' {
        It 'replaces a scalar default with the override value' {
            $default  = @{ port = 8080; timeout = 120 }
            $override = @{ port = 9090 }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['port']    | Should -Be 9090
            $merged['timeout'] | Should -Be 120 -Because 'an unrelated default key survives'
        }

        It 'adds a key that exists only in the override' {
            $default  = @{ a = 1 }
            $override = @{ b = 2 }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['a'] | Should -Be 1
            $merged['b'] | Should -Be 2
        }

        It 'keeps a key that exists only in the default' {
            $default  = @{ a = 1; b = 2 }
            $override = @{ a = 99 }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged.Keys | Should -Contain 'b'
            $merged['b'] | Should -Be 2
        }
    }

    Context 'nested-table overrides (deep merge)' {
        It 'merges a nested table key-by-key instead of replacing it wholesale' {
            $default = @{
                vrage_api   = @{ port = 8080; save_timeout_seconds = 120 }
                compression = @{ engine = 'auto' }
            }
            $override = @{
                vrage_api = @{ port = 9090 }
            }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            # Deeper override key wins...
            $merged['vrage_api']['port'] | Should -Be 9090
            # ...while its unrelated sibling survives (this is what "deep" buys over a wholesale swap).
            $merged['vrage_api']['save_timeout_seconds'] | Should -Be 120
            # ...and an entirely untouched sibling table is intact.
            $merged['compression']['engine'] | Should -Be 'auto'
        }

        It 'recurses through more than one level of nesting' {
            $default = @{
                outer = @{ inner = @{ keep = 'yes'; change = 'old' } }
            }
            $override = @{
                outer = @{ inner = @{ change = 'new' } }
            }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['outer']['inner']['change'] | Should -Be 'new'
            $merged['outer']['inner']['keep']   | Should -Be 'yes'
        }

        It 'adds a brand-new nested table that exists only in the override' {
            $default  = @{ existing = @{ a = 1 } }
            $override = @{ added = @{ b = 2 } }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['existing']['a'] | Should -Be 1
            $merged['added']['b']    | Should -Be 2
        }
    }

    Context 'type mismatches take the override verbatim' {
        It 'replaces a scalar default with a table override (no merge attempted)' {
            $default  = @{ section = 'scalar-value' }
            $override = @{ section = @{ now = 'a-table' } }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['section'] | Should -BeOfType [hashtable]
            $merged['section']['now'] | Should -Be 'a-table'
        }

        It 'replaces a table default with a scalar override (no merge attempted)' {
            $default  = @{ section = @{ a = 1 } }
            $override = @{ section = 'now-a-scalar' }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['section'] | Should -Be 'now-a-scalar'
            $merged['section'] | Should -Not -BeOfType [hashtable]
        }
    }

    Context 'array and null handling' {
        It 'replaces an array default with the override array (arrays are not element-merged)' {
            $default  = @{ excludes = @('*.log', '*.tmp') }
            $override = @{ excludes = @('*.bak') }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            # Arrays are not hashtables, so the override value wins as a unit.
            $merged['excludes'] | Should -Be @('*.bak')
            $merged['excludes'].Count | Should -Be 1
        }

        It 'lets a $null override value replace a non-null default' {
            $default  = @{ key = 'has-value' }
            $override = @{ key = $null }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            # The key is present in the override, so its (null) value wins over the default.
            $merged.ContainsKey('key') | Should -BeTrue
            $merged['key'] | Should -BeNullOrEmpty
        }

        It 'preserves a default value when the override does not mention the key (absent != null)' {
            $default  = @{ keep = 'value'; other = 1 }
            $override = @{ other = 2 }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            $merged['keep'] | Should -Be 'value'
        }
    }

    Context 'empty inputs' {
        It 'returns the default unchanged when the override is empty' {
            $default  = @{ a = 1; b = @{ c = 2 } }
            $merged = Merge-ConfigOverrides -Default $default -Override @{}

            $merged['a'] | Should -Be 1
            $merged['b']['c'] | Should -Be 2
        }

        It 'returns the override values when the default is empty' {
            $override = @{ a = 1 }
            $merged = Merge-ConfigOverrides -Default @{} -Override $override

            $merged['a'] | Should -Be 1
        }

        It 'returns an empty hashtable when both inputs are empty' {
            $merged = Merge-ConfigOverrides -Default @{} -Override @{}
            $merged | Should -BeOfType [hashtable]
            $merged.Count | Should -Be 0
        }
    }

    Context 'non-destructive (inputs are not mutated)' {
        It 'does not mutate either input hashtable' {
            $default  = @{ shared = @{ a = 1 }; only_default = 'd' }
            $override = @{ shared = @{ b = 2 }; only_override = 'o' }

            $null = Merge-ConfigOverrides -Default $default -Override $override

            # Default must not gain the override's keys.
            $default.ContainsKey('only_override')    | Should -BeFalse
            $default['shared'].ContainsKey('b')      | Should -BeFalse
            # Override must not gain the default's keys.
            $override.ContainsKey('only_default')    | Should -BeFalse
            $override['shared'].ContainsKey('a')     | Should -BeFalse
        }

        It 'returns a new top-level hashtable, not one of the inputs' {
            $default  = @{ a = 1 }
            $override = @{ b = 2 }
            $merged = Merge-ConfigOverrides -Default $default -Override $override

            [object]::ReferenceEquals($merged, $default)  | Should -BeFalse
            [object]::ReferenceEquals($merged, $override) | Should -BeFalse
        }
    }
}
