#Requires -Version 5.1
<#
.SYNOPSIS
    Take a clean Windows install to a winpkgs-managed machine, in one command.

.DESCRIPTION
    Runs under Windows PowerShell 5.1, which is all a fresh Windows has, and
    assumes nothing else on the machine: no WSL, no Nix, no PowerShell 7, no git.

    Eight phases. Each one looks at the machine before it acts, and the run
    records which of them finished under %LOCALAPPDATA%\winpkgs\install, so an
    interrupted run continues where it stopped rather than starting over:

      prereqs      winget, PowerShell 7, the Microsoft.WinGet.Client module
      wsl-feature  Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform (elevated)
      wsl-runtime  wsl --update, WSL 2 as the default version (elevated)
      distro       download the NixOS-WSL image and wsl --import it
      source       clone the flake, or take the directory given
      resolve      name the system and home configurations to apply
      system       nix run <flake>#windowsConfigurations.<name> ... -- switch
      home         nix run <flake>#windowsHomeConfigurations."<name>" ... -- switch

    Enabling the WSL feature costs one reboot on a machine that did not have it.
    The script copies itself into its state directory and registers that copy in
    RunOnce, so the run picks itself back up at the next sign-in; -NoReboot stops
    instead and prints the command to resume with.

    Run it as yourself, unelevated. It elevates the two phases that need it, one
    UAC prompt each, and the winpkgs runtime elevates itself when it applies the
    system configuration. A home configuration must never be applied elevated.

.PARAMETER Source
    The flake: a git URL (https://, ssh://, git@host:path, or the github:owner/repo
    shorthand) to clone, or a directory on this machine that already holds one.

.PARAMETER Destination
    Where to clone a git source to. Defaults to %USERPROFILE%\git\<repository>.
    This is a Windows path -- the flake lives on the Windows side, which is what
    winpkgs.cli.flake in your home configuration wants to be set to afterwards.

.EXAMPLE
    # Everything, from a flake on GitHub.
    .\install.ps1 https://github.com/you/config

.EXAMPLE
    # A flake already on this machine, naming the configuration to apply.
    .\install.ps1 D:\src\config -System desktop

.EXAMPLE
    .\install.ps1 github:you/config -Ref develop -Destination C:\src\config

.NOTES
    The prerequisite phase repeats what runtime\bootstrap.ps1 does, because this
    script is downloaded on its own and has no repository beside it. Once the
    first apply has run, bootstrap.ps1 inside the closure covers the same ground.
#>
[CmdletBinding()]
param(
    # Git URL or existing directory. Required, except when resuming a run.
    [Parameter(Position = 0)]
    [string]$Source,

    # Windows directory to clone a git source into.
    [string]$Destination,

    # Branch or tag to clone.
    [string]$Ref,

    # Name under windowsConfigurations. Inferred when the flake has one, or one
    # named after this computer.
    [string]$System,

    # Name under windowsHomeConfigurations. Inferred as <windows user>@<system>.
    # ($Home itself is an automatic, read-only PowerShell variable.)
    [Alias('Home')]
    [string]$HomeName,

    # Stop after the system configuration; do not apply a home configuration.
    [switch]$SkipHome,

    # WSL distribution to install the flake's NixOS into. Defaults to "NixOS";
    # the default is applied after the recorded run is merged in, so that a
    # -Distro from the first run survives the reboot.
    [string]$Distro,

    # Where wsl --import puts the distro's disk. Defaults to %LOCALAPPDATA%\WSL\<Distro>.
    [string]$DistroPath,

    # NixOS-WSL image to import. By default the latest release for this machine's
    # architecture, verified against the .sha256 published beside it.
    [string]$ImageUrl,
    # An image already downloaded, instead of fetching one.
    [string]$ImageFile,

    # Reboot without asking when enabling the WSL feature calls for one.
    [switch]$Yes,
    # Never reboot: stop with the command to resume with instead.
    [switch]$NoReboot,

    # Continue a recorded run, reusing the arguments it was started with. This is
    # what the RunOnce entry passes after the reboot.
    [switch]$Resume,
    # Forget what a previous run recorded and run every phase again.
    [switch]$Reset,

    # Internal: run one phase in an elevated child and log to -LogFile.
    [ValidateSet('wsl-feature', 'wsl-runtime')]
    [string]$ElevatedPhase,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
# Every native command here answers with an exit code -- winget's "already
# installed", DISM's 3010, wsl.exe's "no such distribution" -- and a host with
# this on would raise before the code could be read.
$PSNativeCommandUseErrorActionPreference = $false
# Invoke-WebRequest's progress bar costs more than the download on 5.1.
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 defaults to SSL3/TLS1.0 on some hosts, which GitHub
# refuses. Add TLS 1.2 rather than assigning it, so a host that already offers
# 1.3 keeps it.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
}

$stateDir = Join-Path $env:LOCALAPPDATA 'winpkgs\install'
$statePath = Join-Path $stateDir 'state.json'
$scriptCopy = Join-Path $stateDir 'install.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Where output goes: the console in the ordinary run, a log the parent replays in
# an elevated child, whose window is hidden.
$script:Sink = $null

#region output

# CSI and OSC sequences: colour, and the cursor movement nix redraws progress
# with. A Windows console acts on those, so a line carrying them lands wherever
# the last one told the cursor to go rather than at the left margin. NO_COLOR
# and TERM=dumb stop most of them being written at all; this is for the rest.
# `e is PowerShell 7's escape for it and means a literal "e" under 5.1, which is
# the host this runs on.
$esc = [char]27
$bel = [char]7
$ansi = [regex]::new(
    $esc + '\[[0-9;?]*[ -/]*[@-~]' +           # CSI: colour, cursor movement, erase
    '|' + $esc + '\][^' + $bel + $esc + ']*(' + $bel + '|' + $esc + '\\)' +  # OSC: titles
    '|' + $esc + '[@-Z\\-_]')                  # the rest of the two-character ones

