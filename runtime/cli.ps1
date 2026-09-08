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
    winpkgs rollback -Scope user -Generation 3
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

function Show-Help {
    Write-Host @"
winpkgs <command> [options] [passthrough args]

  plan          show what apply would change on Windows
  apply         converge Windows
  switch        activate the WSL distro, then converge Windows
  wsl           activate the WSL distro only
  build         build the closure and print its store path
  shell         open a shell in the distro, in the flake directory
  generations   list applied generations (local, no WSL)
  rollback      undo a generation: -Scope user|machine -Generation N (local, no WSL)
  config        show the effective flake, name and distro

  -Flake <win path>[#name]   default: $($defaults['flake'])
  -Name <name>               default: $Name
  -Distro <distro>           default: $Distro

Passthrough examples: -ShowUnchanged, -NoElevate, -NoRestartExplorer
"@
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
    'help' { Show-Help }

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
