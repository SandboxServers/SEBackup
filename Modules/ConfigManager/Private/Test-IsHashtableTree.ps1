function Test-IsHashtableTree {
    <#
    .SYNOPSIS
        Tests whether a value is a [hashtable] whose dictionary descendants are all [hashtable].

    .DESCRIPTION
        Internal predicate used to decide whether Convert-PSObjectToHashtable can be skipped. A
        config tree that is "fully hashtable" needs no normalization; one that contains any
        non-hashtable dictionary node (e.g. a PSToml OrderedDictionary section left behind after
        the top level was coerced to [hashtable] by a parameter cast) does.

        The check is conservative: it returns $true only when the input itself is a [hashtable]
        and every value reachable through nested hashtables is either a [hashtable] or not a
        dictionary at all. Any IDictionary that is not a [hashtable] (OrderedDictionary, etc.) or
        any PSCustomObject anywhere in the tree yields $false. Arrays are inspected element-wise.

    .PARAMETER InputObject
        The value to inspect (typically a parsed configuration).

    .OUTPUTS
        System.Boolean

    .EXAMPLE
        Test-IsHashtableTree -InputObject @{ a = @{ b = 1 } }            # True
        Test-IsHashtableTree -InputObject ([ordered]@{ a = 1 })          # False (top is ordered)
        Test-IsHashtableTree -InputObject @{ a = [ordered]@{ b = 1 } }   # False (nested ordered)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    if ($InputObject -is [hashtable]) {
        foreach ($value in $InputObject.Values) {
            if (-not (Test-IsHashtableTree -InputObject $value)) {
                return $false
            }
        }
        return $true
    }

    # A non-hashtable dictionary (OrderedDictionary, etc.) or a PSCustomObject must be converted.
    if ($InputObject -is [System.Collections.IDictionary] -or
        $InputObject -is [System.Management.Automation.PSCustomObject]) {
        return $false
    }

    # Inspect list/array elements; strings are IEnumerable but not IList, so they pass through.
    if ($InputObject -is [System.Collections.IList]) {
        foreach ($item in $InputObject) {
            if (-not (Test-IsHashtableTree -InputObject $item)) {
                return $false
            }
        }
        return $true
    }

    # Scalars (including $null and strings) impose no conversion requirement.
    return $true
}
