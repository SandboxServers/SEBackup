function Convert-PSObjectToHashtable {
    <#
    .SYNOPSIS
        Recursively normalizes a parsed/deserialized config tree into [hashtable]s.

    .DESCRIPTION
        Internal helper used by the ConfigManager load and validation paths. The shapes a
        configuration arrives in are NOT plain [hashtable]s and several downstream consumers gate
        on "-is [hashtable]" or call .ContainsKey():

        - PSToml's ConvertFrom-Toml returns a [System.Collections.Specialized.OrderedDictionary]
          at EVERY level (top-level and every nested table), not a [hashtable].
        - PSRemoting (Invoke-Command) deserializes a returned object tree as PSCustomObject for
          tables and Object[] for arrays.

        This converter walks the tree and rebuilds it with [hashtable] for every dictionary /
        object node and a plain object array for every list, recursing into values. It is a no-op
        for scalars and is safe to run on a value that is already a [hashtable] (that node is
        simply rebuilt key-for-key), so callers may invoke it unconditionally or guard it with
        "-isnot [hashtable]" for the common already-converted case.

    .PARAMETER InputObject
        The value to convert. May be a hashtable, an IDictionary (e.g. OrderedDictionary), a
        PSCustomObject, an IList/array, or any scalar.

    .OUTPUTS
        System.Collections.Hashtable
        For dictionary/object inputs. Lists are returned as object[]; scalars pass through
        unchanged.

    .EXAMPLE
        $parsed = ConvertFrom-Toml -InputObject $rawToml   # OrderedDictionary tree
        $config = Convert-PSObjectToHashtable -InputObject $parsed
        $config -is [hashtable]            # True
        $config.vrage_api -is [hashtable]  # True

    .EXAMPLE
        # Normalize a config handed back across PSRemoting (PSCustomObject tables).
        $remote = Invoke-Command -Session $s -ScriptBlock { ConvertFrom-Toml -InputObject $raw }
        $config = Convert-PSObjectToHashtable -InputObject $remote
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($InputObject -is [hashtable]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = Convert-PSObjectToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        # Catches PSToml's [System.Collections.Specialized.OrderedDictionary] (returned by
        # ConvertFrom-Toml) and any other dictionary shape, which are NOT [hashtable] and would
        # otherwise fall through to the passthrough branch -- leaving Merge-ConfigOverrides to
        # fail binding its [hashtable] parameter.
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = Convert-PSObjectToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    elseif ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = Convert-PSObjectToHashtable -InputObject $prop.Value
        }
        return $result
    }
    elseif ($InputObject -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSObjectToHashtable -InputObject $item))
        }
        return $list.ToArray()
    }
    else {
        return $InputObject
    }
}
