#Requires -Version 7.0
<#
.SYNOPSIS
    winpkgs - drive this machine's configuration from Windows, no WSL shell needed.

.DESCRIPTION
    Installed to %LOCALAPPDATA%\winpkgs\bin by the winpkgs.cli module of a home
    configuration, together with its defaults (cli.json: flake, system, home,
    distro).

    A machine has a system configuration (windowsConfigurations.<host>, applied
    elevated) and, per user, a home configuration
    (windowsHomeConfigurations."<user>@<host>", applied as the user). Each keeps
    its own generations, like NixOS and home-manager.

      winpkgs system <verb>     the machine
      winpkgs home <verb>       this user
      winpkgs <verb>            both, where that makes sense (plan, apply, switch, build)

    Verbs that need Nix run in the WSL distro: plan, apply, switch, wsl, build,
    shell. Verbs that only need the installed runtime run locally: generations,
    rollback, gc, config.

.EXAMPLE
    winpkgs switch                 # WSL distro, then system (UAC once), then home
.EXAMPLE
    winpkgs home plan -ShowUnchanged
.EXAMPLE
    winpkgs system rollback 3
.EXAMPLE
    winpkgs home gc -Keep 5
#>
[CmdletBinding()]
param(
    # `system`, `home`, or a verb (both).
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    # Windows path of the flake. Env vars allowed.
    [Alias('f')]
    [string]$Flake,

    # Name under windowsConfigurations. Defaults to cli.json, then this computer's name.
    [string]$System,

    # Name under windowsHomeConfigurations. Defaults to cli.json, then <user>@<system>.
    # ($Home itself is an automatic, read-only PowerShell variable.)
    [Alias('Home')]
    [string]$HomeName,

    # WSL distribution that evaluates and builds. Defaults to cli.json, then "NixOS".
    [Alias('d')]
    [string]$Distro,

    # Everything else: the verb when a kind was given, then passthrough for the runtime
    # (-ShowUnchanged, -NoElevate, -Keep, -OlderThan, a generation number, ...).
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'winpkgs'
$configPath = Join-Path $stateDir 'cli.json'
$runtimeEntry = Join-Path $stateDir 'runtime\winpkgs.ps1'
$kinds = @('system', 'home')
$verbs = @('plan', 'apply', 'switch', 'wsl', 'build', 'shell', 'generations', 'status', 'rollback', 'gc', 'config', 'help')

# `winpkgs home plan ...`: the kind first, then the verb.
$Kind = 'auto'
if ($Command -in $kinds) {
    $Kind = $Command
    $Command = if ($Rest.Count -gt 0) { $Rest[0] } else { 'help' }
    $Rest = if ($Rest.Count -gt 1) { $Rest[1..($Rest.Count - 1)] } else { @() }
}

$defaults = @{}
if (Test-Path -LiteralPath $configPath) {
    $defaults = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
}
if (-not $Flake) { $Flake = [string]$defaults['flake'] }
if (-not $System) { $System = [string]$defaults['system'] }
if (-not $HomeName) { $HomeName = [string]$defaults['home'] }
if (-not $Distro) { $Distro = [string]$defaults['distro'] }
if (-not $System) { $System = $env:COMPUTERNAME.ToLowerInvariant() }
if (-not $HomeName) { $HomeName = "$env:USERNAME@$System" }
if (-not $Distro) { $Distro = 'NixOS' }

$commandHelp = [ordered]@{
    plan        = @('winpkgs [system|home] plan [-ShowUnchanged]',
                    'Show what apply would change. Reads both configurations by default; never elevates.',
                    '  -ShowUnchanged        also list resources already in their desired state')
    apply       = @('winpkgs [system|home] apply [-NoElevate] [-NoRestartExplorer]',
                    'Converge. The system configuration elevates once (UAC) if anything is out of state; the home configuration runs as you.',
                    '  -NoElevate            system: list pending changes instead of prompting',
                    '  -NoRestartExplorer    home: do not restart Explorer even if shell settings changed')
    switch      = @('winpkgs [system|home] switch',
                    'Activate the WSL distro if the system configuration embeds one, apply the system configuration, then the home configuration. The default.')
    wsl         = @('winpkgs wsl', 'Activate the WSL distro only (part of the system configuration).')
    build       = @('winpkgs [system|home] build', 'Build the closure(s) in the distro and print the store path(s).')
    shell       = @('winpkgs shell', 'Open a shell in the distro, in the flake directory.')
    generations = @('winpkgs [system|home] generations', 'List applied generations, oldest first. Local; no WSL involved.')
    rollback    = @('winpkgs system|home rollback <N> [-NoRestartExplorer]',
                    'Undo generation N of that kind by replaying its journal in reverse, recording the rollback as a new generation. Local; no WSL. System generations elevate once (UAC).',
                    '  <N>                   the generation number (see: winpkgs system|home generations)')
    gc          = @('winpkgs [system|home] gc [-Keep N] [-OlderThan 30d] [-DryRun]',
                    'Delete old generations and the backups behind their rollback. Local; no WSL. System generations elevate once (UAC) if any are due.',
                    '  -Keep N               never touch the newest N generations per kind (default 10)',
                    '  -OlderThan <dur>      beyond those, only delete generations started longer ago than this (30d, 12h, 90m)',
                    '  -DryRun               list what would be removed',
                    'winpkgs.generations.{keep,deleteOlderThan} in a configuration does the same automatically at the end of every apply.')
    config      = @('winpkgs config', 'Show the effective flake, system, home and distro, and where they came from.')
}

function Show-Help {
    param([string]$Topic)
    if ($Topic -and $commandHelp.Contains($Topic)) {
        $commandHelp[$Topic] | ForEach-Object { Write-Host $_ }
        Write-Host ''
        Write-Host 'Global options: -Flake <win path>  -System <name>  -Home <name>  -Distro <distro>'
        return
    }
    Write-Host @"
winpkgs [system|home] <verb> [options]

  system        the machine: windowsConfigurations.$System (applied elevated)
  home          this user:   windowsHomeConfigurations."$HomeName" (applied as you)
  neither       both, in that order

  plan          show what apply would change
  apply         converge
  switch        WSL distro, then system, then home (default)
  wsl           activate the WSL distro only
  build         build the closure and print its store path
  shell         open a shell in the distro, in the flake directory
  generations   list applied generations (local, no WSL)
  rollback <N>  undo generation N -- needs system or home (local, no WSL)
  gc            delete old generations (local, no WSL)
  config        show the effective flake, system, home and distro

  -Flake <win path>   default: $($defaults['flake'])
  -Distro <distro>    default: $Distro

winpkgs <verb> --help   options for one verb   (also -help; -h would be -Home)
"@
}

# `winpkgs rollback --help`, `winpkgs plan -help`, `winpkgs help rollback`.
# Not `-h`: PowerShell binds unambiguous parameter prefixes, so `-h` is `-Home`.
$wantsHelp = @($Rest | Where-Object { $_ -in '--help', '-help', '/?' }).Count -gt 0
if ($Command -eq 'help' -or $wantsHelp) {
    $topic = if ($Command -ne 'help') { $Command } elseif ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    Show-Help -Topic $topic
    exit 0
}
if ($Command -notin $verbs) {
    Write-Host "winpkgs: unknown command '$Command'" -ForegroundColor Red
    Show-Help
    exit 1
}

# A CLI should fail with one line, not a PowerShell exception dump.
trap {
    Write-Host "winpkgs: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function Invoke-LocalRuntime {
    param([string[]]$RuntimeArgs)
    if (-not (Test-Path -LiteralPath $runtimeEntry)) {
        throw "No installed runtime at $runtimeEntry. Apply the home configuration once (from WSL the first time)."
    }
    # As a child process, not `& $runtimeEntry @RuntimeArgs`: splatting an
    # ordinary array passes every element positionally, so "-Generation 2" would
    # arrive as two string values. A native command line is re-parsed as typed.
    $pwsh = (Get-Process -Id $PID).Path
    # Out-Host: the child's output must reach the terminal, not become this
    # function's return value alongside the exit code.
    & $pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $runtimeEntry @RuntimeArgs | Out-Host
    return $LASTEXITCODE
}

function Resolve-FlakeInDistro {
    if (-not $Flake) {
        throw "No flake given and none in $configPath. Pass -Flake <windows path> or set winpkgs.cli.flake in the home configuration."
    }
    $win = [Environment]::ExpandEnvironmentVariables($Flake)
    if (-not (Test-Path -LiteralPath $win)) { throw "Flake path does not exist: $win" }
    $win = (Resolve-Path -LiteralPath $win).ProviderPath
    $linux = (& wsl.exe -d $Distro -- wslpath -u $win 2>&1 | ForEach-Object { "$_" }) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $linux) { throw "wslpath failed in distro '$Distro' for $win`: $linux" }
    return $linux.Trim()
}

