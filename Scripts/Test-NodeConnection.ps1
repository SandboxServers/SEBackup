#Requires -Version 7.0
<#
.SYNOPSIS
    Tests connectivity and health of SEBackup nodes.

.DESCRIPTION
    Performs connectivity and health checks against one or all configured SEBackup
    nodes. Calls Test-SEBConnection from the RemoteManager module and displays
    results in a formatted table.

    Checks include:
    - WinRM connectivity
    - VSS availability
    - SMB share access
    - Disk space
    - PowerShell version
    - 7-Zip availability

.PARAMETER NodeName
    The name of a specific node to test. Required unless -All is specified.

.PARAMETER All
    When specified, tests connectivity to all configured nodes.

.EXAMPLE
    .\Test-NodeConnection.ps1 -NodeName "GameServer01"
    # Tests connectivity to a single node.

.EXAMPLE
    .\Test-NodeConnection.ps1 -All
    # Tests connectivity to all configured nodes.

.OUTPUTS
    None. Results are displayed as a formatted table via Write-Host.
#>
[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single', Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeName,

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$All
)

# ── Import SEBackup modules ──────────────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$modulesRoot = Join-Path $projectRoot 'Modules'

$requiredModules = @('ConfigManager', 'CredentialManager', 'RemoteManager', 'Logger')
foreach ($mod in $requiredModules) {
    $modPath = Join-Path $modulesRoot "$mod\$mod.psm1"
    if (Test-Path $modPath) {
        Import-Module $modPath -Force -ErrorAction Stop
    }
    else {
        Write-Warning "Module not found: $modPath"
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║              SEBackup - Connection Test                     ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

# ── Build list of nodes to test ───────────────────────────────────────────────
$nodesToTest = [System.Collections.Generic.List[string]]::new()

if ($All) {
    Write-Host '  Testing all configured nodes...' -ForegroundColor Yellow
    Write-Host ''

    try {
        $allNodes = Get-SEBNodeConfig -All
        if (-not $allNodes -or $allNodes.Count -eq 0) {
            Write-Host '  No nodes configured.' -ForegroundColor Red
            Write-Host '  Run Setup-Node.ps1 to configure a node first.' -ForegroundColor DarkYellow
            Write-Host ''
            return
        }

        foreach ($node in $allNodes) {
            $nodesToTest.Add($node._NodeName)
        }

        Write-Host "  Found $($nodesToTest.Count) node(s) to test." -ForegroundColor White
        Write-Host ''
    }
    catch {
        Write-Host "  ERROR: Could not load node configs: $_" -ForegroundColor Red
        return
    }
}
else {
    $nodesToTest.Add($NodeName)
    Write-Host "  Testing node: $NodeName" -ForegroundColor Yellow
    Write-Host ''
}

# ── Run connectivity tests ───────────────────────────────────────────────────
$allResults = [System.Collections.Generic.List[object]]::new()

foreach ($node in $nodesToTest) {
    Write-Host "  Checking $node..." -ForegroundColor White -NoNewline

    try {
        $result = Test-SEBConnection -NodeName $node -Detailed
        $allResults.Add($result)

        if ($result.WinRM) {
            Write-Host ' Connected' -ForegroundColor Green
        }
        else {
            Write-Host ' FAILED' -ForegroundColor Red
        }
    }
    catch {
        Write-Host ' ERROR' -ForegroundColor Red
        $allResults.Add([PSCustomObject]@{
            NodeName        = $node
            WinRM           = $false
            VSS             = $false
            SMB             = $false
            DiskSpace       = $null
            PSVersion       = $null
            '7ZipInstalled' = $false
            Error           = $_.Exception.Message
        })
    }
}

# ── Display results table ────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Results:' -ForegroundColor Cyan
Write-Host ''

# Table header
$colWidths = @{
    Node      = 18
    WinRM     = 7
    VSS       = 7
    SMB       = 7
    DiskGB    = 10
    PSVer     = 12
    SevenZip  = 8
}

$header = '  ' +
    'Node'.PadRight($colWidths.Node) + '  ' +
    'WinRM'.PadRight($colWidths.WinRM) + '  ' +
    'VSS'.PadRight($colWidths.VSS) + '  ' +
    'SMB'.PadRight($colWidths.SMB) + '  ' +
    'Disk (GB)'.PadRight($colWidths.DiskGB) + '  ' +
    'PS Version'.PadRight($colWidths.PSVer) + '  ' +
    '7-Zip'.PadRight($colWidths.SevenZip)

$separator = '  ' +
    ('-' * $colWidths.Node) + '  ' +
    ('-' * $colWidths.WinRM) + '  ' +
    ('-' * $colWidths.VSS) + '  ' +
    ('-' * $colWidths.SMB) + '  ' +
    ('-' * $colWidths.DiskGB) + '  ' +
    ('-' * $colWidths.PSVer) + '  ' +
    ('-' * $colWidths.SevenZip)

Write-Host $header -ForegroundColor Cyan
Write-Host $separator -ForegroundColor DarkGray

foreach ($result in $allResults) {
    $nodeName = "$($result.NodeName)".PadRight($colWidths.Node)

    # Format each check as PASS/FAIL with color
    $winrmStr = if ($result.WinRM) { 'PASS' } else { 'FAIL' }
    $vssStr   = if ($result.VSS) { 'PASS' } else { 'FAIL' }
    $smbStr   = if ($result.SMB) { 'PASS' } else { 'FAIL' }

    $diskStr  = if ($null -ne $result.DiskSpace) { "$($result.DiskSpace) GB" } else { 'N/A' }
    $psVerStr = if ($result.PSVersion) { $result.PSVersion } else { 'N/A' }
    $szStr    = if ($result.'7ZipInstalled') { 'Yes' } else { 'No' }

    $winrmStr = $winrmStr.PadRight($colWidths.WinRM)
    $vssStr   = $vssStr.PadRight($colWidths.VSS)
    $smbStr   = $smbStr.PadRight($colWidths.SMB)
    $diskStr  = $diskStr.PadRight($colWidths.DiskGB)
    $psVerStr = $psVerStr.PadRight($colWidths.PSVer)
    $szStr    = $szStr.PadRight($colWidths.SevenZip)

    # Build the row with mixed colors
    Write-Host -NoNewline '  '
    Write-Host -NoNewline $nodeName -ForegroundColor White
    Write-Host -NoNewline '  '

    if ($result.WinRM) {
        Write-Host -NoNewline $winrmStr -ForegroundColor Green
    }
    else {
        Write-Host -NoNewline $winrmStr -ForegroundColor Red
    }
    Write-Host -NoNewline '  '

    if ($result.VSS) {
        Write-Host -NoNewline $vssStr -ForegroundColor Green
    }
    else {
        Write-Host -NoNewline $vssStr -ForegroundColor Red
    }
    Write-Host -NoNewline '  '

    if ($result.SMB) {
        Write-Host -NoNewline $smbStr -ForegroundColor Green
    }
    else {
        Write-Host -NoNewline $smbStr -ForegroundColor Red
    }
    Write-Host -NoNewline '  '

    Write-Host -NoNewline $diskStr -ForegroundColor White
    Write-Host -NoNewline '  '
    Write-Host -NoNewline $psVerStr -ForegroundColor White
    Write-Host -NoNewline '  '

    if ($result.'7ZipInstalled') {
        Write-Host $szStr -ForegroundColor Green
    }
    else {
        Write-Host $szStr -ForegroundColor DarkYellow
    }

    # Show error details if present
    if ($result.Error) {
        Write-Host "    Error: $($result.Error)" -ForegroundColor DarkYellow
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
$connectedCount = @($allResults | Where-Object { $_.WinRM }).Count
$totalCount = $allResults.Count

if ($connectedCount -eq $totalCount) {
    Write-Host "  All $totalCount node(s) connected successfully." -ForegroundColor Green
}
elseif ($connectedCount -gt 0) {
    Write-Host "  $connectedCount of $totalCount node(s) connected. $($totalCount - $connectedCount) failed." -ForegroundColor Yellow
}
else {
    Write-Host "  All $totalCount node(s) failed to connect." -ForegroundColor Red
}

Write-Host ''
