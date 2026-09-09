#Requires -Version 5.1
<#
.SYNOPSIS
    The unattended half of an installation: what FirstLogonCommands runs.

.DESCRIPTION
    `install.ps1` starts from a flake and has to build it, which is why it needs
    WSL, Nix and a network. This starts from a closure that is already built and
    sitting on the boot media beside it, so it needs none of them: the runtime is
    5.1-compatible by construction, and applying a document is pure Windows.

    Five phases, recorded under %LOCALAPPDATA%\winpkgs\setup so the run continues
    where it stopped:

      payload   copy the media's payload to disk, so it can outlive the media
      wsl       import the distro and put the configuration's system in it
      system    apply the system document                        (elevated)
      home      apply the home document                          (never elevated)
      finalize  destroy the setup credential and stop logging on automatically

    Elevation is not managed here, it is inherited. FirstLogonCommands runs with
    the auto-logged-on administrator's full token, so `payload`, `wsl` and
    `system` are already elevated and nothing has to prompt. Between `system` and
    `home` the run always reboots -- whether or not the apply asked for it -- and
    comes back through HKCU RunOnce, which runs at medium integrity. That reboot
    is the privilege boundary: it is what makes the home configuration apply as
    the user rather than as an administrator, which it must.

    The WSL features are already enabled: the answer file turns them on in its
    servicing section while the image is still offline, before this ever runs.

.PARAMETER PayloadRoot
    Where the payload is. Defaults to the directory holding this script, which is
    the media on the first run and the copy on disk afterwards.

.PARAMETER Resume
    Continue a recorded run. What the RunOnce entry passes after the reboot.

.NOTES
    Windows PowerShell 5.1: it is all a machine at first logon has, and the whole
    point is to need nothing that is not already there.
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot,
    [switch]$Resume,
    [switch]$Reset,
    # Never reboot; stop with the command to resume with instead. For working on
    # the payload without losing the machine.
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
# Every native command here answers with an exit code; a host with this on would
# raise before the code could be read.
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'

$stateDir = Join-Path $env:LOCALAPPDATA 'winpkgs\setup'
$statePath = Join-Path $stateDir 'state.json'
$scriptCopy = Join-Path $stateDir 'setup.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# "Done, and the machine has to restart before you believe it." What DISM says
# after enabling a feature and what `winpkgs apply` says for a setting nothing
# short of a restart completes. Read, but not obeyed: this run reboots between
# the system and home applies either way, because the reboot is also how it
# stops being elevated.
$exitRebootRequired = 3010

#region output

function Write-Note {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Gray
}

function Write-Phase {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

#endregion

#region state

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return @{ completed = @() } }
    $raw = Get-Content -LiteralPath $statePath -Raw
    if (-not $raw.Trim()) { return @{ completed = @() } }
    $o = $raw | ConvertFrom-Json
    $state = @{ completed = @() }
    foreach ($p in $o.PSObject.Properties) { $state[$p.Name] = $p.Value }
    if (-not $state.completed) { $state.completed = @() }
    return $state
}

function Write-State {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Test-PhaseDone {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    return (@($State.completed) -contains $Name)
}

function Set-PhaseDone {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-PhaseDone -State $State -Name $Name)) {
        $State.completed = @(@($State.completed) + $Name)
    }
    Write-State -State $State
}

function Set-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name, $Value)
    $State[$Name] = $Value
    Write-State -State $State
}

function Get-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    if ($State.ContainsKey($Name)) { return $State[$Name] }
    return $null
}

#endregion

#region running things

function Invoke-Tool {
    <#
    .SYNOPSIS
        Run a program with its output passed through as it was written, and
        return its exit code.

    .DESCRIPTION
        Never Write-Host: under 5.1 its -ForegroundColor wraps every line in a
        legacy console attribute call, which walks another program's output
        rightwards a line at a time.
    #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [ValidateSet('utf8', 'unicode', 'default')][string]$Encoding = 'default'
    )
    $previous = [Console]::OutputEncoding
    try {
        if ($Encoding -eq 'utf8') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
        elseif ($Encoding -eq 'unicode') { [Console]::OutputEncoding = [Text.UnicodeEncoding]::new($false, $false) }
        & $File @Arguments 2>&1 | ForEach-Object { Out-Host -InputObject "$_" }
        return $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $previous
    }
}

