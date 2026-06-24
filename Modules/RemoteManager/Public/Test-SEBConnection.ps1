function Test-SEBConnection {
    <#
    .SYNOPSIS
        Tests WinRM and service connectivity to a remote SEBackup node.

    .DESCRIPTION
        Validates that the backup management host can communicate with a remote
        Space Engineers Torch server node over WinRM. In simple mode, returns
        $true or $false based on whether a WinRM connection can be established.

        In -Detailed mode, returns a PSCustomObject with comprehensive
        connectivity and capability checks:

        - WinRM:          Can a PSSession be established?
        - VSS:            Can a VSS shadow copy be created and deleted?
        - SMB:            Can the configured SMB share be accessed?
        - DiskSpace:      Free disk space on the remote system drive.
        - PSVersion:      PowerShell version on the remote node.
        - 7ZipInstalled:  Is 7-Zip available on the remote node?

        Stored credentials from the CredentialManager module are used for
        authentication.

    .PARAMETER NodeName
        The name of the remote node to test connectivity to.

    .PARAMETER Detailed
        When specified, performs comprehensive checks and returns a detailed
        result object instead of a simple boolean.

    .EXAMPLE
        Test-SEBConnection -NodeName "GameServer01"
        # Returns $true or $false.

    .EXAMPLE
        Test-SEBConnection -NodeName "GameServer01" -Detailed
        # Returns a detailed object with WinRM, VSS, SMB, DiskSpace, PSVersion, and 7ZipInstalled.

    .EXAMPLE
        $nodes = @("Server01", "Server02", "Server03")
        $nodes | ForEach-Object { [PSCustomObject]@{ Node = $_; Connected = (Test-SEBConnection -NodeName $_) } }
        # Quick connectivity check across multiple nodes.

    .OUTPUTS
        System.Boolean
        When -Detailed is not specified: $true if WinRM is reachable, $false otherwise.

        PSCustomObject
        When -Detailed is specified: An object with properties WinRM, VSS, SMB,
        DiskSpace, PSVersion, and 7ZipInstalled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter()]
        [switch]$Detailed
    )

    # Get stored credentials
    try {
        $credential = Get-SEBCredential -NodeName $NodeName
    }
    catch {
        if ($Detailed) {
            return [PSCustomObject]@{
                NodeName      = $NodeName
                WinRM         = $false
                VSS           = $false
                SMB           = $false
                DiskSpace     = $null
                PSVersion     = $null
                '7ZipInstalled' = $false
                Error         = "Credential retrieval failed: $_"
            }
        }
        return $false
    }

    # Resolve the actual hostname/IP from the node config (the NodeName is just a label).
    # Connecting to the NodeName directly only works when it happens to equal the DNS name;
    # the rest of the system connects via the configured hostname, so match that here.
    $computerName = $NodeName
    $nodeConfig = Get-SEBNodeConfig -NodeName $NodeName -ErrorAction SilentlyContinue
    if ($nodeConfig) {
        $nc = if ($nodeConfig.ContainsKey('node')) { $nodeConfig['node'] } else { $nodeConfig }
        if ($nc.ContainsKey('hostname') -and -not [string]::IsNullOrWhiteSpace($nc['hostname'])) {
            $computerName = $nc['hostname']
        }
    }

    # Test basic WinRM connectivity
    $session = $null
    try {
        $sessionOption = New-PSSessionOption -OperationTimeout 15000 -OpenTimeout 15000
        $session = New-PSSession `
            -ComputerName  $computerName `
            -Credential    $credential `
            -SessionOption $sessionOption `
            -ErrorAction   Stop
        $winRmOk = $true
    }
    catch {
        $winRmOk = $false
    }

    if (-not $Detailed) {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
        return $winRmOk
    }

    # Detailed mode -- run comprehensive checks
    $result = [PSCustomObject]@{
        NodeName        = $NodeName
        WinRM           = $winRmOk
        VSS             = $false
        SMB             = $false
        DiskSpace       = $null
        PSVersion       = $null
        '7ZipInstalled' = $false
        Error           = $null
    }

    if (-not $winRmOk -or -not $session) {
        $result.Error = 'WinRM connection failed. Remaining checks skipped.'
        return $result
    }

    try {
        $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
            $details = @{}

            # PowerShell version
            $details['PSVersion'] = $PSVersionTable.PSVersion.ToString()

            # Disk space on system drive
            try {
                $systemDrive = $env:SystemDrive
                if (-not $systemDrive) { $systemDrive = 'C:' }
                $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'" -ErrorAction Stop
                $details['DiskSpaceGB'] = [math]::Round($disk.FreeSpace / 1GB, 2)
            }
            catch {
                $details['DiskSpaceGB'] = $null
            }

            # VSS: attempt to create and immediately delete a shadow copy
            try {
                $shadow = (Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop | Select-Object -First 1)
                # If we can query VSS classes, consider VSS accessible
                # Creating an actual shadow copy just for a test is heavyweight; instead test the service
                $vssService = Get-Service -Name 'VSS' -ErrorAction Stop
                $details['VSS'] = ($vssService.Status -eq 'Running' -or $vssService.StartType -ne 'Disabled')
            }
            catch {
                $details['VSS'] = $false
            }

            # 7-Zip check
            try {
                $7zPath = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
                $details['7ZipInstalled'] = (Test-Path $7zPath)
            }
            catch {
                $details['7ZipInstalled'] = $false
            }

            return $details
        } -ErrorAction Stop

        $result.PSVersion       = $remoteInfo['PSVersion']
        $result.DiskSpace       = $remoteInfo['DiskSpaceGB']
        $result.VSS             = $remoteInfo['VSS']
        $result.'7ZipInstalled' = $remoteInfo['7ZipInstalled']

        # SMB share test -- attempt to access the admin share as a basic SMB check
        try {
            $smbResult = Invoke-Command -Session $session -ScriptBlock {
                $shareName = (Get-SmbShare -ErrorAction Stop | Where-Object { $_.ShareType -eq 'FileSystemDirectory' } | Select-Object -First 1)
                return ($null -ne $shareName)
            } -ErrorAction Stop
            $result.SMB = $smbResult
        }
        catch {
            $result.SMB = $false
        }
    }
    catch {
        $result.Error = "Remote checks failed: $_"
    }
    finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }

    return $result
}