function Remove-Ansi {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $ansi.Replace($Text, '')
}

function Write-Info {
    # This script's own messages. Write-Host is fine for them -- they are short,
    # plain, and the colour is worth having.
    param([string]$Text, [string]$Color = 'Gray')
    $clean = Remove-Ansi $Text
    if ($script:Sink) {
        Add-Content -LiteralPath $script:Sink -Value $clean
    } else {
        Write-Host $clean -ForegroundColor $Color
    }
}

function Write-ToolLine {
    <#
    .SYNOPSIS
        A line of some other program's output.

    .DESCRIPTION
        Out-Host, never Write-Host. Under 5.1 Write-Host with -ForegroundColor
        wraps every line in a legacy console attribute call, and against the
        output of nix and the runtime that walks each line further right than
        the one before it -- measured on a clean machine, where the phases that
        went through Out-Host printed straight and the one phase still going
        through Write-Host did not. Colour is not worth that, and this output
        brings its own anyway.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $clean = Remove-Ansi $Text
    if ($script:Sink) {
        Add-Content -LiteralPath $script:Sink -Value $clean
    } else {
        $clean | Out-Host
    }
}

function Write-Phase {
    param([string]$Text)
    Write-Info ''
    Write-Info "==> $Text" 'Cyan'
}

function Write-Note {
    param([string]$Text)
    Write-Info "    $Text" 'Gray'
}

function Write-Warn {
    param([string]$Text)
    Write-Info "    warning: $Text" 'Yellow'
}

#endregion

#region running things

function Invoke-Tool {
    <#
    .SYNOPSIS
        Run a native command, route its output to the current sink, and return
        its exit code.

    .DESCRIPTION
        -Encoding is how the tool writes to the console: wsl.exe's own messages
        are UTF-16LE, anything it runs inside a distro is UTF-8, and everything
        else speaks the console default.

        Output is re-emitted line by line only when something needs doing to it
        -- an indent to nest it under its phase, or a log file to reach the
        parent of an elevated child. When neither applies it goes to the host as
        one stream, which is what cli.ps1 does and what the runtime's own output
        was written for.
    #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [ValidateSet('default', 'unicode', 'utf8')][string]$Encoding = 'default',
        [string]$Indent = '    ',
        [switch]$Silent
    )
    $eap = $ErrorActionPreference
    # Merging a native command's streams under 'Stop' turns its first line of
    # stderr into a terminating NativeCommandError. These tools' exit codes are
    # the answer, not their stderr.
    $ErrorActionPreference = 'Continue'
    $previous = $null
    try {
        if ($Encoding -ne 'default') { $previous = Set-ConsoleEncoding $Encoding }
        if ($Silent) {
            & $File @Arguments 2>&1 | Out-Null
        } elseif (-not $script:Sink -and -not $Indent) {
            # Nothing to indent and nowhere else to send it, so hand the stream
            # to the host in one piece and let it render.
            & $File @Arguments 2>&1 | ForEach-Object { Remove-Ansi "$_" } | Out-Host
        } else {
            # An ErrorRecord can carry more than one line; write them as more
            # than one, so the indent lands on each. Write-ToolLine rather than
            # Write-Info: this is somebody else's output, and it must not go
            # through Write-Host.
            & $File @Arguments 2>&1 | ForEach-Object {
                foreach ($line in ("$_" -split "`r?`n")) { Write-ToolLine ($Indent + $line) }
            }
        }
        return $LASTEXITCODE
    } finally {
        Restore-ConsoleEncoding $previous
        $ErrorActionPreference = $eap
    }
}