function ConvertTo-DistroPath {
    # A Windows path as the distro sees it. --exec, because a login shell eats
    # the backslashes of a Windows path unless it happens to contain a space.
    param([Parameter(Mandatory)][string]$Path)
    $out = & wsl.exe -d $script:Distro --exec wslpath -a -u $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wslpath failed for '$Path': $out" }
    return ("$out").Trim()
}

#endregion

#region phases

function Invoke-PayloadPhase {
    <#
    .SYNOPSIS
        Put the payload somewhere that outlives the media.

    .DESCRIPTION
        The run reboots before it is finished, and what it comes back to must not
        depend on a DVD still being attached or a USB stick still being in. The
        copy is also what the RunOnce entry points at.
    #>
    param([Parameter(Mandatory)]$State)

    $target = Join-Path $stateDir 'payload'
    if ((Get-StateValue -State $State -Name 'payload') -and (Test-Path -LiteralPath $target)) {
        Write-Note 'the payload is already on disk'
        return
    }
    Write-Note "copying the payload to $target"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $script:SourceRoot '*') -Destination $target -Recurse -Force
    Set-StateValue -State $State -Name 'payload' -Value $target
    Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force
}

function Invoke-WslPhase {
    <#
    .SYNOPSIS
        The distro, and the configuration's own system inside it.

    .DESCRIPTION
        The stock NixOS-WSL rootfs is imported first because a distro has to
        exist before anything can be put in it. The configuration's WSL system is
        then loaded from a store archive on the payload -- no evaluation, no
        network, no flake -- and activated exactly the way `activate.sh` does it
        when the flake is present: set the system profile, then
        switch-to-configuration.
    #>
    param([Parameter(Mandatory)]$State)

    $payload = Get-StateValue -State $State -Name 'payload'
    $wsl = Join-Path $payload 'wsl'
    $rootfs = Join-Path $wsl 'nixos.wsl'
    $archive = Join-Path $wsl 'system.tar.gz'
    $toplevelFile = Join-Path $wsl 'toplevel'

    if (-not (Test-Path -LiteralPath $rootfs)) {
        throw "The payload has no distro image at $rootfs"
    }

    $existing = & wsl.exe --list --quiet 2>$null
    if (("$existing" -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $script:Distro) {
        Write-Note "the distro '$($script:Distro)' is already imported"
    } else {
        # Tolerated, not required: a machine with no network cannot fetch the
        # WSL update, and an inbox WSL 2 does not need it.
        Write-Note 'updating the WSL runtime'
        $code = Invoke-Tool -File 'wsl.exe' -Arguments @('--update') -Encoding unicode
        if ($code -ne 0) { Write-Note "  wsl --update answered $code; continuing with the inbox runtime" }
        $null = Invoke-Tool -File 'wsl.exe' -Arguments @('--set-default-version', '2') -Encoding unicode

        $distroPath = Join-Path $env:LOCALAPPDATA "WSL\$($script:Distro)"
        New-Item -ItemType Directory -Force -Path $distroPath | Out-Null
        Write-Note "importing $rootfs as '$($script:Distro)'"
        $code = Invoke-Tool -File 'wsl.exe' -Encoding unicode -Arguments @(
            '--import', $script:Distro, $distroPath, $rootfs, '--version', '2')
        if ($code -ne 0) { throw "wsl --import failed with exit code $code" }
    }

    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Note 'no WSL system on the payload; leaving the stock distro as it is'
        return
    }

    $toplevel = (Get-Content -LiteralPath $toplevelFile -Raw).Trim()
    Write-Note "activating $toplevel in the distro"
    $script = @(
        'set -euo pipefail',
        # Plain gzip: the stock image is minimal and this must not depend on a
        # decompressor that may not be in it.
        ("tar -xzf " + (ConvertTo-DistroPath $archive) + " -C /"),
        'if [ -f /nix/.registration ]; then nix-store --load-db < /nix/.registration; rm -f /nix/.registration; fi',
        ("nix-env -p /nix/var/nix/profiles/system --set " + $toplevel),
        ($toplevel + '/bin/switch-to-configuration boot')
    ) -join "`n"

    $scriptPath = Join-Path $env:TEMP ('winpkgs-setup-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($scriptPath, $script + "`n", (New-Object Text.UTF8Encoding $false))
    try {
        $code = Invoke-Tool -File 'wsl.exe' -Encoding utf8 -Arguments @(
            '-d', $script:Distro, '-u', 'root', '--exec', 'bash', (ConvertTo-DistroPath $scriptPath))
        if ($code -ne 0) { throw "Activating the WSL system failed with exit code $code" }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    # The distro has to come back for the new system to be the one running.
    $null = Invoke-Tool -File 'wsl.exe' -Arguments @('--terminate', $script:Distro) -Encoding unicode
}

function Invoke-DocumentPhase {
    <#
    .SYNOPSIS
        Apply one of the two documents on the payload, with the runtime that
        came with it.

    .DESCRIPTION
        Windows PowerShell, deliberately: the runtime is 5.1-compatible and a
        machine at first logon has nothing else. 3010 means the apply worked and
        something it changed is read only at boot -- not a failure.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind
    )

    $payload = Get-StateValue -State $State -Name 'payload'
    $config = Join-Path $payload "$Kind\config.json"
    if (-not (Test-Path -LiteralPath $config)) {
        Write-Note "no $Kind document on the payload"
        return
    }
    $entry = Join-Path $payload "$Kind\runtime\winpkgs.ps1"

    Write-Note "applying the $Kind document"
    $code = Invoke-Tool -File $windowsPowerShell -Arguments @(
        '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', $entry,
        'apply', '-Config', $config)
    if ($code -eq $exitRebootRequired) {
        Write-Note "the $Kind document changed something that needs a reboot"
        return
    }
    if ($code -ne 0) { throw "Applying the $Kind document failed with exit code $code" }
}

function Invoke-FinalizePhase {
    <#
    .SYNOPSIS
        Destroy the setup credential and stop logging on automatically.

    .DESCRIPTION
        The password in the answer file was never a secret -- Nix cannot keep one
        -- it was a one-time credential, and this is where it stops working. The
        replacement is generated here, on this machine, and is not written down
        anywhere: nobody, including whoever built the ISO, can log in until
        somebody at the console sets a password of their own.

        Autologon is cleared outright rather than left to a count running out, so
        it does not matter how many times the run rebooted.
    #>
    param([Parameter(Mandatory)]$State)

    $logon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Write-Note 'clearing the automatic logon'
    Set-ItemProperty -Path $logon -Name 'AutoAdminLogon' -Value '0' -Type String
    foreach ($name in 'DefaultPassword', 'AutoLogonCount', 'DefaultUserName', 'DefaultDomainName') {
        Remove-ItemProperty -Path $logon -Name $name -ErrorAction SilentlyContinue
    }

    $user = Get-StateValue -State $State -Name 'user'
    if ($user) {
        Write-Note "retiring the setup password for '$user'"
        # Generated here and dropped on the floor. A machine-local account, so
        # the only way back in is to set a new password at the console.
        $bytes = New-Object 'byte[]' 48
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $throwaway = [Convert]::ToBase64String($bytes)
        try {
            $null = & net.exe user $user $throwaway
            # Must change at next logon. Set after the password, because setting
            # a password clears the flag.
            $null = & net.exe user $user /logonpasswordchg:yes
            Write-Note 'the account must be given a new password at the console'
        } finally {
            $throwaway = $null
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Get-SetupPhases {
    <#
    .SYNOPSIS
        The run, in order, and which phase the reboot follows.

    .DESCRIPTION
        `RebootAfter` is on `system` and on nothing else, and it is not about
        what the apply asked for. Everything up to and including `system` needs
        the administrator token first logon was given; everything after it must
        not have one. The reboot is where the run stops being elevated, so it has
        to happen there whether or not anything changed that needs it.
    #>
    param([Parameter(Mandatory)]$State)
    return @(
        @{ Name = 'payload';  Label = 'the payload';               Action = { Invoke-PayloadPhase -State $State } },
        @{ Name = 'wsl';      Label = 'the WSL distro';            Action = { Invoke-WslPhase -State $State } },
        @{ Name = 'system';   Label = 'the system configuration';  Action = { Invoke-DocumentPhase -State $State -Kind system }; RebootAfter = $true },
        @{ Name = 'home';     Label = 'the home configuration';    Action = { Invoke-DocumentPhase -State $State -Kind home } },
        @{ Name = 'finalize'; Label = 'the setup credential';      Action = { Invoke-FinalizePhase -State $State } }
    )
}

#endregion

#region the reboot

function Register-Resume {
    <#
    .SYNOPSIS
        Have the next sign-in continue this run, unelevated.

    .DESCRIPTION
        RunOnce under HKCU runs as this user with a standard token. That is not
        an accident of where it lives -- it is the whole mechanism: the home
        document must never be applied elevated, and coming back through here is
        what guarantees it is not. Windows removes the entry as it runs it.
    #>
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $command = '"{0}" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "{1}" -Resume' -f
        $windowsPowerShell, $scriptCopy
    New-ItemProperty -Path $key -Name 'winpkgs-setup' -Value $command -PropertyType String -Force | Out-Null
}

#endregion

#region the run

trap {
    Write-Host ''
    Write-Host "setup: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'setup: the phases that finished are recorded; re-run with -Resume to continue.' -ForegroundColor Red
    exit 1
}

if ($Reset) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }

$state = Read-State

$script:SourceRoot = $PayloadRoot
if (-not $script:SourceRoot) { $script:SourceRoot = Split-Path -Parent $PSCommandPath }

# Recorded on the first run, because after the reboot the payload's own settings
# file is the only thing that still knows them.
$settingsPath = Join-Path $script:SourceRoot 'setup.json'
if (Test-Path -LiteralPath $settingsPath) {
    $settings = (Get-Content -LiteralPath $settingsPath -Raw) | ConvertFrom-Json
    foreach ($name in 'distro', 'user') {
        if ($settings.PSObject.Properties.Name -contains $name -and -not (Get-StateValue -State $state -Name $name)) {
            Set-StateValue -State $state -Name $name -Value $settings.$name
        }
    }
}
$script:Distro = Get-StateValue -State $state -Name 'distro'
if (-not $script:Distro) { $script:Distro = 'NixOS' }

Write-Host ''
Write-Host 'setup: winpkgs, unattended' -ForegroundColor White

$phases = Get-SetupPhases -State $state

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

    # Always, not only when the apply asked. The reboot is how this run stops
    # being elevated: everything after it has to reach the machine as the user.
    if ($phase.RebootAfter) {
        $stopped = $true
        break
    }
}

if ($stopped) {
    if ($NoReboot) {
        Write-Host ''
        Write-Host 'Stopping before the reboot. Continue with:' -ForegroundColor Yellow
        Write-Note ("    powershell -ExecutionPolicy Bypass -File `"$scriptCopy`" -Resume")
        exit 0
    }
    Register-Resume
    Write-Host ''
    Write-Host 'Rebooting. The run continues at the next sign-in, as the user.' -ForegroundColor Cyan
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    exit 0
}

Write-Host ''
Write-Host 'setup: done.' -ForegroundColor Green
Write-Note 'Set a password at the console to sign in.'

#endregion
