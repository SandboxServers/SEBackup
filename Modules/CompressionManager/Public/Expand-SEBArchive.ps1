function Expand-SEBArchive {
    <#
    .SYNOPSIS
        Extracts a backup archive to a destination directory using 7-Zip or .NET.

    .DESCRIPTION
        Extracts the contents of an archive file to the specified destination path.
        Auto-detects the appropriate compression engine based on file extension:

        - .7z files are extracted using 7-Zip (7z.exe)
        - .zip files are extracted using the built-in Expand-Archive cmdlet

        The Engine parameter can override auto-detection. When a PSSession is provided,
        extraction runs entirely on the remote node.

        Creates the destination directory if it does not exist. Uses the -y flag with
        7-Zip to automatically overwrite existing files during extraction.

    .PARAMETER ArchivePath
        The full path to the archive file to extract. Must exist on the target system
        (local or remote depending on Session parameter).

    .PARAMETER DestinationPath
        The directory to extract the archive contents into. Will be created if it
        does not exist.

    .PARAMETER Engine
        The compression engine to use for extraction: "auto" (default), "7zip", or
        "dotnet". When "auto", the engine is chosen based on the archive file extension.

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, extraction runs on
        the remote machine.

    .EXAMPLE
        Expand-SEBArchive -ArchivePath "D:\Backups\backup.7z" -DestinationPath "C:\Restore\Instance1"

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        Expand-SEBArchive -ArchivePath "D:\Backups\backup.zip" -DestinationPath "C:\Restore\Instance1" -Session $session

    .OUTPUTS
        PSCustomObject
        An object with properties: ArchivePath, DestinationPath, Engine, Duration.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

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
        Write-Verbose "Auto-detected extraction engine '$resolvedEngine' from extension '$extension'."
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($resolvedEngine -eq '7zip') {
        $extractScript = {
            param(
                [string]$Archive,
                [string]$Destination
            )

            # Create destination if needed
            if (-not (Test-Path -Path $Destination -PathType Container)) {
                New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

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
                throw '7z.exe not found on the node.'
            }

            $args7z = @('x', $Archive, "-o$Destination", '-y')

            $process = Start-Process -FilePath $sevenZip -ArgumentList $args7z `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\seb_7z_out.txt" `
                -RedirectStandardError "$env:TEMP\seb_7z_err.txt"

            $stderr = if (Test-Path "$env:TEMP\seb_7z_err.txt") { Get-Content "$env:TEMP\seb_7z_err.txt" -Raw } else { '' }

            Remove-Item -Path "$env:TEMP\seb_7z_out.txt", "$env:TEMP\seb_7z_err.txt" -Force -ErrorAction SilentlyContinue

            if ($process.ExitCode -ne 0) {
                throw "7-Zip extraction failed (exit code $($process.ExitCode)). Stderr: $stderr"
            }
        }

        if ($Session) {
            Invoke-Command -Session $Session -ScriptBlock $extractScript `
                -ArgumentList $ArchivePath, $DestinationPath -ErrorAction Stop
        }
        else {
            & $extractScript -Archive $ArchivePath -Destination $DestinationPath
        }
    }
    else {
        # .NET / Expand-Archive engine
        $extractScript = {
            param(
                [string]$Archive,
                [string]$Destination
            )

            # Create destination if needed
            if (-not (Test-Path -Path $Destination -PathType Container)) {
                New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            Expand-Archive -Path $Archive -DestinationPath $Destination -Force -ErrorAction Stop
        }

        if ($Session) {
            Invoke-Command -Session $Session -ScriptBlock $extractScript `
                -ArgumentList $ArchivePath, $DestinationPath -ErrorAction Stop
        }
        else {
            & $extractScript -Archive $ArchivePath -Destination $DestinationPath
        }
    }

    $stopwatch.Stop()

    $output = [PSCustomObject]@{
        ArchivePath     = $ArchivePath
        DestinationPath = $DestinationPath
        Engine          = $resolvedEngine
        Duration        = $stopwatch.Elapsed
    }

    Write-Verbose "Extraction complete: engine=$resolvedEngine, duration=$($stopwatch.Elapsed)."

    return $output
}