function Set-ConsoleEncoding {
    # Returns the encoding replaced, or $null when the host has no console to set.
    param([Parameter(Mandatory)][ValidateSet('unicode', 'utf8')][string]$Encoding)
    try {
        $previous = [Console]::OutputEncoding
        if ($Encoding -eq 'utf8') {
            [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
        } else {
            [Console]::OutputEncoding = [Text.Encoding]::Unicode
        }
        return $previous
    } catch {
        return $null
    }
}

function Restore-ConsoleEncoding {
    param($Encoding)
    if ($null -eq $Encoding) { return }
    try { [Console]::OutputEncoding = $Encoding } catch { Write-Verbose 'Could not restore the console encoding' }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Resolve-FullPath {
    # Absolute, with environment variables expanded. Anything recorded for a
    # later run has to be: RunOnce resumes from %SystemRoot%\System32, where a
    # relative path means something else entirely.
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $expanded))
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion

#region the distro

function ConvertTo-DistroPath {
    <#
    .SYNOPSIS
        The distro's path for a Windows one: /mnt/c/... for the flake, for the
        scripts below, for anything the two sides both have to name.

    .DESCRIPTION
        --exec, not `--`: without it wsl.exe hands the command to the login
        shell, which eats the backslashes of a Windows path. It only looks like
        it works when the path contains a space, because then PowerShell quotes
        the argument and sh keeps backslashes inside double quotes -- so
        C:\Users\Some One\... survives and C:\Users\me\... does not.
    #>
    param([Parameter(Mandatory)][string]$WindowsPath)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $previous = Set-ConsoleEncoding utf8
    try {
        $out = & wsl.exe -d $Distro --exec wslpath -u $WindowsPath 2>$null
        $code = $LASTEXITCODE
    } finally {
        Restore-ConsoleEncoding $previous
        $ErrorActionPreference = $eap
    }
    $path = (($out | ForEach-Object { "$_" }) -join '').Trim()
    if ($code -ne 0 -or -not $path) { throw "wslpath failed in distro '$Distro' for $WindowsPath" }
    return $path
}

function New-DistroPreamble {
    <#
    .SYNOPSIS
        The head of every script run in the distro: fail on the first error, and
        a `withgit` wrapper for the nix calls that need a git binary.

    .DESCRIPTION
        Nix reads and locks a `git+file` flake -- which is what a cloned
        configuration directory is -- by executing git, not with anything built
        in, and the NixOS-WSL image has no git at all until the first switch
        replaces it with the configuration's own distro. `withgit` supplies one
        from nixpkgs for the length of the command, and costs nothing once the
        distro has a real one.
    #>
    return @(
        'set -euo pipefail',
        '# Nothing downstream is a terminal, whatever it believes: nix colours its',
        '# output and redraws progress with cursor-movement escapes, and the pwsh',
        '# that activate execs colours its own, both because WSL interop hands them',
        '# something terminal-shaped. Replayed into a Windows console those escapes',
        '# move the cursor, and each line lands further right than the last.',
        'export NO_COLOR=1',
        'export TERM=dumb',
        'withgit() {',
        '  if command -v git >/dev/null 2>&1; then',
        '    "$@"',
        '  else',
        ('    ' + $nix + ' shell nixpkgs#git -c "$@"'),
        '  fi',
        '}'
    )
}

function New-DistroScript {
    # A bash script on disk, rather than a command line: wsl.exe's arguments pass
    # through Windows PowerShell 5.1, which drops embedded double quotes from
    # native command lines -- and the home configuration's flake attribute is
    # windowsHomeConfigurations."Some User@host", quotes and all.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $text = ((New-DistroPreamble) + $Lines) -join "`n"
    $path = Join-Path $env:TEMP ('winpkgs-install-' + [Guid]::NewGuid().ToString('N') + '.sh')
    # No BOM, and LF: bash reads this, not Windows.
    [IO.File]::WriteAllText($path, $text + "`n", (New-Object Text.UTF8Encoding $false))
    return $path
}

# Printed by the distro immediately before the output a caller wants, so that
# whatever the login shell said first -- NixOS-WSL greets every login shell until
# the system is first rebuilt -- is not mistaken for the answer.
$outputMarker = '===winpkgs-install-output==='

function Invoke-DistroScript {
    <#
    .SYNOPSIS
        Runs in the distro with its output streamed here. Returns the exit code.

    .DESCRIPTION
        `bash -l`: only a login shell sources the profile that puts
        /run/current-system/sw/bin on PATH, and nothing here can run without nix.
        Under --exec, which is what keeps the arguments intact, nothing else does
        it for us.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines, [string]$Indent = '    ')
    $win = New-DistroScript -Lines $Lines
    try {
        $linux = ConvertTo-DistroPath $win
        return (Invoke-Tool -File 'wsl.exe' -Encoding utf8 -Indent $Indent `
                -Arguments @('-d', $Distro, '--exec', 'bash', '-l', $linux))
    } finally {
        Remove-Item -LiteralPath $win -Force -ErrorAction SilentlyContinue
    }
}

function Get-DistroScriptOutput {
    # Runs in the distro and returns what it wrote to stdout. Throws on failure,
    # with what it wrote to stderr -- which is where nix puts its progress, and
    # its errors.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $win = New-DistroScript -Lines (@("echo '$outputMarker'") + $Lines)
    $errPath = Join-Path $env:TEMP ('winpkgs-install-' + [Guid]::NewGuid().ToString('N') + '.err')
    try {
        $linux = ConvertTo-DistroPath $win
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $previous = Set-ConsoleEncoding utf8
        try {
            $out = & wsl.exe -d $Distro --exec bash -l $linux 2>$errPath
            $code = $LASTEXITCODE
        } finally {
            Restore-ConsoleEncoding $previous
            $ErrorActionPreference = $eap
        }
        if ($code -ne 0) {
            $stderr = ''
            if (Test-Path -LiteralPath $errPath) { $stderr = (Get-Content -LiteralPath $errPath -Raw) }
            throw "The distro '$Distro' returned $code`:`n$stderr"
        }
        return (Select-MarkedOutput -Lines @($out | ForEach-Object { "$_" }))
    } finally {
        Remove-Item -LiteralPath $win -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }
}

function Select-MarkedOutput {
    # Everything the distro printed after the last marker line: the answer,
    # without the login shell's greeting in front of it.
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $index = [Array]::LastIndexOf($Lines, $outputMarker)
    if ($index -lt 0) { return ($Lines -join "`n") }
    if ($index -ge $Lines.Count - 1) { return '' }
    return ($Lines[($index + 1)..($Lines.Count - 1)] -join "`n")
}

function ConvertTo-ShellArgument {
    # Single-quoted for bash, so a path with a space or a URL with a query is
    # one word whatever it contains.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-WslDistribution {
    # WSL's own registry, not `wsl --list`: that writes UTF-16LE through a pipe
    # that mangles it differently on every console host, and this cannot be wrong.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $key)) { return @() }
    return @(Get-ChildItem -LiteralPath $key | ForEach-Object {
        (Get-ItemProperty -LiteralPath $_.PSPath -Name DistributionName -ErrorAction SilentlyContinue).DistributionName
    } | Where-Object { $_ })
}

# Nix has to be told to speak flakes: the NixOS-WSL image is a stock NixOS with
# neither the experimental features nor git, and stays that way until the first
# apply replaces it with the distro the configuration describes.
$nix = "nix --extra-experimental-features 'nix-command flakes'"

#endregion

#region state

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{ version = 1; completed = @(); parameters = [pscustomobject]@{} }
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    # ConvertFrom-Json gives $null for an empty JSON array on 5.1.
    if ($null -eq $state.completed) { $state.completed = @() }
    return $state
}

function Save-State {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Test-PhaseDone {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    return (@($State.completed) -contains $Name)
}

function Set-PhaseDone {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-PhaseDone -State $State -Name $Name)) {
        $State.completed = @($State.completed) + $Name
    }
    Save-State -State $State
}

function Set-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name, $Value)
    if ($State.parameters.PSObject.Properties.Name -contains $Name) {
        $State.parameters.$Name = $Value
    } else {
        $State.parameters | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    Save-State -State $State
}

