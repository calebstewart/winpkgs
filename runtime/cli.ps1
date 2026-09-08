#Requires -Version 7.0
<#
.SYNOPSIS
    winpkgs - drive this machine's configuration from Windows, no WSL shell needed.

.DESCRIPTION
    Installed to %LOCALAPPDATA%\winpkgs\bin by the winpkgs.cli module on every
    apply, together with its defaults (cli.json: flake, name, distro).

    Commands that need Nix run in the WSL distro:
      plan | apply | switch | wsl | build | shell
    Commands that only need the last-applied runtime run locally on Windows:
      generations | rollback | config

    The flake is given as a Windows path (env vars allowed, optional #name),
    and translated with wslpath inside the distro.

.EXAMPLE
    winpkgs plan
.EXAMPLE
    winpkgs switch
.EXAMPLE
    winpkgs plan -Flake 'D:\src\stewos#gaming-windows' -ShowUnchanged
.EXAMPLE
    winpkgs rollback 3
.EXAMPLE
    winpkgs rollback --help
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'apply', 'switch', 'wsl', 'build', 'shell', 'generations', 'status', 'rollback', 'config', 'help')]
    [string]$Command = 'help',

    # Windows path of the flake, optionally followed by #<configuration name>.
    [Alias('f')]
    [string]$Flake,

    # Name under windowsConfigurations. Defaults to cli.json, then this computer's name.
    [Alias('n')]
    [string]$Name,

    # WSL distribution that evaluates and builds. Defaults to cli.json, then "NixOS".
    [Alias('d')]
    [string]$Distro,

    # Everything else is passed through to activate / winpkgs.ps1 (-ShowUnchanged, -NoElevate, -Scope, -Generation, ...).
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'winpkgs'
$configPath = Join-Path $stateDir 'cli.json'
$runtimeEntry = Join-Path $stateDir 'runtime\winpkgs.ps1'

$defaults = @{}
if (Test-Path -LiteralPath $configPath) {
    $defaults = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
}

if (-not $Flake) { $Flake = [string]$defaults['flake'] }
if (-not $Name) { $Name = [string]$defaults['name'] }
if (-not $Distro) { $Distro = [string]$defaults['distro'] }
if ($Flake -match '^(.*)#([^#]+)$') { $Flake = $Matches[1]; $Name = $Matches[2] }
if (-not $Name) { $Name = $env:COMPUTERNAME.ToLowerInvariant() }
if (-not $Distro) { $Distro = 'NixOS' }

$commandHelp = [ordered]@{
    plan        = @('winpkgs plan [-ShowUnchanged] [-Scope user|machine]',
                    'Show what apply would change on Windows. Reads both scopes; never elevates.',
                    '  -ShowUnchanged        also list resources already in their desired state',
                    '  -Scope user|machine   limit to one scope (default: both)')
    apply       = @('winpkgs apply [-Scope user|machine] [-NoElevate] [-NoRestartExplorer]',
                    'Converge Windows. User scope runs as you; machine scope elevates once (UAC) if anything is out of state.',
                    '  -NoElevate            apply user scope only; list pending machine changes instead of prompting',
                    '  -NoRestartExplorer    do not restart Explorer even if shell settings changed')
    switch      = @('winpkgs switch', 'Activate the WSL distro (if the configuration embeds one), then converge Windows. The default.')
    wsl         = @('winpkgs wsl', 'Activate the WSL distro only.')
    build       = @('winpkgs build', 'Build the closure in the distro and print its store path.')
    shell       = @('winpkgs shell', 'Open a shell in the distro, in the flake directory.')
    generations = @('winpkgs generations', 'List applied generations, both scopes, oldest first. Local; no WSL involved.')
    rollback    = @('winpkgs rollback <N> [-Scope user|machine] [-NoRestartExplorer]',
                    'Undo generation N by replaying its journal in reverse, recording the rollback as a new generation. Local; no WSL involved. Machine-scope generations elevate once (UAC).',
                    '  <N>                   the generation number (one sequence across scopes; see generations)',
                    '  -Scope user|machine   only needed if N exists in both scopes (generations from before numbering was shared)',
                    '  -NoRestartExplorer    do not restart Explorer even if shell settings were restored')
    config      = @('winpkgs config', 'Show the effective flake, name and distro, and where they came from.')
}

