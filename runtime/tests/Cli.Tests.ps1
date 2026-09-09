# Drives the real cli.ps1 as a child process against a stub runtime, to pin
# down subcommand parsing and argument forwarding. cli.ps1 calls exit, so it
# must not run in-process. The CLI itself needs pwsh 7; when the suite runs
# under Windows PowerShell the tests are skipped rather than failed.
BeforeDiscovery {
    $script:PwshOnPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
}

BeforeAll {
    $Cli = Join-Path $PSScriptRoot '..\cli.ps1'
    $Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source

    # cli.ps1 finds everything under %LOCALAPPDATA%\winpkgs; point that at the test drive.
    $FakeLocalAppData = Join-Path $TestDrive 'lad'
    $RuntimeDir = Join-Path $FakeLocalAppData 'winpkgs\runtime'
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Set-Content -LiteralPath (Join-Path $RuntimeDir 'winpkgs.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Kind = '(none)',
    [Parameter(Position = 1)][int]$Generation = 0,
    [int]$Keep = 10,
    [string]$OlderThan,
    [switch]$NoElevate,
    [switch]$ShowUnchanged
)
"STUB Command=$Command Kind=$Kind Generation=$Generation Keep=$Keep OlderThan=$OlderThan NoElevate=$NoElevate ShowUnchanged=$ShowUnchanged"
exit 7
'@
    @{ flake = 'C:\nowhere'; system = 'testhost'; home = 'tester@testhost'; distro = 'NixOS' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $FakeLocalAppData 'winpkgs\cli.json') -Encoding utf8

    function Invoke-Cli {
        param([string[]]$CliArgs)
        $saved = $env:LOCALAPPDATA
        $savedColor = $env:NO_COLOR
        $env:LOCALAPPDATA = $FakeLocalAppData
        # No ANSI escapes in captured output, whatever the host would do.
        $env:NO_COLOR = '1'
        try {
            $out = & $Pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $Cli @CliArgs 2>&1 | ForEach-Object { "$_" }
            return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
        } finally {
            $env:LOCALAPPDATA = $saved
            if ($null -eq $savedColor) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue } else { $env:NO_COLOR = $savedColor }
        }
    }
}

Describe 'winpkgs CLI: kinds, verbs and forwarding' -Skip:(-not $PwshOnPath) {
    It 'home rollback -Generation 2: kind and named parameter reach the runtime' {
        $r = Invoke-Cli @('home', 'rollback', '-Generation', '2')
        $r.Output | Should -Match 'STUB Command=rollback Kind=home Generation=2'
        $r.ExitCode | Should -Be 7
    }

    It 'system rollback 12: positional generation' {
        (Invoke-Cli @('system', 'rollback', '12')).Output | Should -Match 'STUB Command=rollback Kind=system Generation=12'
    }

    It 'every verb that touches a configuration needs a kind: <_>' -ForEach @('plan', 'apply', 'switch', 'build', 'generations', 'gc', 'rollback') {
        $r = Invoke-Cli @($_, '3')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "'$_' needs a kind: winpkgs system $_ or winpkgs home $_"
        $r.Output | Should -Not -Match 'STUB'
    }

    It 'generations and gc forward the kind and the rest' {
        (Invoke-Cli @('home', 'generations')).Output | Should -Match 'STUB Command=generations Kind=home'
        (Invoke-Cli @('system', 'gc', '-Keep', '3', '-OlderThan', '7d')).Output | Should -Match 'STUB Command=gc Kind=system .*Keep=3 OlderThan=7d'
    }

    It 'wsl belongs to system; config takes no kind' {
        $r = Invoke-Cli @('home', 'wsl')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'winpkgs system wsl'
        $r = Invoke-Cli @('system', 'config')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "takes no kind"
    }

    It 'shows verb help without touching the runtime' {
        $r = Invoke-Cli @('rollback', '--help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'winpkgs system\|home rollback <N>'
        $r.Output | Should -Not -Match 'STUB'
        (Invoke-Cli @('help', 'apply')).Output | Should -Match 'winpkgs system\|home apply'
        (Invoke-Cli @('home', 'plan', '-help')).Output | Should -Match 'winpkgs system\|home plan'
        # -h is a prefix of -Home and binds to it; it must not be mistaken for help.
        (Invoke-Cli @('config', '-h', 'x@y')).Output | Should -Match 'Home\s*:\s*x@y'
        (Invoke-Cli @()).Output | Should -Match 'winpkgs system\|home <verb>'
        (Invoke-Cli @('home')).Output | Should -Match 'winpkgs system\|home <verb>'
    }

    It 'reads defaults from cli.json' {
        $r = Invoke-Cli @('config')
        $r.Output | Should -Match 'Flake\s*:\s*C:\\nowhere'
        $r.Output | Should -Match 'System\s*:\s*testhost'
        $r.Output | Should -Match 'Home\s*:\s*tester@testhost'
    }

    It 'rejects an unknown verb' {
        $r = Invoke-Cli @('home', 'frobnicate')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "unknown command 'frobnicate'"
    }

    It 'fails with one line for a missing flake path' {
        $r = Invoke-Cli @('home', 'plan', '-Flake', 'C:\definitely\not\here')
        $r.Output | Should -Match '^winpkgs: Flake path does not exist'
        $r.ExitCode | Should -Be 1
    }

    It 'flake is kind-less, resolves the flake before running, and shows help only when bare' {
        $r = Invoke-Cli @('home', 'flake', 'update')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "'flake' takes no kind"
        # Routed to the distro (which the test host may not have): it must get as
        # far as resolving the flake, and never near the local runtime.
        $r = Invoke-Cli @('flake', 'update', 'komorebi-asc', '-Flake', 'C:\definitely\not\here')
        $r.Output | Should -Match '^winpkgs: Flake path does not exist'
        $r.Output | Should -Not -Match 'STUB'
        # A bare `winpkgs flake` is ours; `--help` after it is nix's, so it is not intercepted.
        $r = Invoke-Cli @('flake')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'winpkgs flake <args\.\.\.>'
        $r = Invoke-Cli @('flake', '--help', '-Flake', 'C:\definitely\not\here')
        $r.Output | Should -Match '^winpkgs: Flake path does not exist'
    }
}