function Get-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    if ($State.parameters.PSObject.Properties.Name -contains $Name) { return $State.parameters.$Name }
    return $null
}

function Restore-RecordedArguments {
    <#
    .SYNOPSIS
        Merge what this run was given with what an earlier one recorded.

    .DESCRIPTION
        An argument passed now wins, and is recorded for whatever run comes
        after the reboot; one left out is taken from the record. So -Resume needs
        no arguments at all, and re-running by hand needs only the ones that
        changed. $Given holds only the arguments actually passed -- a parameter
        left at its default is not one of them.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][hashtable]$Given,
        [Parameter(Mandatory)][string[]]$Names
    )
    $merged = @{}
    foreach ($name in $Names) {
        if ($Given.ContainsKey($name)) {
            $value = $Given[$name]
            # A switch does not survive a round trip through JSON; a bool does.
            if ($value -is [switch]) { $value = [bool]$value }
            Set-StateValue -State $State -Name $name -Value $value
            $merged[$name] = $value
        } else {
            $merged[$name] = Get-StateValue -State $State -Name $name
        }
    }
    return $merged
}

#endregion

#region elevation and the reboot

function Invoke-ElevatedPhase {
    <#
    .SYNOPSIS
        Run one phase in an elevated child of this same script. One UAC prompt.
        Returns the child's exit code; 3010 means the machine wants a reboot.
    #>
    param([Parameter(Mandatory)][string]$Phase)

    $log = Join-Path $stateDir "$Phase.log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    # One pre-quoted string, not an array: Start-Process on 5.1 joins an
    # -ArgumentList with spaces and quotes nothing, and this path lives under a
    # user profile that may well have a space in it.
    $line = '-NoProfile -NoLogo -ExecutionPolicy Bypass -File "{0}" -ElevatedPhase {1} -LogFile "{2}"' -f
        $scriptCopy, $Phase, $log
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = $windowsPowerShell }

    Write-Note 'elevating (UAC prompt)...'
    try {
        $proc = Start-Process -FilePath $exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $line
    } catch {
        throw "Elevation was refused or failed: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log | ForEach-Object { Write-ToolLine $_ }
    }
    return $proc.ExitCode
}

function Register-Resume {
    <#
    .SYNOPSIS
        Have the next sign-in continue this run.

    .DESCRIPTION
        RunOnce, under HKCU: it runs as this user, unelevated, which is what the
        remaining phases want -- the home configuration must not be applied
        elevated. Windows removes the entry as it runs it. -NoExit so a failure
        stays on screen instead of closing with the window.
    #>
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $command = '"{0}" -NoProfile -NoLogo -NoExit -ExecutionPolicy Bypass -File "{1}" -Resume' -f
        $windowsPowerShell, $scriptCopy
    New-ItemProperty -Path $key -Name 'winpkgs-install' -Value $command -PropertyType String -Force | Out-Null
}

function Request-Reboot {
    <#
    .SYNOPSIS
        Reboot and continue afterwards, or explain how to. Returns $false when
        the caller should stop without rebooting.
    #>
    if ($NoReboot) {
        Write-Info ''
        Write-Info 'The WSL feature needs a reboot before the rest can run.' 'Yellow'
        Write-Note 'Reboot, then continue with:'
        Write-Note ("    powershell -ExecutionPolicy Bypass -File `"$scriptCopy`" -Resume")
        return $false
    }

    Register-Resume
    if (-not $Yes) {
        Write-Info ''
        Write-Info 'The WSL feature needs a reboot before the rest can run.' 'Yellow'
        Write-Note 'The run continues automatically at the next sign-in.'
        $answer = Read-Host '    Reboot now? [Y/n]'
        if ($answer -and $answer.Trim() -notmatch '^(y|yes)$') {
            Write-Note 'Not rebooting. Reboot when you are ready and the run continues on its own,'
            Write-Note ("or run:  powershell -ExecutionPolicy Bypass -File `"$scriptCopy`" -Resume")
            return $false
        }
    }
    Write-Info ''
    Write-Info 'Rebooting. Sign back in and the run continues.' 'Cyan'
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    return $true
}

#endregion

#region phases

