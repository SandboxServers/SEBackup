function New-SEBSession {
    <#
    .SYNOPSIS
        Creates or retrieves a cached PSSession to a remote SEBackup node.

    .DESCRIPTION
        Establishes a new PowerShell remoting session (PSSession) to the specified
        node using stored DPAPI-encrypted credentials from the CredentialManager
        module. Sessions are cached in a module-scoped hashtable keyed by NodeName.

        If a cached session already exists for the node and is still in an Opened
        state, the existing session is returned instead of creating a new one.

        If a cached session exists but is no longer open (Broken, Closed, or
        Disconnected), it is removed and a fresh session is created.

        The session is configured with appropriate timeouts for long-running
        backup operations:
        - OperationTimeout: 5 minutes (300,000 ms)
        - IdleTimeout: 30 minutes (1,800,000 ms)
        - OpenTimeout: 30 seconds (30,000 ms)

    .PARAMETER NodeName
        The name of the remote node to connect to. This is used both as the
        ComputerName for the PSSession and as the key for credential lookup.

    .PARAMETER NodeConfig
        An optional hashtable containing node configuration. If provided, the
        'hostname' key is used as the ComputerName instead of NodeName. This
        allows the NodeName to be a friendly alias while connecting to the
        actual hostname or IP address.

        Expected keys:
        - hostname: The actual hostname or IP address to connect to.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        Invoke-Command -Session $session -ScriptBlock { Get-Process }
        # Creates a session using stored credentials and executes a remote command.

    .EXAMPLE
        $config = @{ hostname = "192.168.1.100" }
        $session = New-SEBSession -NodeName "GameServer01" -NodeConfig $config
        # Connects to the IP address while using "GameServer01" as the credential lookup key.

    .EXAMPLE
        $session = New-SEBSession -NodeName "GameServer01"
        $session2 = New-SEBSession -NodeName "GameServer01"
        $session -eq $session2  # True -- returns the cached session.

    .OUTPUTS
        System.Management.Automation.Runspaces.PSSession
        An open PSSession to the remote node.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$NodeName,

        [Parameter(Position = 1)]
        [hashtable]$NodeConfig
    )

    # Check for a cached session that is still usable. Availability (not just State)
    # is the authoritative liveness signal -- a session can be State=Opened yet
    # Availability=Busy/None and unable to accept a new command. Mirror this exact
    # condition in Test-SEBSessionExists and Invoke-SEBRemoteCommand.
    if ($script:SEBSessions.ContainsKey($NodeName)) {
        $existingSession = $script:SEBSessions[$NodeName]
        $isOpen = $existingSession.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened
        $isAvailable = $existingSession.Availability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::Available
        if ($isOpen -and $isAvailable) {
            Write-Verbose "Returning cached session for node '$NodeName' (ID: $($existingSession.Id))"
            return $existingSession
        }
        else {
            Write-Verbose "Cached session for node '$NodeName' is not usable (State=$($existingSession.State), Availability=$($existingSession.Availability)). Removing and creating a new session."
            try { Remove-PSSession -Session $existingSession -ErrorAction SilentlyContinue } catch {}
            $script:SEBSessions.Remove($NodeName)
        }
    }

    # Determine the target computer name
    $computerName = $NodeName
    if ($NodeConfig -and $NodeConfig.ContainsKey('hostname')) {
        $computerName = $NodeConfig['hostname']
        Write-Verbose "Using hostname '$computerName' from node configuration for '$NodeName'."
    }

    # Retrieve stored credentials
    $credential = Get-SEBCredential -NodeName $NodeName

    # Configure session options for long-running backup operations
    $sessionOption = New-PSSessionOption `
        -OperationTimeout  300000  `
        -IdleTimeout      1800000  `
        -OpenTimeout        30000  `
        -NoMachineProfile

    try {
        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Creating PSSession to node '$NodeName' ($computerName)" -Level INFO
        }

        $session = New-PSSession `
            -ComputerName  $computerName `
            -Credential    $credential `
            -SessionOption $sessionOption `
            -Name          "SEBackup-$NodeName" `
            -ErrorAction   Stop

        $script:SEBSessions[$NodeName] = $session
        Write-Verbose "PSSession created for node '$NodeName' (ID: $($session.Id), ComputerName: $computerName)"

        return $session
    }
    catch {
        throw "Failed to create PSSession to node '$NodeName' ($computerName): $_"
    }
}
