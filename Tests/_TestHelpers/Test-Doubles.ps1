# Shared Pester test doubles for the SEBackup suite.
#
# This file is NOT a *.Tests.ps1, so Pester's default discovery skips it; test files dot-source it
# from their BeforeAll, e.g.:
#     . "$PSScriptRoot/../_TestHelpers/Test-Doubles.ps1"
#
# It exists to de-duplicate the hand-rolled PSSession double that several suites previously each
# defined inline (the FormatterServices.GetUninitializedObject([PSSession]) trick).

function New-FakeSession {
    <#
    .SYNOPSIS
        Builds a type-satisfying System.Management.Automation.Runspaces.PSSession that touches no
        transport, for binding to [PSSession]-typed parameters under mock.

    .DESCRIPTION
        PSSession has no public constructor, so we materialize an UNINITIALIZED instance via
        FormatterServices. It binds to any [PSSession] parameter while opening no runspace and
        touching no WinRM. Every consumer of the returned object is expected to be mocked.

        When -Name / -Target are supplied, the corresponding adapted .Name / .ComputerName
        ScriptProperties are added so functions that read those (e.g. to parse a cache node from a
        "SEBackup-<node>" session name) see the intended values. Omit them for the bare double.

    .PARAMETER Name
        Optional value exposed as the session's .Name property.

    .PARAMETER Target
        Optional value exposed as the session's .ComputerName property. Named -Target (not
        -ComputerName) so PSScriptAnalyzer's PSAvoidUsingComputerNameHardcoded rule does not flag a
        literal bound to a -ComputerName parameter on this test helper.

    .OUTPUTS
        System.Management.Automation.Runspaces.PSSession (uninitialized).
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [string]$Name,
        [string]$Target
    )

    $session = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
        [System.Management.Automation.Runspaces.PSSession])

    if ($PSBoundParameters.ContainsKey('Name')) {
        $session | Add-Member -Force -MemberType ScriptProperty -Name Name `
            -Value ([scriptblock]::Create("'$Name'"))
    }
    if ($PSBoundParameters.ContainsKey('Target')) {
        $session | Add-Member -Force -MemberType ScriptProperty -Name ComputerName `
            -Value ([scriptblock]::Create("'$Target'"))
    }

    return $session
}
