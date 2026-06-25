#Requires -Module Pester

# Zip-slip / arbitrary-write containment for Expand-SEBArchive (issue #28). A backup archive --
# especially one whose path is supplied by a (possibly tampered) manifest -- is extracted on the
# production node. Without a containment check, an archive entry named '..\escape.txt' (or a rooted
# path) is written OUTSIDE the destination root, giving an attacker arbitrary write. These tests
# build an archive carrying such an entry and assert that Expand-SEBArchive REFUSES to extract it
# and that the would-be escape file is never created -- for BOTH extraction engines:
#   * dotnet  -> the System.IO.Compression.ZipFile entry-enumeration guard before Expand-Archive.
#   * 7zip    -> the '7z l -slt' listing guard before '7z x' (only when 7-Zip is installed; the .zip
#               is read fine by 7-Zip, so the same crafted archive exercises that path).
# A benign archive must still extract normally through both engines (no false positives).

# Whether real 7-Zip is installed must be known at DISCOVERY time, because the per-test
# '-Skip:' decision is evaluated during discovery (a $script: var set in BeforeAll is still
# $null then, which would wrongly skip every 7zip test on a machine that HAS 7-Zip).
BeforeDiscovery {
    $script:sevenZipAvailable = $false
    foreach ($c in @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))) {
        if ($c -and (Test-Path -Path $c -PathType Leaf)) { $script:sevenZipAvailable = $true; break }
    }
    if (-not $script:sevenZipAvailable) {
        $script:sevenZipAvailable = [bool](Get-Command -Name '7z.exe' -CommandType Application -ErrorAction SilentlyContinue)
    }
}

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    Import-Module "$repoRoot/SEBackup.psd1" -Force -DisableNameChecking 3>$null

    # Build a .zip containing the given entries (name -> content). Crafting a traversal entry needs
    # the low-level ZipArchive API; Compress-Archive will not emit a '..' entry.
    function New-RawZip {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][hashtable]$Entries
        )
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $zip.CreateEntry($name)
                $sw = [System.IO.StreamWriter]::new($entry.Open())
                try { $sw.Write([string]$Entries[$name]) } finally { $sw.Dispose() }
            }
        }
        finally {
            $zip.Dispose()
            $fs.Dispose()
        }
    }

    # Verbatim mirror of the 7-Zip pre-extraction FAIL-CLOSED accounting in
    # Modules/CompressionManager/Public/Expand-SEBArchive.ps1. Returns $true when extraction WOULD be
    # refused fail-closed (the '-slt' parse never reached the entries section -- the '----------'
    # separator was absent -- yet the listing still described file content), and $false when the
    # listing was well-formed enough for the real loop to have validated entries (or is a genuinely
    # empty archive with nothing to extract). If the in-function logic changes, update this mirror.
    function Test-SevenZipListingFailsClosed {
        param([string[]]$ListOutput)
        $inEntries = $false
        $pathLineCount = 0
        $sawEntryMetadata = $false
        foreach ($line in $ListOutput) {
            $lineStr = $line.ToString()
            if ($lineStr -match '^Path = (.+)$') { $pathLineCount++ }
            elseif ($lineStr -match '^(Size|Folder) = ') { $sawEntryMetadata = $true }
            if (-not $inEntries) {
                if ($lineStr -match '^-{5,}\s*$') { $inEntries = $true }
                continue
            }
        }
        return (-not $inEntries -and ($pathLineCount -gt 1 -or $sawEntryMetadata))
    }
}