function Invoke-PrereqPhase {
    if (-not (Test-CommandAvailable winget)) {
        throw "winget is not available. Install 'App Installer' from the Microsoft Store (or let Windows Update finish), then re-run."
    }

    if (Test-CommandAvailable pwsh) {
        Write-Note 'PowerShell 7 is installed'
    } else {
        Write-Note 'installing PowerShell 7'
        $code = Invoke-Tool -File 'winget' -Arguments @(
            'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        # 0x8A15002B: already installed, no applicable upgrade.
        if ($code -ne 0 -and $code -ne -1978335189) {
            throw "winget install Microsoft.PowerShell failed with exit code $code"
        }
        Update-SessionPath
        if (-not (Test-CommandAvailable pwsh)) {
            throw 'PowerShell 7 was installed but is not on PATH yet. Open a new terminal and re-run this script.'
        }
    }

    Install-WinGetClientModule
}

function Install-WinGetClientModule {
    <#
    .SYNOPSIS
        Put Microsoft.WinGet.Client where both PowerShells will find it, without
        running either of them.

    .DESCRIPTION
        The runtime drives winget through this module under whichever host runs
        the phase: PowerShell 7 applies a home configuration, and the elevated
        machine phase runs under Windows PowerShell when pwsh is the MSIX build.
        The two hosts keep user modules in different directories, so both need it.

        Not by invoking pwsh, which is the obvious way and does not work here.
        From 7.6 winget installs the MSIX build, so on a machine that has just
        followed the phase above, `pwsh` on PATH is a zero-byte App Execution
        Alias: it hands off to the packaged app, so a pipeline reading its output
        never sees the handle close, and Start-Process hands back a stub whose
        exit code is empty. It hung this script once and then reported "(exit )".

        Saving the module into a host's user module directory is all installing
        it there amounts to -- both directories are on their host's default
        PSModulePath -- and Save-Module does it from here, in process, with no
        alias in the way. GetFolderPath rather than $env:USERPROFILE\Documents,
        because Documents is redirected on plenty of machines.
    #>
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $targets = [ordered]@{
        'Windows PowerShell' = Join-Path $documents 'WindowsPowerShell\Modules'
        'PowerShell 7'       = Join-Path $documents 'PowerShell\Modules'
    }
    $missing = @($targets.Keys | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $targets[$_] 'Microsoft.WinGet.Client'))
    })
    if ($missing.Count -eq 0) {
        Write-Note 'Microsoft.WinGet.Client is already there for both hosts'
        return
    }

    # Installed unconditionally rather than asked about first: asking is the bug.
    # Get-PackageProvider for a provider that is not there offers to fetch it,
    # and that offer is a ShouldContinue prompt, which -ErrorAction cannot
    # silence -- so on a machine with nobody at the console it is a wait with no
    # end. Install-PackageProvider -Force does the same work and cannot ask.
    Write-Note 'ensuring the NuGet package provider'
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser `
                                -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        Write-Warn "NuGet provider: $($_.Exception.Message)"
    }

    # And trust the gallery for the length of this, so the other prompt -- "you
    # are installing from an untrusted repository" -- has nothing to ask either.
    $restorePolicy = $null
    try {
        $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($repository.InstallationPolicy -ne 'Trusted') {
            $restorePolicy = $repository.InstallationPolicy
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Write-Note 'trusting PSGallery for the duration'
        }
    } catch {
        Write-Warn "PSGallery: $($_.Exception.Message)"
    }

    try {
        foreach ($host_ in $missing) {
            $dir = $targets[$host_]
            Write-Note "installing Microsoft.WinGet.Client for $host_"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Save-Module -Name Microsoft.WinGet.Client -Path $dir -Force -Repository PSGallery -Confirm:$false
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'Microsoft.WinGet.Client'))) {
                throw "Microsoft.WinGet.Client did not appear under $dir"
            }
        }
    } finally {
        if ($restorePolicy) {
            Set-PSRepository -Name PSGallery -InstallationPolicy $restorePolicy
        }
    }
}

function Test-WindowsFeatureEnabled {
    # Win32_OptionalFeature answers this without elevation, where
    # Get-WindowsOptionalFeature and `dism /get-featureinfo` both need it.
    param([Parameter(Mandatory)][string]$Name)
    $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    return ($null -ne $feature -and $feature.InstallState -eq 1)
}

$wslFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')

function Invoke-WslFeaturePhase {
    $missing = @($wslFeatures | Where-Object { -not (Test-WindowsFeatureEnabled $_) })
    if ($missing.Count -eq 0) {
        Write-Note 'the WSL and Virtual Machine Platform features are already enabled'
        return $false
    }
    Write-Note ("enabling: " + ($missing -join ', '))
    $code = Invoke-ElevatedPhase -Phase 'wsl-feature'
    if ($code -eq 3010) {
        return $true
    }
    if ($code -ne 0) { throw "Enabling the WSL features failed with exit code $code" }
    return $false
}

function Invoke-WslFeatureElevated {
    # DISM rather than `wsl --install`: it is on every Windows that has the
    # features at all, and it says whether a reboot is due -- 3010 -- instead of
    # leaving it to be discovered.
    $reboot = $false
    foreach ($feature in $wslFeatures) {
        if (Test-WindowsFeatureEnabled $feature) {
            Write-Note "$feature is already enabled"
            continue
        }
        Write-Note "enabling $feature"
        $code = Invoke-Tool -File (Join-Path $env:SystemRoot 'System32\dism.exe') -Arguments @(
            '/online', '/enable-feature', "/featurename:$feature", '/all', '/norestart', '/quiet')
        if ($code -eq 3010) {
            $reboot = $true
        } elseif ($code -ne 0) {
            throw "dism /enable-feature:$feature failed with exit code $code"
        }
    }
    if ($reboot) { return 3010 }
    return 0
}

function Test-WslRuntimeReady {
    # wsl.exe is absent entirely until the optional component is installed, and a
    # command that does not exist leaves $LASTEXITCODE from whatever ran before.
    if (-not (Test-CommandAvailable wsl.exe)) { return $false }
    $code = Invoke-Tool -File 'wsl.exe' -Arguments @('--version') -Encoding unicode -Silent
    return ($code -eq 0)
}

function Invoke-WslRuntimePhase {
    if (Test-WslRuntimeReady) {
        Write-Note 'the WSL runtime is installed'
        return
    }
    Write-Note 'installing the WSL runtime (wsl --update)'
    $code = Invoke-ElevatedPhase -Phase 'wsl-runtime'
    if ($code -ne 0) { throw "Installing the WSL runtime failed with exit code $code" }
    if (-not (Test-WslRuntimeReady)) {
        throw 'wsl --update ran but `wsl --version` still fails. Install "Windows Subsystem for Linux" from the Microsoft Store and re-run.'
    }
}

function Invoke-WslRuntimeElevated {
    $code = Invoke-Tool -File 'wsl.exe' -Arguments @('--update') -Encoding unicode
    if ($code -ne 0) {
        Write-Warn "wsl --update returned $code"
    }
    $code = Invoke-Tool -File 'wsl.exe' -Arguments @('--set-default-version', '2') -Encoding unicode
    if ($code -ne 0) { Write-Warn "wsl --set-default-version 2 returned $code" }
    # Neither is fatal on its own; the caller checks `wsl --version` afterwards.
    return 0
}

function Get-DefaultImageUrl {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if (-not $arch) { $arch = 'AMD64' }
    $asset = 'nixos.wsl'
    if ($arch -eq 'ARM64') { $asset = 'nixos.aarch64.wsl' }
    return "https://github.com/nix-community/NixOS-WSL/releases/latest/download/$asset"
}

function ConvertFrom-ChecksumText {
    # A .sha256 file is either the bare digest or "<digest>  <filename>", and
    # either may carry a trailing newline.
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    $trimmed = $Text.Trim()
    if (-not $trimmed) { return $null }
    return ($trimmed -split '\s+')[0]
}

function Get-NixOSImage {
    # Returns the image on disk, and whether this run downloaded it.
    if ($ImageFile) {
        if (-not (Test-Path -LiteralPath $ImageFile)) { throw "No such image: $ImageFile" }
        return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $ImageFile).ProviderPath; Downloaded = $false }
    }

    $url = $ImageUrl
    if (-not $url) { $url = Get-DefaultImageUrl }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $path = Join-Path $stateDir ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))

    Write-Note "downloading $url"
    Write-Note 'about half a gigabyte; a few minutes on a normal connection'
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing

    # The checksum GitHub publishes beside the image. A release that has none is
    # a warning, not a failure: -ImageUrl can name anything.
    # To a file rather than through .Content: PowerShell 7 hands back a byte[]
    # for anything not served as text, and GitHub serves release assets as
    # application/octet-stream, so [string] on it renders decimal byte values.
    $expected = $null
    $sumPath = "$path.sha256"
    try {
        Invoke-WebRequest -Uri "$url.sha256" -OutFile $sumPath -UseBasicParsing
        $expected = ConvertFrom-ChecksumText (Get-Content -LiteralPath $sumPath -Raw)
    } catch {
        Write-Warn "no checksum published beside the image ($($_.Exception.Message)); not verifying"
    } finally {
        Remove-Item -LiteralPath $sumPath -Force -ErrorAction SilentlyContinue
    }
    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $expected.ToUpperInvariant()) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            throw "The downloaded image does not match its published SHA256 ($actual, expected $expected)"
        }
        Write-Note 'checksum verified'
    }
    return [pscustomobject]@{ Path = $path; Downloaded = $true }
}

function Invoke-DistroPhase {
    if ((Get-WslDistribution) -contains $Distro) {
        Write-Note "the distro '$Distro' is already registered"
    } else {
        $target = $DistroPath
        if (-not $target) { $target = Join-Path $env:LOCALAPPDATA "WSL\$Distro" }
        New-Item -ItemType Directory -Force -Path $target | Out-Null

        $image = Get-NixOSImage
        Write-Note "importing '$Distro' into $target"
        $code = Invoke-Tool -File 'wsl.exe' -Encoding unicode `
            -Arguments @('--import', $Distro, $target, $image.Path, '--version', '2')
        if ($code -ne 0) { throw "wsl --import failed with exit code $code" }
        if ($image.Downloaded) { Remove-Item -LiteralPath $image.Path -Force -ErrorAction SilentlyContinue }
    }

    # First boot, and a look at who we are in there. NixOS-WSL's image carries
    # /etc/wsl.conf naming its own default user; if that did not take, everything
    # after this runs as root, which works but is not what the machine will look
    # like once the configuration owns the distro.
    $whoami = (Get-DistroScriptOutput -Lines @('whoami')).Trim()
    Write-Note "the distro answers as '$whoami'"
    if ($whoami -eq 'root') {
        Write-Warn "'$Distro' has no default user; the flake will be cloned and built as root"
    }
}

