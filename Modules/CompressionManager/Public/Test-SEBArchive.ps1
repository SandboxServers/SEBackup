function Test-SEBArchive {
    <#
    .SYNOPSIS
        Tests the integrity of a backup archive.

    .DESCRIPTION
        Validates that a backup archive is not corrupted by testing its internal
        consistency:

        - 7-Zip: Runs "7z t" which verifies CRC checksums of all files within the
          archive. This is fast and does not require disk space for extraction.
        - .NET:  Attempts to open and read the ZIP file entries using
          System.IO.Compression.ZipFile. If the archive is corrupted, the open
          or entry enumeration will throw an exception.

        Auto-detects the engine from the file extension when Engine is "auto".

    .PARAMETER ArchivePath
        The full path to the archive file to test.

    .PARAMETER Engine
        The compression engine to use for testing: "auto" (default), "7zip", or
        "dotnet". When "auto", chosen from file extension (.7z = 7zip, else dotnet).

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the integrity test
        runs on the remote machine.

    .EXAMPLE
        $isValid = Test-SEBArchive -ArchivePath "D:\Backups\backup.7z"
        if (-not $isValid) { Write-Error "Archive is corrupted!" }

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        Test-SEBArchive -ArchivePath "D:\Backups\backup.zip" -Session $session

    .OUTPUTS
        System.Boolean
        $true if the archive passes integrity checks, $false if it is corrupted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter()]
        [ValidateSet('auto', '7zip', 'dotnet')]
        [string]$Engine = 'auto',

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    # Resolve engine from file extension if auto
    $resolvedEngine = $Engine
    if ($resolvedEngine -eq 'auto') {
        $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLower()
        if ($extension -eq '.7z') {
            $resolvedEngine = '7zip'
        }
        else {
            $resolvedEngine = 'dotnet'
        }
        Write-Verbose "Auto-detected test engine '$resolvedEngine' from extension '$extension'."
    }

    if ($resolvedEngine -eq '7zip') {
        $testScript = {
            param([string]$Archive)

            # Find 7z.exe
            $sevenZip = $null
            $candidates = @(
                (Join-Path -Path $env:ProgramFiles -ChildPath '7-Zip\7z.exe')
                (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath '7-Zip\7z.exe')
            )
            foreach ($c in $candidates) {
                if ($c -and (Test-Path -Path $c -PathType Leaf)) {
                    $sevenZip = $c
                    break
                }
            }
            if (-not $sevenZip) {
                $cmd = Get-Command -Name '7z.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($cmd) { $sevenZip = $cmd.Source }
            }
            if (-not $sevenZip) {
                throw '7z.exe not found on the node. Cannot test .7z archive.'
            }

            $process = Start-Process -FilePath $sevenZip -ArgumentList @('t', $Archive) `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\seb_7z_out.txt" `
                -RedirectStandardError "$env:TEMP\seb_7z_err.txt"

            Remove-Item -Path "$env:TEMP\seb_7z_out.txt", "$env:TEMP\seb_7z_err.txt" -Force -ErrorAction SilentlyContinue

            return ($process.ExitCode -eq 0)
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $testScript -ArgumentList $ArchivePath -ErrorAction Stop
        }
        else {
            $result = & $testScript -Archive $ArchivePath
        }
    }
    else {
        # .NET ZIP integrity test
        $testScript = {
            param([string]$Archive)

            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

                $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
                try {
                    # Iterate all entries to verify they can be read
                    foreach ($entry in $zip.Entries) {
                        $stream = $entry.Open()
                        try {
                            # Read through the entire entry to verify CRC
                            $buffer = [byte[]]::new(8192)
                            while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) {
                                # Reading is sufficient to trigger CRC validation
                            }
                        }
                        finally {
                            $stream.Close()
                            $stream.Dispose()
                        }
                    }
                }
                finally {
                    $zip.Dispose()
                }

                return $true
            }
            catch {
                return $false
            }
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $testScript -ArgumentList $ArchivePath -ErrorAction Stop
        }
        else {
            $result = & $testScript -Archive $ArchivePath
        }
    }

    if ($result) {
        Write-Verbose "Archive integrity test PASSED for '$ArchivePath' (engine: $resolvedEngine)."
    }
    else {
        Write-Warning "Archive integrity test FAILED for '$ArchivePath' (engine: $resolvedEngine)."
    }

    return $result
}
