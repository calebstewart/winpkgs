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
    # The selector `winpkgs installer` hands to nix; the verb checks it is installed.
    Set-Content -LiteralPath (Join-Path $RuntimeDir 'installer.nix') -Encoding utf8 -Value '{ flake }: flake'
    @{ flake = 'C:\nowhere'; system = 'testhost'; home = 'tester@testhost'; distro = 'NixOS' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $FakeLocalAppData 'winpkgs\cli.json') -Encoding utf8

    # A stand-in for wsl.exe (cli.ps1 takes one from WINPKGS_WSL): translates
    # paths the way wslpath does, and echoes any other command line back with
    # its arguments kept apart, so a test can see exactly what the distro
    # would have been asked to run. A plain script rather than an advanced
    # one: `$args` takes `-d` as a string, where a param block would refuse it.
    $WslStub = Join-Path $TestDrive 'wsl.ps1'
    Set-Content -LiteralPath $WslStub -Encoding utf8 -Value @'
$a = @($args | ForEach-Object { "$_" })
if ($a.Count -ge 6 -and $a[2] -eq '--exec' -and $a[3] -eq 'wslpath') {
    $win = $a[5]
    Write-Output ('/mnt/' + $win.Substring(0, 1).ToLowerInvariant() + ($win.Substring(2) -replace '\\', '/'))
    exit 0
}
Write-Output ('WSL ' + ($a -join ' | '))
exit 5
'@
    function ConvertTo-StubLinuxPath([string]$Win) {
        '/mnt/' + $Win.Substring(0, 1).ToLowerInvariant() + ($Win.Substring(2) -replace '\\', '/')
    }

    function Invoke-Cli {
        param([string[]]$CliArgs, [switch]$WithWsl)
        $saved = $env:LOCALAPPDATA
        $savedColor = $env:NO_COLOR
        $savedWsl = $env:WINPKGS_WSL
        $env:LOCALAPPDATA = $FakeLocalAppData
        # No ANSI escapes in captured output, whatever the host would do.
        $env:NO_COLOR = '1'
        if ($WithWsl) { $env:WINPKGS_WSL = $WslStub }
        try {
            $out = & $Pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $Cli @CliArgs 2>&1 | ForEach-Object { "$_" }
            return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
        } finally {
            $env:LOCALAPPDATA = $saved
            if ($null -eq $savedColor) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue } else { $env:NO_COLOR = $savedColor }
            if ($null -eq $savedWsl) { Remove-Item Env:\WINPKGS_WSL -ErrorAction SilentlyContinue } else { $env:WINPKGS_WSL = $savedWsl }
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

    It 'home rollback: no generation, so the runtime goes to the one before the current' {
        (Invoke-Cli @('home', 'rollback')).Output | Should -Match 'STUB Command=rollback Kind=home Generation=0'
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
        $r.Output | Should -Match 'winpkgs system\|home rollback \[N\]'
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

Describe 'winpkgs installer: the app in the distro, with every path translated' -Skip:(-not $PwshOnPath) {
    BeforeAll {
        $FlakeDir = Join-Path $TestDrive 'my flake'
        New-Item -ItemType Directory -Force -Path $FlakeDir | Out-Null
        # Spaces on purpose: a Windows path usually has one, and they must
        # arrive in the distro as one argument each.
        $Iso = Join-Path $TestDrive 'Win 11.iso'
        Set-Content -LiteralPath $Iso -Value 'not really'
        $Rootfs = Join-Path $TestDrive 'nixos.wsl'
        Set-Content -LiteralPath $Rootfs -Value 'not really'

        # The command line the stub saw, one argument per element.
        function Get-DistroCommand([string]$Output) {
            $line = @($Output -split "`n" | Where-Object { $_ -like 'WSL *' })
            $line.Count | Should -Be 1
            return , @($line[0].Substring(4) -split ' \| ')
        }
    }

    It 'runs the installer app of the flake''s own winpkgs input, through the runtime''s selector' {
        # -Out need not exist yet, only be made absolute and translated.
        $out = Join-Path $TestDrive 'media\out.iso'
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', $Iso, '-Flake', $FlakeDir, '-Out', $out)
        $r.ExitCode | Should -Be 5
        $cmd = Get-DistroCommand $r.Output
        $flake = ConvertTo-StubLinuxPath $FlakeDir
        $selector = ConvertTo-StubLinuxPath (Join-Path $FakeLocalAppData 'winpkgs\runtime\installer.nix')
        # The `--` after the distro name is there (wsl.exe needs it), but the
        # stub cannot see it: PowerShell keeps the first `--` on a script's
        # command line for itself, as the end of named parameters. wsl.exe is
        # native and gets it. The second one, the app's, survives.
        $expected = @('-d', 'NixOS', 'nix', 'run', '--impure', '--file', $selector, '--argstr', 'flake', $flake, 'installer', '--',
            '--flake', $flake, '--system', 'testhost', '--home', 'tester@testhost',
            '--windows-iso', (ConvertTo-StubLinuxPath $Iso), '--out', (ConvertTo-StubLinuxPath $out))
        ($cmd -join "`n") | Should -Be ($expected -join "`n")
    }

    It 'defaults -Out to winpkgs-installer-(system).iso where the command was typed' {
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', $Iso, '-Flake', $FlakeDir)
        $cmd = Get-DistroCommand $r.Output
        $i = [array]::IndexOf($cmd, '--out')
        $i | Should -BeGreaterThan 0
        $cmd[$i + 1] | Should -Match '^/mnt/[a-z]/.+/winpkgs-installer-testhost\.iso$'
    }

    It 'spells the verb''s options the app''s way, translating the ones that are files' {
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', $Iso, '-Flake', $FlakeDir,
            '-Edition', 'Windows 11 Home', '-productkey', 'ABCDE-FGHIJ', '-Locale', 'de-DE', '-DiskId', '1',
            '-KeepResult', '-DeleteWindowsIso', '-WslRootfs', $Rootfs, '--winpkgs-input', 'win')
        $r.ExitCode | Should -Be 5
        $cmd = Get-DistroCommand $r.Output
        $tail = $cmd[([array]::IndexOf($cmd, '--out') + 2)..($cmd.Count - 1)]
        $expected = @('--edition', 'Windows 11 Home', '--product-key', 'ABCDE-FGHIJ', '--locale', 'de-DE', '--disk-id', '1',
            '--keep-result', '--delete-windows-iso', '--wsl-rootfs', (ConvertTo-StubLinuxPath $Rootfs), '--winpkgs-input', 'win')
        ($tail -join "`n") | Should -Be ($expected -join "`n")
    }

    It 'refuses an option it does not have, and a file option without a file, before the distro is involved' {
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', $Iso, '-Flake', $FlakeDir, '-Bogus', '1')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "^winpkgs: installer has no option '-Bogus'"
        $r.Output | Should -Not -Match '^WSL'
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', $Iso, '-Flake', $FlakeDir, '-WslRootfs', 'C:\no\such.wsl')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '^winpkgs: -WslRootfs does not exist: C:\\no\\such\.wsl'
        $r.Output | Should -Not -Match '^WSL'
    }

    It 'needs the Windows ISO, and it has to exist' {
        $r = Invoke-Cli -WithWsl @('installer', '-Flake', $FlakeDir)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '^winpkgs: installer needs -WindowsIso'
        $r = Invoke-Cli -WithWsl @('installer', '-WindowsIso', 'C:\no\such.iso', '-Flake', $FlakeDir)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '^winpkgs: Windows ISO does not exist: C:\\no\\such\.iso'
        $r.Output | Should -Not -Match '^WSL'
    }

    It 'takes no kind, and has help that names its options' {
        $r = Invoke-Cli @('home', 'installer', '-WindowsIso', $Iso)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "'installer' takes no kind"
        foreach ($invocation in @(@('installer', '--help'), @('help', 'installer'))) {
            $r = Invoke-Cli $invocation
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'winpkgs installer -WindowsIso <iso>'
            $r.Output | Should -Match '-ProductKey <key>'
            $r.Output | Should -Match '-DeleteWindowsIso'
        }
        (Invoke-Cli @()).Output | Should -Match 'winpkgs installer -WindowsIso <iso>'
    }
}