function Test-GitSource {
    param([Parameter(Mandatory)][string]$Value)
    # A scheme with an authority (https://, ssh://, git://), scp-style
    # user@host:path, a bare .git, or nix's flake shorthands -- but not C:\src,
    # which a looser scheme test would swallow.
    return ($Value -match '^[a-z][a-z0-9+.-]*://' -or
            $Value -match '^[^\\/:]+@[^\\/:]+:' -or
            $Value -match '^(github|gitlab):' -or
            $Value -match '\.git/?$')
}

function ConvertTo-CloneUrl {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '^github:(.+)$') { return "https://github.com/$($Matches[1])" }
    if ($Value -match '^gitlab:(.+)$') { return "https://gitlab.com/$($Matches[1])" }
    return $Value
}

function Get-RepositoryName {
    param([Parameter(Mandatory)][string]$Url)
    $name = ($Url -replace '/+$', '') -replace '\.git$', ''
    $name = $name -replace '^.*[/:]', ''
    if (-not $name) { throw "Could not work out a directory name from $Url; pass -Destination" }
    return $name
}

function New-CloneScript {
    <#
    .SYNOPSIS
        The clone, as it runs inside the distro.

    .DESCRIPTION
        Every line is parenthesised. PowerShell's comma binds tighter than its
        plus, so `'a=' + $x, 'b=' + $y` is `'a=' + ($x, 'b=') + $y` -- one string
        where seven lines were meant, and a shell script that is one long line is
        a syntax error rather than a wrong answer.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        # Where to put it, as the distro names it.
        [Parameter(Mandatory)][string]$Destination,
        [string]$Ref
    )
    $branch = ''
    if ($Ref) { $branch = '--branch ' + (ConvertTo-ShellArgument $Ref) + ' ' }
    return @(
        ('url=' + (ConvertTo-ShellArgument $Url)),
        ('dest=' + (ConvertTo-ShellArgument $Destination)),
        'if command -v git >/dev/null 2>&1; then',
        ('  git clone --recurse-submodules ' + $branch + '"$url" "$dest"'),
        'else',
        ('  ' + $nix + ' run nixpkgs#git -- clone --recurse-submodules ' + $branch + '"$url" "$dest"'),
        'fi'
    )
}

