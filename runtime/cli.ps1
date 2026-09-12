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
    its own generations, like NixOS and home-manager, and every verb acts on
    exactly one of them -- there is no "both", just as there is no command that
    is nixos-rebuild and home-manager at once:

      winpkgs system <verb>     the machine
      winpkgs home <verb>       this user

    Verbs that need Nix run in the WSL distro: plan, apply, switch, build, and
    system wsl. Verbs that only need the installed runtime run locally:
    generations, rollback, gc. Kind-less: config, shell, flake (nix flake
    <args> in the distro, in the flake directory), help.

.EXAMPLE
    winpkgs system switch          # WSL distro, then the machine (UAC once, if anything changed)
.EXAMPLE
    winpkgs home switch            # this user; never elevates
.EXAMPLE
    winpkgs home plan -ShowUnchanged
.EXAMPLE
    winpkgs home rollback          # back to the generation before the current one
.EXAMPLE
    winpkgs system rollback 3
.EXAMPLE
    winpkgs home gc -Keep 5
.EXAMPLE
    winpkgs flake update komorebi-asc   # nix flake update komorebi-asc, in the distro
#>
[CmdletBinding()]
param(
    # `system`, `home`, or a kind-less verb (config, shell, help).
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
# Every verb here forwards an exit code -- from the installed runtime, from
# `wsl.exe`, from `nix` -- and forwarding it is the whole job: `winpkgs system
# plan` on a flake that does not evaluate must exit non-zero, not raise. A host
# with $PSNativeCommandUseErrorActionPreference on would turn each of those into
# an exception before the code could be read.
$PSNativeCommandUseErrorActionPreference = $false
$stateDir = Join-Path $env:LOCALAPPDATA 'winpkgs'
$configPath = Join-Path $stateDir 'cli.json'
$runtimeEntry = Join-Path $stateDir 'runtime\winpkgs.ps1'
$kinds = @('system', 'home')
$kindVerbs = @('plan', 'apply', 'switch', 'wsl', 'build', 'generations', 'status', 'rollback', 'gc')
$rootVerbs = @('shell', 'config', 'flake', 'help')

# `winpkgs home plan ...`: the kind first, then the verb.
$Kind = ''
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
    plan        = @('winpkgs system|home plan [-ShowUnchanged]',
                    'Show what apply would change for that configuration. Never elevates.',
                    '  -ShowUnchanged        also list resources already in their desired state')
    apply       = @('winpkgs system|home apply [-NoElevate] [-NoRestartExplorer]',
                    'Converge. system elevates once (UAC) if anything is out of state; home runs as you and never elevates.',
                    '  -NoElevate            system: list pending changes instead of prompting',
                    '  -NoRestartExplorer    home: do not restart Explorer even if shell settings changed')
    switch      = @('winpkgs system|home switch',
                    'system: activate the WSL distro if the configuration embeds one, then apply. home: the same as apply.')
    wsl         = @('winpkgs system wsl', 'Activate the WSL distro only. It is part of the system configuration.')
    build       = @('winpkgs system|home build', 'Build that closure in the distro and print its store path.')
    shell       = @('winpkgs shell', 'Open a shell in the distro, in the flake directory.')
    flake       = @('winpkgs flake <args...>',
                    'Run `nix flake <args>` in the distro, in the flake directory: update, lock, metadata, check, show. Everything after `flake` goes to nix as it is, --help included.',
                    '  winpkgs flake update                 update every input',
                    '  winpkgs flake update komorebi-asc    update one input',
                    '  winpkgs flake metadata')
    generations = @('winpkgs system|home generations', 'List the generations of that kind, oldest first, and which one is current. Local; no WSL involved.')
    rollback    = @('winpkgs system|home rollback [N] [-NoRestartExplorer]',
                    'Go to generation N of that kind, as nixos-rebuild and home-manager do: N''s own runtime applies the configuration N keeps, and N is current again. Nothing new is recorded; the next apply is numbered after the newest. Local; no WSL. System generations elevate once (UAC).',
                    '  [N]                   the generation (see: winpkgs system|home generations); default: the one before the current')
    gc          = @('winpkgs system|home gc [-Keep N] [-OlderThan 30d] [-DryRun]',
                    'Delete old generations of that kind: the configurations they keep, their journals and backups. Never the current one. Local; no WSL. System generations elevate once (UAC) if any are due.',
                    '  -Keep N               never touch the newest N generations (default 10)',
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
winpkgs system|home <verb> [options]

  system        the machine: windowsConfigurations.$System (applied elevated)
  home          this user:   windowsHomeConfigurations."$HomeName" (applied as you)

  plan          show what apply would change
  apply         converge
  switch        system: WSL distro, then apply.  home: apply
  wsl           system only: activate the WSL distro
  build         build the closure and print its store path
  generations   list generations, and which is current (local, no WSL)
  rollback [N]  go to generation N, by default the previous one (local, no WSL)
  gc            delete old generations (local, no WSL)

winpkgs shell           open a shell in the distro, in the flake directory
winpkgs flake <args>    nix flake <args> in the distro, in the flake directory (update, lock, metadata, ...)
winpkgs config          show the effective flake, system, home and distro

  -Flake <win path>   default: $($defaults['flake'])
  -Distro <distro>    default: $Distro

winpkgs <verb> --help   options for one verb   (also -help; -h would be -Home)
"@
}

# `winpkgs rollback --help`, `winpkgs home plan -help`, `winpkgs help rollback`.
# Not `-h`: PowerShell binds unambiguous parameter prefixes, so `-h` is `-Home`.
$wantsHelp = @($Rest | Where-Object { $_ -in '--help', '-help', '/?' }).Count -gt 0
# `flake` passes everything through, `--help` included (nix's own help is the
# useful one); only a bare `winpkgs flake` shows ours.
if ($Command -eq 'flake') { $wantsHelp = $Rest.Count -eq 0 }
if ($Command -eq 'help' -or $wantsHelp) {
    $topic = if ($Command -ne 'help') { $Command } elseif ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    Show-Help -Topic $topic
    exit 0
}
if ($Command -notin $kindVerbs -and $Command -notin $rootVerbs) {
    Write-Host "winpkgs: unknown command '$Command'" -ForegroundColor Red
    Show-Help
    exit 1
}
if ($Command -in $kindVerbs -and -not $Kind) {
    Write-Host "winpkgs: '$Command' needs a kind: winpkgs system $Command or winpkgs home $Command" -ForegroundColor Red
    exit 1
}
if ($Command -in $rootVerbs -and $Kind) {
    Write-Host "winpkgs: '$Command' takes no kind: winpkgs $Command" -ForegroundColor Red
    exit 1
}
if ($Command -eq 'wsl' -and $Kind -ne 'system') {
    Write-Host 'winpkgs: the WSL distro belongs to the system configuration: winpkgs system wsl' -ForegroundColor Red
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
    # --exec, not `--`: without it wsl.exe hands the command to the login shell,
    # which eats the backslashes of a Windows path -- C:\src\config arrives as
    # C:srcconfig and wslpath fails. It survives only when the path contains a
    # space, because PowerShell then quotes the argument and sh keeps
    # backslashes inside double quotes, which is why a flake under
    # "C:\Users\Some One\..." works and one under "C:\Users\me\config" does not.
    # wslpath is a real binary, so --exec finds it without a login shell.
    $linux = (& wsl.exe -d $Distro --exec wslpath -u $win 2>&1 | ForEach-Object { "$_" }) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $linux) { throw "wslpath failed in distro '$Distro' for $win`: $linux" }
    return $linux.Trim()
}