Describe 'Expand-SEBArchive zip-slip containment' {

    BeforeEach {
        # A fresh sandbox per test: <work>/dest is the extraction target; <work>/escape.txt is the
        # sibling location a '..\escape.txt' entry would resolve to. We assert that sibling never
        # appears.
        $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ("sebexp_" + [guid]::NewGuid().ToString('n'))
        New-Item -Path $script:work -ItemType Directory -Force | Out-Null
        $script:dest = Join-Path $script:work 'dest'
        $script:escapeTarget = Join-Path $script:work 'escape.txt'
        $script:zipPath = Join-Path $script:work 'payload.zip'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'dotnet engine' {
        It 'refuses an archive whose entry escapes via ..\ and writes nothing outside the destination' {
            New-RawZip -Path $script:zipPath -Entries @{
                'good.txt'      = 'benign'
                '..\escape.txt' = 'PWNED'
            }

            { Expand-SEBArchive -ArchivePath $script:zipPath -DestinationPath $script:dest -Engine dotnet -ErrorAction Stop } |
                Should -Throw -ErrorId '*' -Because 'a traversal entry must abort extraction'

            # The crafted escape file must NOT exist outside the destination root.
            Test-Path -LiteralPath $script:escapeTarget | Should -BeFalse -Because 'the escaping entry must never be written'
            # And the benign entry must not have been written either (we abort BEFORE extracting).
            Test-Path -LiteralPath (Join-Path $script:dest 'good.txt') | Should -BeFalse -Because 'extraction is refused atomically, before any file is written'
        }

        It 'extracts a benign archive normally (no false positive)' {
            New-RawZip -Path $script:zipPath -Entries @{
                'good.txt'     = 'hello'
                'sub/nest.txt' = 'world'
            }

            { Expand-SEBArchive -ArchivePath $script:zipPath -DestinationPath $script:dest -Engine dotnet -ErrorAction Stop } |
                Should -Not -Throw

            Test-Path -LiteralPath (Join-Path $script:dest 'good.txt') | Should -BeTrue
            Get-Content -LiteralPath (Join-Path $script:dest 'good.txt') -Raw | Should -Match 'hello'
            Test-Path -LiteralPath (Join-Path $script:dest 'sub/nest.txt') | Should -BeTrue
        }
    }

    Context '7zip engine' {
        It 'refuses an archive whose entry escapes via ..\ and writes nothing outside the destination' -Skip:(-not $script:sevenZipAvailable) {
            New-RawZip -Path $script:zipPath -Entries @{
                'good.txt'      = 'benign'
                '..\escape.txt' = 'PWNED'
            }

            { Expand-SEBArchive -ArchivePath $script:zipPath -DestinationPath $script:dest -Engine 7zip -ErrorAction Stop } |
                Should -Throw -Because 'the 7z listing guard must reject a traversal entry before extracting'

            Test-Path -LiteralPath $script:escapeTarget | Should -BeFalse -Because 'the escaping entry must never be written'
            Test-Path -LiteralPath (Join-Path $script:dest 'good.txt') | Should -BeFalse -Because 'extraction is refused before any file is written'
        }

        It 'extracts a benign archive normally through 7-Zip (the archive header is not mistaken for an entry)' -Skip:(-not $script:sevenZipAvailable) {
            New-RawZip -Path $script:zipPath -Entries @{
                'good.txt' = 'hello-7z'
            }

            { Expand-SEBArchive -ArchivePath $script:zipPath -DestinationPath $script:dest -Engine 7zip -ErrorAction Stop } |
                Should -Not -Throw -Because 'a benign archive must not trip the containment guard (regression: the -slt archive-header Path line must be skipped)'

            Test-Path -LiteralPath (Join-Path $script:dest 'good.txt') | Should -BeTrue
            Get-Content -LiteralPath (Join-Path $script:dest 'good.txt') -Raw | Should -Match 'hello-7z'
        }
    }

    Context '7-Zip listing fail-closed rule (issue #28)' {
        # The original 7z guard only inspected entries AFTER a '^-{5,}' separator line. If 7-Zip ever
        # emitted an '-slt' listing without that separator, $inEntries stayed false, NO entry was
        # checked, and a traversal archive would be handed straight to '7z x'. The fix makes that case
        # FAIL CLOSED. 7-Zip's binary path is resolved inside the function's scriptblock (Program Files
        # first) and a real 7z.exe is normally installed, so '& $sevenZip' cannot be intercepted to
        # inject a separator-less listing without swapping the binary; the fail-closed PREDICATE is
        # therefore pinned directly (mirror function above).
        It 'does NOT fail closed for a well-formed non-empty listing (separator present)' {
            # Header 'Path =', a separator, then a real entry block: the entries section IS reached,
            # so the real loop validates each entry path -- no fail-closed abort.
            $listing = @(
                'Path = C:\backups\world.7z'
                'Type = 7z'
                ''
                '----------'
                'Path = Sandbox.sbc'
                'Size = 123'
                'Folder = -'
            )
            Test-SevenZipListingFailsClosed -ListOutput $listing | Should -BeFalse
        }

        It 'FAILS CLOSED for a non-empty listing that never delimits its entry section (no separator)' {
            # An entry 'Path = ..\evil.txt' appears but, with no separator, the old code would have
            # validated NOTHING and extracted. The fix refuses it.
            $listing = @(
                'Path = C:\backups\world.7z'
                'Type = 7z'
                'Path = ..\evil.txt'
                'Size = 5'
            )
            Test-SevenZipListingFailsClosed -ListOutput $listing | Should -BeTrue
        }

        It 'FAILS CLOSED when only per-entry metadata (Size/Folder) leaks without a separator' {
            $listing = @(
                'Path = C:\backups\world.7z'
                'Size = 999'
            )
            Test-SevenZipListingFailsClosed -ListOutput $listing | Should -BeTrue
        }

        It 'does NOT fail closed for an empty archive (header-only, nothing to extract)' {
            # Only the archive's own header 'Path =' and no per-entry metadata: there is nothing to
            # extract that could escape, so an empty archive must not be penalised.
            $listing = @(
                'Path = C:\backups\empty.7z'
                'Type = 7z'
                'Physical Size = 22'
            )
            Test-SevenZipListingFailsClosed -ListOutput $listing | Should -BeFalse
        }
    }
}