function Invoke-SourcePhase {
    param([Parameter(Mandatory)]$State)

    # A directory that is really there wins over the shape of the string, so a
    # checkout named config.git is not mistaken for a URL.
    if (Test-Path -LiteralPath $Source -PathType Container) {
        $dir = (Resolve-Path -LiteralPath $Source).ProviderPath
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'flake.nix'))) {
            throw "$dir has no flake.nix"
        }
        Write-Note "using the flake at $dir"
        Set-StateValue -State $State -Name 'flake' -Value $dir
        return
    }
    if (-not (Test-GitSource $Source)) {
        throw "No such directory: $Source (and it does not look like a git URL)"
    }

    $url = ConvertTo-CloneUrl $Source
    $dir = $Destination
    if (-not $dir) { $dir = Join-Path $env:USERPROFILE ('git\' + (Get-RepositoryName $url)) }
    $dir = [Environment]::ExpandEnvironmentVariables($dir)

    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        Write-Note "a clone is already at $dir; leaving it alone"
    } else {
        if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) {
            throw "$dir exists and is not empty, but is not a git clone. Pass -Destination, or move it aside."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null

        # Cloned from inside the distro rather than with a Windows git, so
        # nothing has to be installed on Windows that the configuration has not
        # asked for. The image has no git either, hence `nix run nixpkgs#git`.
        $linuxDir = ConvertTo-DistroPath (Split-Path -Parent $dir)
        $linuxDir = $linuxDir.TrimEnd('/') + '/' + (Split-Path -Leaf $dir)

        Write-Note "cloning $url into $dir"
        Write-Note 'the first `nix run` fetches nixpkgs, which takes a few minutes'
        $code = Invoke-DistroScript -Lines (New-CloneScript -Url $url -Destination $linuxDir -Ref $Ref)
        if ($code -ne 0) { throw "Cloning $url failed with exit code $code" }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $dir 'flake.nix'))) {
        throw "$dir has no flake.nix"
    }
    Set-StateValue -State $State -Name 'flake' -Value $dir
}

function Get-ConfigurationNames {
    # attrNames, not the configurations: nix never forces a value it is only
    # being asked the name of, so this costs one evaluation of the flake outputs.
    param([Parameter(Mandatory)][string]$LinuxFlake, [Parameter(Mandatory)][string]$Output)
    $json = Get-DistroScriptOutput -Lines @(
        "cd $(ConvertTo-ShellArgument $LinuxFlake)",
        "withgit $nix eval --json '.#$Output' --apply builtins.attrNames")
    if (-not $json) { return @() }
    return @($json | ConvertFrom-Json)
}

function Resolve-ConfigurationName {
    <#
    .SYNOPSIS
        Which of a flake's configurations this machine's is. Errors name the
        alternatives rather than the absence.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [string]$Requested,
        [string]$Preferred
    )
    if ($Requested) {
        if ($Names -notcontains $Requested) {
            throw "This flake has no $Kind named '$Requested'. It has: $($Names -join ', ')"
        }
        return $Requested
    }
    if ($Names.Count -eq 0) { return $null }
    if ($Preferred) {
        $match = $Names | Where-Object { $_ -eq $Preferred }
        if ($match) { return @($match)[0] }
    }
    if ($Names.Count -eq 1) { return $Names[0] }
    throw ("This flake has several ${Kind}s and none is named '$Preferred': $($Names -join ', ')")
}

function Invoke-ResolvePhase {
    param([Parameter(Mandatory)]$State)

    $flake = Get-StateValue -State $State -Name 'flake'
    $linux = ConvertTo-DistroPath $flake
    Set-StateValue -State $State -Name 'linuxFlake' -Value $linux
    Write-Note "evaluating $flake"

    $systems = Get-ConfigurationNames -LinuxFlake $linux -Output 'windowsConfigurations'
    $name = Resolve-ConfigurationName -Kind 'windowsConfiguration' -Names $systems `
        -Requested $System -Preferred $env:COMPUTERNAME
    if (-not $name) { throw 'This flake has no windowsConfigurations' }
    Write-Note "system: $name"
    Set-StateValue -State $State -Name 'system' -Value $name

    if ($SkipHome) {
        Set-StateValue -State $State -Name 'home' -Value $null
        return
    }
    # A flake with no windowsHomeConfigurations at all is a system-only machine,
    # not an error. ($Home is an automatic, read-only PowerShell variable, hence
    # the name here.)
    $homes = @()
    try {
        $homes = Get-ConfigurationNames -LinuxFlake $linux -Output 'windowsHomeConfigurations'
    } catch {
        Write-Note 'this flake has no windowsHomeConfigurations'
    }
    $homeConfig = Resolve-ConfigurationName -Kind 'windowsHomeConfiguration' -Names $homes `
        -Requested $HomeName -Preferred "$env:USERNAME@$name"
    if ($homeConfig) {
        Write-Note "home:   $homeConfig"
    } else {
        Write-Note 'home:   none to apply'
    }
    Set-StateValue -State $State -Name 'home' -Value $homeConfig
}

