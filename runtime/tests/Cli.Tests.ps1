# Drives the real cli.ps1 as a child process against a stub runtime, to pin
# down argument forwarding. cli.ps1 calls exit, so it must not run in-process.
# The CLI itself needs pwsh 7; when the suite runs under Windows PowerShell the
# tests are skipped rather than failed.
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
    [string]$Scope = 'auto',
    [Parameter(Position = 1)][int]$Generation = 0,
    [switch]$NoElevate,
    [switch]$ShowUnchanged
)
"STUB Command=$Command Scope=$Scope Generation=$Generation NoElevate=$NoElevate ShowUnchanged=$ShowUnchanged"
exit 7
'@
    @{ flake = 'C:\nowhere'; name = 'testhost'; distro = 'NixOS' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $FakeLocalAppData 'winpkgs\cli.json') -Encoding utf8

    function Invoke-Cli {
        param([string[]]$CliArgs)
        $saved = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $FakeLocalAppData
        try {
            $out = & $Pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $Cli @CliArgs 2>&1 | ForEach-Object { "$_" }
            return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
        } finally {
            $env:LOCALAPPDATA = $saved
        }
    }
}

Describe 'winpkgs CLI argument forwarding to the local runtime' -Skip:(-not $PwshOnPath) {
    It 'forwards named parameters: rollback -Generation 2 -Scope user' {
        $r = Invoke-Cli @('rollback', '-Generation', '2', '-Scope', 'user')
        $r.Output | Should -Match 'STUB Command=rollback Scope=user Generation=2'
        $r.ExitCode | Should -Be 7
    }

    It 'forwards a positional generation: rollback 12' {
        $r = Invoke-Cli @('rollback', '12')
        $r.Output | Should -Match 'STUB Command=rollback Scope=auto Generation=12'
    }

    It 'shows command help for --help without touching the runtime' {
        $r = Invoke-Cli @('rollback', '--help')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'winpkgs rollback <N>'
        $r.Output | Should -Not -Match 'STUB'
    }

    It 'shows command help for `help <command>` and -h' {
        (Invoke-Cli @('help', 'apply')).Output | Should -Match 'winpkgs apply \['
        (Invoke-Cli @('plan', '-h')).Output | Should -Match 'winpkgs plan \['
        (Invoke-Cli @()).Output | Should -Match 'winpkgs <command>'
    }

    It 'forwards a switch: generations -ShowUnchanged' {
        $r = Invoke-Cli @('generations', '-ShowUnchanged')
        $r.Output | Should -Match 'Command=generations .*ShowUnchanged=True'
    }

    It 'propagates the runtime exit code' {
        (Invoke-Cli @('generations')).ExitCode | Should -Be 7
    }

    It 'reads defaults from cli.json' {
        $r = Invoke-Cli @('config')
        $r.Output | Should -Match 'Flake\s*:\s*C:\\nowhere'
        $r.Output | Should -Match 'Name\s*:\s*testhost'
    }

    It 'fails with one line for a missing flake path' {
        $r = Invoke-Cli @('plan', '-Flake', 'C:\definitely\not\here')
        $r.Output | Should -Match '^winpkgs: Flake path does not exist'
        $r.ExitCode | Should -Be 1
    }
}
