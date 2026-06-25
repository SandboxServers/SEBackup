function ConvertTo-CanonicalInstanceConfig {
    <#
    .SYNOPSIS
        Normalizes a legacy instance-config layout to the canonical schema the engine reads.

    .DESCRIPTION
        Back-compat shim for nodes whose C:\SEBackup\instances\{name}.toml was written by an
        older Register-Instance.ps1 / Setup-Node.ps1 that emitted the now-superseded layout:
        operational values nested under [paths] / [smb] / [instance], and the VRage key named
        [vrage_api].key.

        The current engine (Invoke-SEBBackup, Invoke-SEBRestore, Test-SEBPreFlight,
        Start/Stop-SEBTorchServer) reads the operational values as FLAT top-level keys
        (world_path, staging_path, share_name, run_mode) plus a nested [vrage_api] table with
        port / security_key. New configs are generated in that shape directly, so this shim is
        ONLY a bridge for already-deployed nodes that have not been re-registered.

        It is intentionally additive and non-destructive: a legacy value is copied to its
        canonical key ONLY when the canonical key is absent, so a config already written in the
        canonical schema passes through untouched and an explicit canonical value always wins.
        The caller's hashtable is never mutated -- the input is shallow-cloned (and any nested
        table about to be edited is cloned in turn) before any key is added.

        For already-canonical configs (world_path + share_name present and no legacy
        [vrage_api].key shadowing security_key) the function returns the input unchanged via a
        fast path, so a post-migration load incurs no copying.

    .PARAMETER InputObject
        The parsed instance-config hashtable (already converted from the TOML / remoting shape).

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        # Legacy config with operational values nested under [paths] / [smb].
        $legacy = @{
            instance = @{ name = 'X'; run_mode = 'console' }
            paths    = @{ world_save = 'C:\W\Saves\X'; staging_local = 'E:\stage\X' }
            smb      = @{ share_name = 'SEBackup_X$' }
            vrage_api = @{ port = 8081; key = 'legacykey' }
        }
        $canon = ConvertTo-CanonicalInstanceConfig -InputObject $legacy
        $canon['world_path']                # C:\W\Saves\X (promoted from [paths].world_save)
        $canon['vrage_api']['security_key'] # legacykey   (promoted from [vrage_api].key)
        # $legacy is unchanged.

    .EXAMPLE
        # An already-canonical config is returned as-is (fast path, no copy).
        $canon = ConvertTo-CanonicalInstanceConfig -InputObject $alreadyCanonical
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$InputObject
    )

    # Fast path: an already-canonical config needs nothing done. It has the required flat keys
    # (world_path + share_name) and no legacy [vrage_api].key shadowing security_key. Returning
    # the input untouched keeps post-migration loads free of any copying. (run_mode/staging_path
    # are optional with engine defaults, so their absence does not force a migration pass.)
    $hasLegacyVrageKey = $InputObject.ContainsKey('vrage_api') -and
        $InputObject['vrage_api'] -is [hashtable] -and
        $InputObject['vrage_api'].ContainsKey('key') -and
        -not $InputObject['vrage_api'].ContainsKey('security_key')
    if ($InputObject.ContainsKey('world_path') -and
        $InputObject.ContainsKey('share_name') -and
        -not $hasLegacyVrageKey) {
        return $InputObject
    }

    # Non-destructive: shallow-clone so we never mutate the caller's hashtable. Nested tables are
    # cloned individually below, immediately before they are edited.
    $config = @{} + $InputObject

    # Map legacy nested values onto canonical flat keys, only filling gaps.
    # (legacy section, legacy key) -> canonical top-level key
    $flatMap = @(
        @{ Section = 'paths'; Key = 'world_save';    Target = 'world_path' }
        @{ Section = 'paths'; Key = 'staging_local'; Target = 'staging_path' }
        @{ Section = 'smb';   Key = 'share_name';    Target = 'share_name' }
    )

    foreach ($m in $flatMap) {
        if (-not $config.ContainsKey($m.Target) -and
            $config.ContainsKey($m.Section) -and
            $config[$m.Section] -is [hashtable] -and
            $config[$m.Section].ContainsKey($m.Key) -and
            -not [string]::IsNullOrWhiteSpace([string]$config[$m.Section][$m.Key])) {
            $config[$m.Target] = $config[$m.Section][$m.Key]
        }
    }

    # run_mode used to live under [instance]; the engine now reads it top-level.
    if (-not $config.ContainsKey('run_mode') -and
        $config.ContainsKey('instance') -and
        $config['instance'] -is [hashtable] -and
        $config['instance'].ContainsKey('run_mode') -and
        -not [string]::IsNullOrWhiteSpace([string]$config['instance']['run_mode'])) {
        $config['run_mode'] = $config['instance']['run_mode']
    }

    # VRage key was renamed [vrage_api].key -> [vrage_api].security_key.
    if ($config.ContainsKey('vrage_api') -and $config['vrage_api'] -is [hashtable]) {
        # Clone the nested table before promoting so the caller's [vrage_api] is left intact.
        $vrage = @{} + $config['vrage_api']
        if (-not $vrage.ContainsKey('security_key') -and
            $vrage.ContainsKey('key') -and
            -not [string]::IsNullOrWhiteSpace([string]$vrage['key'])) {
            $vrage['security_key'] = $vrage['key']
            $config['vrage_api'] = $vrage
        }
    }

    return $config
}