function Invoke-ApplyPhase {
    <#
    .SYNOPSIS
        The first activation, from inside the distro: exactly what the README's
        "The first time, from WSL" tells you to run by hand.

    .DESCRIPTION
        The flake is addressed as a bare directory, the way the winpkgs command
        addresses it afterwards, so this run and every later one see the same
        flake -- a dirty working tree included.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind)

    $linux = Get-StateValue -State $State -Name 'linuxFlake'
    if ($Kind -eq 'system') {
        $name = Get-StateValue -State $State -Name 'system'
        $attr = "windowsConfigurations.$name"
    } else {
        $name = Get-StateValue -State $State -Name 'home'
        if (-not $name) {
            Write-Note 'no home configuration to apply'
            return
        }
        $attr = "windowsHomeConfigurations.`"$name`""
    }

    Write-Note "applying $attr"
    if ($Kind -eq 'system') {
        Write-Note 'the WSL distro is activated first, then Windows, which prompts for UAC'
    }
    $target = "$linux#$attr.config.system.build.toplevel"
    $code = Invoke-DistroScript -Indent '' -Lines @(
        "cd $(ConvertTo-ShellArgument $linux)",
        "withgit $nix run $(ConvertTo-ShellArgument $target) -- switch")
    if ($code -ne 0) { throw "Applying the $Kind configuration failed with exit code $code" }
}

#endregion

#region the elevated child

if ($ElevatedPhase) {
    $script:Sink = $LogFile
    if ($LogFile) { New-Item -ItemType File -Force -Path $LogFile | Out-Null }
    try {
        switch ($ElevatedPhase) {
            'wsl-feature' { exit (Invoke-WslFeatureElevated) }
            'wsl-runtime' { exit (Invoke-WslRuntimeElevated) }
        }
    } catch {
        Write-Info "    error: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

#endregion

#region the run

trap {
    Write-Host ''
    Write-Host "install: $($_.Exception.Message)" -ForegroundColor Red
    # Only worth saying once there is progress to lose: a usage error on the
    # first run has nothing to continue from.
    try {
        if ((Test-Path -LiteralPath $statePath) -and @((Read-State).completed).Count -gt 0) {
            Write-Host 'install: the phases that finished are recorded; re-run to continue from here.' -ForegroundColor Red
        }
    } catch {
        Write-Verbose 'No recorded run to report'
    }
    exit 1
}

if (-not $PSCommandPath) {
    throw 'Run this script from a file (irm ... -OutFile install.ps1; .\install.ps1 <source>): it copies itself aside so it can elevate and resume across a reboot.'
}

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
if ($Reset) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
if ($Resume -and -not (Test-Path -LiteralPath $statePath)) {
    throw "Nothing to resume: no run recorded in $stateDir. Start one by passing your flake."
}
$state = Read-State

# Every path is made absolute before it is recorded, because the run that reads
# it back has a different working directory.
if ($Source -and ((Test-Path -LiteralPath $Source) -or -not (Test-GitSource $Source))) {
    $Source = Resolve-FullPath $Source
}
foreach ($name in @('Destination', 'DistroPath', 'ImageFile')) {
    $given = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
    if ($given) { Set-Variable -Name $name -Value (Resolve-FullPath $given) }
}

$remembered = @('Source', 'Destination', 'Ref', 'System', 'HomeName',
                'Distro', 'DistroPath', 'ImageUrl', 'ImageFile', 'SkipHome')
$given = @{}
foreach ($name in $remembered) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $given[$name] = Get-Variable -Name $name -ValueOnly
    }
}
$merged = Restore-RecordedArguments -State $state -Given $given -Names $remembered
foreach ($name in $remembered) {
    $value = $merged[$name]
    if ($name -eq 'SkipHome') { $value = [switch][bool]$value }
    Set-Variable -Name $name -Value $value
}

if (-not $Source) {
    throw 'Nothing to install. Pass a git URL or a directory holding your flake, or -Resume a recorded run.'
}
if (-not $Distro) { $Distro = 'NixOS' }

if (Test-Elevated) {
    Write-Host ''
    Write-Host 'install: warning: this session is elevated.' -ForegroundColor Yellow
    Write-Host '         The script elevates the phases that need it on its own, and a home' -ForegroundColor Yellow
    Write-Host '         configuration is meant to be applied as an ordinary user. Continuing.' -ForegroundColor Yellow
}

# Elevating and resuming both re-run this file, so it has to outlive wherever it
# was downloaded to.
if ($PSCommandPath -ne $scriptCopy) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force
}

$transcript = Join-Path $stateDir 'install.log'
try { Start-Transcript -LiteralPath $transcript -Append | Out-Null } catch { Write-Verbose 'No transcript' }

Write-Host ''
Write-Host "install: winpkgs, from $Source" -ForegroundColor White

$phases = @(
    @{ Name = 'prereqs';     Label = 'prerequisites';                Action = { Invoke-PrereqPhase } },
    @{ Name = 'wsl-feature'; Label = 'the WSL Windows features';     Action = { if (Invoke-WslFeaturePhase) { $script:RebootRequired = $true } } },
    @{ Name = 'wsl-runtime'; Label = 'the WSL runtime';              Action = { Invoke-WslRuntimePhase } },
    @{ Name = 'distro';      Label = "the NixOS-WSL distro '$Distro'"; Action = { Invoke-DistroPhase } },
    @{ Name = 'source';      Label = 'the flake';                    Action = { Invoke-SourcePhase -State $state } },
    @{ Name = 'resolve';     Label = 'the configurations to apply';  Action = { Invoke-ResolvePhase -State $state } },
    @{ Name = 'system';      Label = 'the system configuration';     Action = { Invoke-ApplyPhase -State $state -Kind system } },
    @{ Name = 'home';        Label = 'the home configuration';       Action = { Invoke-ApplyPhase -State $state -Kind home } }
)

$script:RebootRequired = $false
$index = 0
$stopped = $false
foreach ($phase in $phases) {
    $index++
    if (Test-PhaseDone -State $state -Name $phase.Name) {
        Write-Phase ("[{0}/{1}] {2} -- already done" -f $index, $phases.Count, $phase.Label)
        continue
    }
    Write-Phase ("[{0}/{1}] {2}" -f $index, $phases.Count, $phase.Label)
    & $phase.Action
    Set-PhaseDone -State $state -Name $phase.Name
    if ($script:RebootRequired) {
        $stopped = $true
        break
    }
}

if ($stopped) {
    Request-Reboot | Out-Null
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }
    exit 0
}

$flake = Get-StateValue -State $state -Name 'flake'
Write-Host ''
Write-Host 'install: done.' -ForegroundColor Green
Write-Note "flake:  $flake"
Write-Note "distro: $Distro  (winpkgs shell, or wsl -d $Distro)"
Write-Info ''
Write-Note 'Open a new terminal, then:'
Write-Note '    winpkgs system plan'
Write-Note '    winpkgs home switch'
Write-Info ''
Write-Note 'If `winpkgs` is not found, the home configuration did not set winpkgs.cli.flake.'
Write-Note "Set it to '$flake' and apply the home configuration again."
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }

#endregion
