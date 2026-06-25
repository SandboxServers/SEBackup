# Shared test helpers for the ManifestManager Pester suites.
#
# Dot-sourced from New-SEBManifest.Tests.ps1 and Compare-SEBManifest.Tests.ps1 so the manifest
# "files" entry factory lives in ONE place and cannot drift between the two suites (it was
# previously copy-pasted verbatim into both). Defines functions in the dot-sourcing scope; call
# from a BeforeAll so they are visible to the Describe/It blocks.

function New-FileEntry {
    <#
        Build a single manifest 'files' entry exactly the way New-SEBManifest records one:
        a hashtable with size / sha256 / last_write keys. last_write defaults to a fixed ISO-8601
        UTC instant so size/hash are the only things a test needs to vary.
    #>
    param(
        [long]$Size,
        [string]$Sha256,
        [string]$LastWrite = '2026-01-01T00:00:00.0000000Z'
    )
    @{ size = $Size; sha256 = $Sha256; last_write = $LastWrite }
}
