function Merge-ConfigOverrides {
    <#
    .SYNOPSIS
        Deep-merges two hashtables, with override values taking precedence over defaults.

    .DESCRIPTION
        Recursively merges the Override hashtable into the Default hashtable. When both
        hashtables contain a key whose value is itself a hashtable, the merge recurses
        into the nested structure. For all other types, the Override value wins.

        This is used to combine global defaults with instance-level or node-level
        overrides so that specific configurations can selectively replace individual
        settings while inheriting everything else.

        The function does not modify either input hashtable; it returns a new hashtable
        containing the merged result.

    .PARAMETER Default
        The base hashtable containing default values. All keys from this hashtable
        will appear in the output unless overridden.

    .PARAMETER Override
        The hashtable containing override values. These values take precedence over
        the Default hashtable. Nested hashtables are merged recursively rather than
        replaced wholesale.

    .EXAMPLE
        $global = @{
            vrage_api = @{ port = 8080; save_timeout_seconds = 120 }
            compression = @{ engine = "auto" }
        }
        $instance = @{
            vrage_api = @{ port = 9090 }
        }
        $merged = Merge-ConfigOverrides -Default $global -Override $instance
        # Result: vrage_api.port = 9090, vrage_api.save_timeout_seconds = 120, compression.engine = "auto"

    .OUTPUTS
        System.Collections.Hashtable
        A new hashtable containing the deep-merged result.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Default,

        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    # Start with a shallow clone of the default
    $merged = @{}
    foreach ($key in $Default.Keys) {
        $merged[$key] = $Default[$key]
    }

    foreach ($key in $Override.Keys) {
        $overrideValue = $Override[$key]

        if ($merged.ContainsKey($key)) {
            $defaultValue = $merged[$key]

            # If both values are hashtables, recurse for deep merge
            if ($defaultValue -is [hashtable] -and $overrideValue -is [hashtable]) {
                $merged[$key] = Merge-ConfigOverrides -Default $defaultValue -Override $overrideValue
            }
            else {
                # Override value wins for non-hashtable types or type mismatches
                $merged[$key] = $overrideValue
            }
        }
        else {
            # Key exists only in override; add it
            $merged[$key] = $overrideValue
        }
    }

    return $merged
}
