function Mount-SEBShare {
    <#
    .SYNOPSIS
        Maps a network drive to an SMB share for SEBackup file operations.

    .DESCRIPTION
        Creates a PSDrive mapping to the specified UNC share path using the
        provided credentials. This allows standard PowerShell file operations
        (Get-ChildItem, Copy-Item, etc.) to work seamlessly with the remote
        share.

        If a specific -DriveLetter is provided, the share is mapped to that
        drive letter (e.g., "Z:" maps to Z:\). If no drive letter is specified,
        a temporary PSDrive is created with a generated name in the format
        "SEBShare_{8-char-guid}".

        The returned PSDrive object should be cleaned up when no longer needed
        using Remove-PSDrive.

    .PARAMETER SharePath
        The UNC path to the SMB share (e.g., \\GameServer01\TorchBackups).

    .PARAMETER Credential
        The PSCredential to use for authenticating to the share.

    .PARAMETER DriveLetter
        An optional single character specifying the drive letter to use for
        the mapping (e.g., 'Z'). If not specified, a temporary PSDrive with
        a generated name is created.

    .EXAMPLE
        $cred = Get-SEBCredential -NodeName "GameServer01"
        $drive = Mount-SEBShare -SharePath "\\GameServer01\TorchBackups" -Credential $cred
        Get-ChildItem -Path "$($drive.Name):\"
        Remove-PSDrive -Name $drive.Name
        # Creates a temporary mapped drive, lists contents, and cleans up.

    .EXAMPLE
        $cred = Get-SEBCredential -NodeName "GameServer01"
        $drive = Mount-SEBShare -SharePath "\\GameServer01\TorchBackups" -Credential $cred -DriveLetter 'Z'
        Copy-Item -Path "Z:\backup.7z" -Destination "C:\LocalBackups\"
        Remove-PSDrive -Name $drive.Name
        # Maps to drive letter Z, copies a file, and cleans up.

    .EXAMPLE
        try {
            $drive = Mount-SEBShare -SharePath $sharePath -Credential $cred
            # ... perform file operations ...
        }
        finally {
            if ($drive) { Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue }
        }
        # Ensures cleanup even on errors.

    .OUTPUTS
        System.Management.Automation.PSDriveInfo
        The PSDrive object representing the mapped network drive.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSDriveInfo])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$SharePath,

        [Parameter(Mandatory, Position = 1)]
        [PSCredential]$Credential,

        [Parameter()]
        [ValidatePattern('^[A-Za-z]$')]
        [char]$DriveLetter
    )

    # Determine the drive name
    if ($PSBoundParameters.ContainsKey('DriveLetter')) {
        $driveName = $DriveLetter.ToString().ToUpper()
    }
    else {
        $driveName = "SEBShare_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }

    try {
        $drive = New-PSDrive `
            -Name       $driveName `
            -PSProvider  FileSystem `
            -Root        $SharePath `
            -Credential  $Credential `
            -Scope       Global `
            -ErrorAction Stop

        if (Get-Command -Name 'Write-SEBLog' -ErrorAction SilentlyContinue) {
            Write-SEBLog -Message "Mounted SMB share '$SharePath' as drive '$driveName'" -Level INFO
        }
        Write-Verbose "Mounted SMB share '$SharePath' as drive '$driveName'"

        return $drive
    }
    catch {
        throw "Failed to mount SMB share '$SharePath' as drive '$driveName': $_"
    }
}