function Get-Toplevel {
    # The flake attribute of the kind's closure. The home name may contain spaces
    # ("Caleb Stewart@host"), so it is a quoted attribute path component.
    param([string]$Dir)
    if ($Kind -eq 'system') { return "$Dir#windowsConfigurations.$System.config.system.build.toplevel" }
    return "$Dir#windowsHomeConfigurations.`"$HomeName`".config.system.build.toplevel"
}

function Invoke-InDistro {
    # -Cd: the distro directory to run in (a flake path from Resolve-FlakeInDistro),
    # for commands that act on the flake in the current directory.
    param([string[]]$LinuxArgs, [string]$Cd)
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    if ($Cd) {
        & wsl.exe -d $Distro --cd $Cd -- @LinuxArgs | Out-Host
    } else {
        & wsl.exe -d $Distro -- @LinuxArgs | Out-Host
    }
    return $LASTEXITCODE
}

switch ($Command) {
    'config' {
        # Plain lines, not Format-List: the formatter decorates property names
        # with ANSI escapes on some hosts (pwsh 7.4 in CI), which breaks anything
        # reading the output.
        $rows = [ordered]@{
            Flake      = $Flake
            System     = $System
            Home       = $HomeName
            Distro     = $Distro
            ConfigFile = $configPath
            Runtime    = if (Test-Path -LiteralPath $runtimeEntry) { $runtimeEntry } else { '(not installed)' }
        }
        foreach ($k in $rows.Keys) { Write-Host ('{0,-10} : {1}' -f $k, $rows[$k]) }
        exit 0
    }
    'shell' {
        $dir = Resolve-FlakeInDistro
        & wsl.exe -d $Distro --cd $dir
        exit $LASTEXITCODE
    }
    'flake' {
        # `nix flake update komorebi-asc` and friends act on the flake in the
        # current directory, so run in the flake's directory rather than
        # naming it: nix then edits the lock file in place, as it would from a
        # shell there.
        $dir = Resolve-FlakeInDistro
        exit (Invoke-InDistro -Cd $dir -LinuxArgs (@('nix', 'flake') + $Rest))
    }

    { $_ -in 'generations', 'status' } {
        exit (Invoke-LocalRuntime -RuntimeArgs (@('generations', '-Kind', $Kind) + $Rest))
    }
    'gc' {
        exit (Invoke-LocalRuntime -RuntimeArgs (@('gc', '-Kind', $Kind) + $Rest))
    }
    'rollback' {
        exit (Invoke-LocalRuntime -RuntimeArgs (@('rollback', '-Kind', $Kind) + $Rest))
    }

    'build' {
        $dir = Resolve-FlakeInDistro
        exit (Invoke-InDistro -LinuxArgs @('nix', 'build', (Get-Toplevel $dir), '--no-link', '--print-out-paths'))
    }
    default {
        # plan | apply | switch | wsl: `nix run <toplevel> -- <verb>` in the distro.
        # The closure's activate handles `switch` for either kind: the distro
        # first when it embeds one, then apply.
        $dir = Resolve-FlakeInDistro
        exit (Invoke-InDistro -LinuxArgs (@('nix', 'run', (Get-Toplevel $dir), '--', $Command) + $Rest))
    }
}
