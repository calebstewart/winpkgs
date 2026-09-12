<#
    winpkgs/activation - a command run at the end of an apply when what it
    depends on changed. For the one thing no resource can say: tell a running
    program about a change, as a service manager is told to re-read its units.
    home-manager's `home.activation`, NixOS's activation scripts. Either kind.

    properties: name, command (PowerShell), revision (a hash of the command
    and its triggers)

    Its state is the revision it last ran at, in the kind's ledger
    (`activations`), and Test is having run at this one: an apply whose
    triggers did not change does not run it. The plan puts every activation
    after the other resources and after pruning, since what it reacts to is
    the rest of the apply -- a unit file deleted because it left the
    configuration, say.

    Set runs the command in a child process of this host, with the PATH a new
    session would have (the machine's and the user's, from the registry: the
    apply may have just changed them), and prints what it writes. Only a
    command that succeeds is recorded; one that fails fails the apply, and the
    next apply runs it again. Restore puts the recorded revision back, so an
    undone apply's activation runs again at the next one.
#>

function Get-WinPkgsActivationState {
    # The live ledger during an apply, a fresh read during a plan.
    param([hashtable]$Context)
    if ($Context -and $Context['State']) { return $Context['State'] }
    return Read-WinPkgsState -Kind $Context['Kind']
}

function Get-WinPkgsSessionPath {
    # PATH as a session starting now would have it: the machine's, then the user's.
    $parts = foreach ($scope in 'Machine', 'User') { [Environment]::GetEnvironmentVariable('Path', $scope) }
    return [Environment]::ExpandEnvironmentVariables((@($parts | Where-Object { $_ }) -join ';'))
}

function Invoke-WinPkgsActivationCommand {
    param([Parameter(Mandatory)][string]$Command)
    # A PowerShell error fails the script through 'Stop'; so does its last
    # native command's exit code, passed on as the script's own.
    $script = "`$ErrorActionPreference = 'Stop'`n& {`n$Command`n}`nif (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
    # Encoded: Windows PowerShell 5.1 strips the double quotes a command line
    # would carry.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $saved = $env:Path
    try {
        $env:Path = Get-WinPkgsSessionPath
        return Invoke-WinPkgsExternal -Command (Get-Process -Id $PID).Path -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } finally {
        $env:Path = $saved
    }
}

function Get-WinPkgsActivation {
    param([hashtable]$Properties, [hashtable]$Context)
    $state = Get-WinPkgsActivationState -Context $Context
    $recorded = $state['activations'][[string]$Properties['name']]
    return @{ exists = ($null -ne $recorded); revision = $recorded }
}

function Test-WinPkgsActivation {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([string]$Current['revision'] -ceq [string]$Properties['revision'])
}

function Set-WinPkgsActivation {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $name = [string]$Properties['name']
    $result = Invoke-WinPkgsActivationCommand -Command ([string]$Properties['command'])
    foreach ($line in $result.lines) { Write-Host "    | $line" }
    if ($result.failed) {
        throw "Activation $name failed (exit code $($result.code)); the next apply runs it again."
    }
    if ($Context -and $Context['State']) {
        $Context['State']['activations'][$name] = [string]$Properties['revision']
    }
}

function Restore-WinPkgsActivation {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    if (-not $Context -or -not $Context['State']) { return }
    $name = [string]$Properties['name']
    if ($null -eq $Before['revision']) { $Context['State']['activations'].Remove($name) }
    else { $Context['State']['activations'][$name] = [string]$Before['revision'] }
}

function Format-WinPkgsActivationChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $first = @(([string]$Properties['command']).Trim() -split "`r?`n")[0]
    return "runs: $first"
}

Register-WinPkgsResource -Type 'winpkgs/activation' `
    -Get 'Get-WinPkgsActivation' -Test 'Test-WinPkgsActivation' -Set 'Set-WinPkgsActivation' `
    -Restore 'Restore-WinPkgsActivation' -Describe 'Format-WinPkgsActivationChange'
