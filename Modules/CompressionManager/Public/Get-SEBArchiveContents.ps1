function Get-SEBArchiveContents {
    <#
    .SYNOPSIS
        Lists the files inside a backup archive without extracting them.

    .DESCRIPTION
        Enumerates all files within an archive and returns their relative paths and
        sizes. This is useful for verifying archive contents before extraction or
        for building file lists during restore planning.

        - 7-Zip: Runs "7z l" and parses the listing output for filenames and sizes.
        - .NET:  Uses System.IO.Compression.ZipFile.OpenRead() to enumerate entries.

        Auto-detects the engine from the file extension when Engine is "auto".

    .PARAMETER ArchivePath
        The full path to the archive file to list.

    .PARAMETER Engine
        The compression engine to use: "auto" (default), "7zip", or "dotnet".
        When "auto", chosen from file extension (.7z = 7zip, else dotnet).

    .PARAMETER Session
        An optional PSSession to a remote node. When specified, the listing runs
        on the remote machine.

    .EXAMPLE
        $contents = Get-SEBArchiveContents -ArchivePath "D:\Backups\backup.7z"
        $contents | Format-Table Path, Size

    .EXAMPLE
        $session = New-PSSession -ComputerName "GameNode01"
        $contents = Get-SEBArchiveContents -ArchivePath "D:\Backups\backup.zip" -Session $session

    .OUTPUTS
        PSCustomObject[]
        An array of objects, each with properties: Path (string), Size (long).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
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
        Write-Verbose "Auto-detected listing engine '$resolvedEngine' from extension '$extension'."
    }

    if ($resolvedEngine -eq '7zip') {
        $listScript = {
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
                throw '7z.exe not found on the node. Cannot list .7z archive.'
            }

            # Run 7z l with -slt for technical listing (machine-parseable)
            $output = & $sevenZip l -slt $Archive 2>&1

            if ($LASTEXITCODE -ne 0) {
                throw "7-Zip listing failed (exit code $LASTEXITCODE)."
            }

            $entries = @()
            $currentPath = $null
            $currentSize = $null
            $isDirectory = $false

            foreach ($line in $output) {
                $lineStr = $line.ToString().Trim()

                if ($lineStr -match '^Path = (.+)$') {
                    # Save previous entry before starting a new one
                    if ($null -ne $currentPath -and -not $isDirectory) {
                        $entries += [PSCustomObject]@{
                            Path = $currentPath
                            Size = if ($null -ne $currentSize) { [long]$currentSize } else { 0 }
                        }
                    }
                    $currentPath = $Matches[1]
                    $currentSize = $null
                    $isDirectory = $false
                }
                elseif ($lineStr -match '^Size = (\d+)$') {
                    $currentSize = $Matches[1]
                }
                elseif ($lineStr -match '^Folder = \+$') {
                    $isDirectory = $true
                }
            }

            # Capture the last entry
            if ($null -ne $currentPath -and -not $isDirectory) {
                $entries += [PSCustomObject]@{
                    Path = $currentPath
                    Size = if ($null -ne $currentSize) { [long]$currentSize } else { 0 }
                }
            }

            # The first entry from -slt is the archive itself; skip it
            if ($entries.Count -gt 1) {
                $entries = $entries[1..($entries.Count - 1)]
            }
            elseif ($entries.Count -eq 1) {
                # Single entry might be the archive path itself; check
                if ($entries[0].Path -eq $Archive) {
                    $entries = @()
                }
            }

            return $entries
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $listScript -ArgumentList $ArchivePath -ErrorAction Stop
        }
        else {
            $result = & $listScript -Archive $ArchivePath
        }
    }
    else {
        # .NET ZIP listing
        $listScript = {
            param([string]$Archive)

            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

            $entries = @()
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
            try {
                foreach ($entry in $zip.Entries) {
                    # Skip directory entries (they have empty names or end with /)
                    if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }

                    $entries += [PSCustomObject]@{
                        Path = $entry.FullName
                        Size = $entry.Length
                    }
                }
            }
            finally {
                $zip.Dispose()
            }

            return $entries
        }

        if ($Session) {
            $result = Invoke-Command -Session $Session -ScriptBlock $listScript -ArgumentList $ArchivePath -ErrorAction Stop
        }
        else {
            $result = & $listScript -Archive $ArchivePath
        }
    }

    # Ensure we always return an array
    if ($null -eq $result) {
        $result = @()
    }
    elseif ($result -isnot [array]) {
        $result = @($result)
    }

    Write-Verbose "Listed $($result.Count) file(s) in archive '$ArchivePath' (engine: $resolvedEngine)."

    return $result
}
