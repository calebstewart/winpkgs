# The elevated child is a generated script run by an unpackaged host. UAC cannot
# be exercised in tests, but the generated script can: run it non-elevated under
# Windows PowerShell (always present) against a stub runtime and check that the
# arguments bind as parameters and that failures reach the log.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Stub = Join-Path $TestDrive 'stub-winpkgs.ps1'
    Set-Content -LiteralPath $Stub -Encoding utf8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Config,
    [string]$Scope = 'auto',
    [int]$Generation = 0,
    [switch]$NoRestartExplorer
)
if ($Command -eq 'explode') { throw 'kaboom' }
"STUB Command=$Command Config=$Config Scope=$Scope Generation=$Generation NoRestartExplorer=$NoRestartExplorer"
'@
    $Host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Run-Generated([string[]]$RuntimeArgs) {
        $log = Join-Path $TestDrive ("elevated-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $script = & (Get-Module WinPkgs) { param($e, $a, $l) New-WinPkgsElevatedScript -Entry $e -RuntimeArgs $a -Log $l } $Stub $RuntimeArgs $log
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $null = & $Host51 -NoProfile -NoLogo -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        return @{ ExitCode = $LASTEXITCODE; Log = (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue) }
    }
}

Describe 'Format-WinPkgsCommandArguments' {
    It 'leaves parameter names bare and quotes values' {
        $s = & (Get-Module WinPkgs) { Format-WinPkgsCommandArguments -Arguments @('apply', '-Config', 'C:\a b\c.json', '-Scope', 'machine', '-NoRestartExplorer') }
        $s | Should -Be "'apply' -Config 'C:\a b\c.json' -Scope 'machine' -NoRestartExplorer"
    }
    It 'escapes single quotes inside values' {
        $s = & (Get-Module WinPkgs) { Format-WinPkgsCommandArguments -Arguments @("it's") }
        $s | Should -Be "'it''s'"
    }
}

Describe 'the generated elevated script (run non-elevated under Windows PowerShell)' {
    It 'binds -Config, -Scope and switches as parameters' {
        $r = Run-Generated @('apply', '-Config', 'C:\some path\config.json', '-Scope', 'machine', '-NoRestartExplorer')
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'STUB Command=apply Config=C:\\some path\\config.json Scope=machine Generation=0 NoRestartExplorer=True'
    }

    It 'binds -Generation for rollback' {
        $r = Run-Generated @('rollback', '-Scope', 'machine', '-Generation', '7', '-NoRestartExplorer')
        $r.Log | Should -Match 'Command=rollback .*Scope=machine Generation=7'
    }

    It 'writes a terminating error to the log and exits 1' {
        $r = Run-Generated @('explode')
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match 'ERROR: kaboom'
    }
}