function Show-Help {
    param([string]$Topic)
    if ($Topic -and $commandHelp.Contains($Topic)) {
        $commandHelp[$Topic] | ForEach-Object { Write-Host $_ }
        Write-Host ''
        Write-Host 'Global options: -Flake <win path>[#name]  -Name <name>  -Distro <distro>'
        return
    }
    Write-Host @"
winpkgs <command> [options]

  plan          show what apply would change on Windows
  apply         converge Windows
  switch        activate the WSL distro, then converge Windows (default)
  wsl           activate the WSL distro only
  build         build the closure and print its store path
  shell         open a shell in the distro, in the flake directory
  generations   list applied generations (local, no WSL)
  rollback <N>  undo generation N (local, no WSL; elevates for machine scope)
  config        show the effective flake, name and distro

  -Flake <win path>[#name]   default: $($defaults['flake'])
  -Name <name>               default: $Name
  -Distro <distro>           default: $Distro

winpkgs <command> --help   options for one command
"@
}

# `winpkgs rollback --help`, `winpkgs -h`, `winpkgs help rollback`
$wantsHelp = @($Rest | Where-Object { $_ -in '--help', '-h', '-help', '/?' }).Count -gt 0
if ($Command -eq 'help' -or $wantsHelp) {
    $topic = if ($Command -ne 'help') { $Command } elseif ($Rest.Count -gt 0) { $Rest[0] } else { '' }
    Show-Help -Topic $topic
    exit 0
}

function Invoke-LocalRuntime {
    param([string]$RuntimeCommand, [string[]]$RuntimeArgs)
    if (-not (Test-Path -LiteralPath $runtimeEntry)) {
        throw "No installed runtime at $runtimeEntry. Run 'winpkgs apply' (or the first activation from WSL) once."
    }
    # As a child process, not `& $runtimeEntry @RuntimeArgs`: splatting an
    # ordinary array passes every element positionally, so "-Generation 2" would
    # arrive as two string values. A native command line is re-parsed as typed.
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $runtimeEntry $RuntimeCommand @RuntimeArgs
    exit $LASTEXITCODE
}

function Resolve-FlakeInDistro {
    if (-not $Flake) {
        throw "No flake given and none in $configPath. Pass -Flake <windows path> or set winpkgs.cli.flake in the configuration."
    }
    $win = [Environment]::ExpandEnvironmentVariables($Flake)
    if (-not (Test-Path -LiteralPath $win)) { throw "Flake path does not exist: $win" }
    $win = (Resolve-Path -LiteralPath $win).ProviderPath
    $linux = (& wsl.exe -d $Distro -- wslpath -u $win 2>&1 | ForEach-Object { "$_" }) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $linux) { throw "wslpath failed in distro '$Distro' for $win`: $linux" }
    return $linux.Trim()
}

function Invoke-InDistro {
    param([string[]]$LinuxArgs)
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    & wsl.exe -d $Distro -- @LinuxArgs
    exit $LASTEXITCODE
}

# A CLI should fail with one line, not a PowerShell exception dump.
trap {
    Write-Host "winpkgs: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

switch ($Command) {
    'config' {
        [pscustomobject]@{
            Flake      = $Flake
            Name       = $Name
            Distro     = $Distro
            ConfigFile = $configPath
            Runtime    = if (Test-Path -LiteralPath $runtimeEntry) { $runtimeEntry } else { '(not installed)' }
        } | Format-List
    }

    { $_ -in 'generations', 'status' } { Invoke-LocalRuntime -RuntimeCommand 'generations' -RuntimeArgs $Rest }
    'rollback' { Invoke-LocalRuntime -RuntimeCommand 'rollback' -RuntimeArgs $Rest }

    'shell' {
        $dir = Resolve-FlakeInDistro
        & wsl.exe -d $Distro --cd $dir
        exit $LASTEXITCODE
    }

    'build' {
        $dir = Resolve-FlakeInDistro
        $ref = "$dir#windowsConfigurations.$Name.config.system.build.toplevel"
        Invoke-InDistro -LinuxArgs @('nix', 'build', $ref, '--no-link', '--print-out-paths')
    }

    default {
        # plan | apply | switch | wsl
        $dir = Resolve-FlakeInDistro
        $ref = "$dir#windowsConfigurations.$Name.config.system.build.toplevel"
        Invoke-InDistro -LinuxArgs (@('nix', 'run', $ref, '--', $Command) + $Rest)
    }
}