function Get-Toplevel {
    # The flake attribute of a kind's closure. The home name may contain spaces
    # ("Caleb Stewart@host"), so it is a quoted attribute path component.
    param([string]$Dir, [string]$OfKind)
    if ($OfKind -eq 'system') { return "$Dir#windowsConfigurations.$System.config.system.build.toplevel" }
    return "$Dir#windowsHomeConfigurations.`"$HomeName`".config.system.build.toplevel"
}

function Invoke-InDistro {
    param([string[]]$LinuxArgs)
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    & wsl.exe -d $Distro -- @LinuxArgs | Out-Host
    return $LASTEXITCODE
}

$forKinds = if ($Kind -eq 'auto') { $kinds } else { @($Kind) }

switch ($Command) {
    'config' {
        [pscustomobject]@{
            Flake      = $Flake
            System     = $System
            Home       = $HomeName
            Distro     = $Distro
            ConfigFile = $configPath
            Runtime    = if (Test-Path -LiteralPath $runtimeEntry) { $runtimeEntry } else { '(not installed)' }
        } | Format-List
        exit 0
    }

    { $_ -in 'generations', 'status' } {
        exit (Invoke-LocalRuntime -RuntimeArgs (@('generations', '-Kind', $Kind) + $Rest))
    }
    'gc' {
        exit (Invoke-LocalRuntime -RuntimeArgs (@('gc', '-Kind', $Kind) + $Rest))
    }
    'rollback' {
        if ($Kind -eq 'auto') { throw 'rollback needs a kind: winpkgs system rollback <N> or winpkgs home rollback <N>' }
        exit (Invoke-LocalRuntime -RuntimeArgs (@('rollback', '-Kind', $Kind) + $Rest))
    }

    'shell' {
        $dir = Resolve-FlakeInDistro
        & wsl.exe -d $Distro --cd $dir
        exit $LASTEXITCODE
    }
    'wsl' {
        $dir = Resolve-FlakeInDistro
        exit (Invoke-InDistro -LinuxArgs @('nix', 'run', (Get-Toplevel $dir 'system'), '--', 'wsl'))
    }
    'build' {
        $dir = Resolve-FlakeInDistro
        foreach ($k in $forKinds) {
            $code = Invoke-InDistro -LinuxArgs @('nix', 'build', (Get-Toplevel $dir $k), '--no-link', '--print-out-paths')
            if ($code -ne 0) { exit $code }
        }
        exit 0
    }

    default {
        # plan | apply | switch: system first, then home. `switch` on the system
        # side also activates the WSL distro; on the home side it is an apply.
        $dir = Resolve-FlakeInDistro
        foreach ($k in $forKinds) {
            $verb = if ($Command -eq 'switch' -and $k -eq 'home') { 'apply' } else { $Command }
            if ($forKinds.Count -gt 1) { Write-Host "== $k ==" -ForegroundColor Cyan }
            $code = Invoke-InDistro -LinuxArgs (@('nix', 'run', (Get-Toplevel $dir $k), '--', $verb) + $Rest)
            if ($code -ne 0) { exit $code }
        }
        exit 0
    }
}
