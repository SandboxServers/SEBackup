# Shared AST memoization for the Contract suite.
#
# WHY: the contract tests are AST lint over the SAME ~135 module source files, and several of
# them parse each file independently (Conventions parses every Public/Private file 2-3x just to
# build its discovery cases, then again at run time for the alias/Write-Host scan; Parse,
# ApiContract, RemoteScriptBlock and Exports each parse overlapping sets too). Re-running
# [Parser]::ParseFile on the same path many times dominates contract DISCOVERY time.
#
# This helper parses each file EXACTLY ONCE and caches the resulting AST in a script-scoped
# hashtable keyed by full path. The cache lives in this dot-sourced file's own script scope,
# which Pester keeps alive across every container in a single Invoke-Pester run (verified:
# a cache populated in one .Tests.ps1's BeforeDiscovery is reused by the next), so all
# discovery sites -- across all contract files -- share one parse per file.
#
# Dot-source this from each contract file's BeforeDiscovery AND BeforeAll:
#     . "$PSScriptRoot/_ContractAst.ps1"
# then call Get-ContractAst / Get-ContractFunctionInfo / Get-CommandAstsFromFile instead of
# calling [Parser]::ParseFile directly.

# Initialise the cache once. Guard with Get-Variable so re-dot-sourcing (each container dot-sources
# this file again) does NOT wipe the accumulated cache.
if (-not (Get-Variable -Name __ContractAstCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__ContractAstCache = @{}
}

function Get-ContractAst {
    # Parse $Path once and return its ScriptBlockAst; subsequent calls for the same path return
    # the cached AST. Tokens/parse-errors are cached alongside so callers that need errors (the
    # parse-integrity contract) can read them without re-parsing.
    param([Parameter(Mandatory)][string]$Path)
    $key = [System.IO.Path]::GetFullPath($Path)
    if (-not $script:__ContractAstCache.ContainsKey($key)) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($key, [ref]$tokens, [ref]$errors)
        $script:__ContractAstCache[$key] = [pscustomobject]@{
            Ast    = $ast
            Tokens = $tokens
            Errors = @($errors)
        }
    }
    return $script:__ContractAstCache[$key]
}

function Get-ContractFunctionInfo {
    # Returns one hashtable per function definition found in $Path, with the metadata each
    # convention test needs. IsTopLevel=$true means the function is at file scope (not nested
    # inside another function) -- used by the one-function-per-file and naming rules.
    param([Parameter(Mandatory)][string]$Path)
    $parsed = Get-ContractAst -Path $Path
    $ast = $parsed.Ast
    $topLevel = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
    $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($fn in $all) {
        $attrs = @()
        if ($fn.Body.ParamBlock) { $attrs = @($fn.Body.ParamBlock.Attributes.TypeName.FullName) }
        $help = $fn.GetHelpContent()
        @{
            Name           = $fn.Name
            IsTopLevel     = ($topLevel -contains $fn)
            HasCmdletBind  = ($attrs -contains 'CmdletBinding')
            HasOutputType  = ($attrs -contains 'OutputType')
            HasSynopsis    = ($help -and -not [string]::IsNullOrWhiteSpace($help.Synopsis))
            HasDescription = ($help -and -not [string]::IsNullOrWhiteSpace($help.Description))
            HasExample     = ($help -and $help.Examples -and $help.Examples.Count -gt 0)
        }
    }
}

function Get-CommandAstsFromFile {
    # All CommandAst nodes (including nested) in $Path, from the cached AST.
    param([Parameter(Mandatory)][string]$Path)
    $parsed = Get-ContractAst -Path $Path
    return @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
}
