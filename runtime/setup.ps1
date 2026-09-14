#Requires -Version 5.1
<#
.SYNOPSIS
    The unattended half of an installation: what FirstLogonCommands runs.

.DESCRIPTION
    `install.ps1` starts from a flake and has to build it, which is why it needs
    WSL, Nix and a network. This starts from a closure that is already built and
    sitting on the boot media beside it: the runtime is 5.1-compatible by
    construction, and applying a document is pure Windows. What the runtime does
    need that a new machine lacks -- WSL itself and the WinGet client module --
    travels on the media too. A network is still wanted for winget packages,
    unless the media carries their installers as well (winpkgs.installer.offline):
    then nothing in the run reaches the network at all.

    Six phases, recorded under %LOCALAPPDATA%\winpkgs\setup so the run continues
    where it stopped, with the whole run transcribed to setup.log beside them:

      payload   copy the media's payload to disk, so it can outlive the media
      wsl       install WSL, import the distro, put the configuration's system in it
      winget    install the WinGet client module; wait until winget answers
                (offline media: the module only)
      system      apply the system document                      (elevated)
      credential  arrange for the setup credential to be retired (elevated)
      home        apply the home document                        (never elevated)

    Offline is a fact of the payload, not a switch: media built with
    winpkgs.installer.offline has installers.json at the payload's root, and
    both applies are handed the copy on disk to install from (-Installers).

    The setup credential is retired at the first sign-in after the reboot, by a
    task the credential phase leaves behind: a blank password that must be
    changed at the next logon, and no more automatic logon. See the region of
    that name for why blank and why a task.

    Elevation is not managed here, it is inherited. FirstLogonCommands runs with
    the auto-logged-on administrator's full token, so everything before the
    reboot is already elevated and nothing has to prompt. Before `home` the run
    always reboots -- whether or not the apply asked for it -- and comes back
    through HKCU RunOnce, which runs at medium
    integrity. That reboot is the privilege boundary: it is what makes the home
    configuration apply as the user rather than as an administrator, which it
    must. The log says which token each run had.

    The WSL features are already enabled: the answer file turns them on in its
    servicing section while the image is still offline, before this ever runs.
    On current Windows that is not WSL, only what it needs: the features bring a
    placeholder wsl.exe that installs the real one the first time it is run --
    and closes the console it was run from, which is how the first run to reach
    this script died with nothing to say. So nothing here runs the placeholder:
    the MSI on the payload is installed first, and its wsl.exe is the one used.

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
# This file, wherever it was run from; the payload phase copies it to $scriptCopy.
$setupScript = $PSCommandPath
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# The real WSL, where its MSI installs it -- never System32\wsl.exe, which on a
# machine without the package is the placeholder described above.
$script:WslExe = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
# wsl.exe writes its own messages -- `--list` among them -- as UTF-16, which
# arrives here as text with a NUL between every letter: no distro name read
# that way ever equals the one looked for, so a resumed run would import the
# distro a second time and fail. With this set it writes UTF-8, like everything
# that runs inside the distro already does.
$env:WSL_UTF8 = '1'

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

        The exit code decides, and nothing else. Under Windows PowerShell,
        stderr redirected with 2>&1 while ErrorActionPreference is Stop turns
        the first line a program writes there into a terminating error -- so a
        warning from nix-store would end a run that was succeeding, and a real
        failure is reported as its first line of stderr instead of by its exit
        code. install.ps1 learned this; this copies what it does.
    #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [ValidateSet('utf8', 'unicode', 'default')][string]$Encoding = 'default'
    )
    $previous = [Console]::OutputEncoding
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Encoding -eq 'utf8') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
        elseif ($Encoding -eq 'unicode') { [Console]::OutputEncoding = [Text.UnicodeEncoding]::new($false, $false) }
        & $File @Arguments 2>&1 | ForEach-Object { Out-Host -InputObject "$_" }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
        [Console]::OutputEncoding = $previous
    }
}

function Invoke-Capture {
    <#
    .SYNOPSIS
        A program's stdout as lines, and its exit code: for the calls whose
        output is read rather than shown.

    .DESCRIPTION
        stderr is not part of what the program answered. It goes to the log as
        it is and stays out of the lines returned -- wsl.exe warns there on a
        distro's first start ("Failed to start the systemd user session"), and
        captured with 2>&1 that warning became part of the path wslpath gave
        back. Under Windows PowerShell with ErrorActionPreference Stop it did
        worse: the warning was thrown, as Invoke-Tool explains. Read as UTF-8,
        which wsl.exe writes with WSL_UTF8 set and a Linux program always does.
    #>
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $previous = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $all = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $previous
        $ErrorActionPreference = $eap
    }
    $out = @()
    $err = @()
    foreach ($item in $all) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $err += "$item" }
        else { $out += ("$item" -replace "`0", '') }
    }
    foreach ($line in $err) {
        if ($line.Trim()) { Write-Note "  $(Split-Path -Leaf $File): $line" }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err }
}

function ConvertTo-DistroPath {
    # A Windows path as the distro sees it. --exec, because a login shell eats
    # the backslashes of a Windows path unless it happens to contain a space.
    param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-Capture -File $script:WslExe -Arguments @('-d', $script:Distro, '--exec', 'wslpath', '-a', '-u', $Path)
    $line = @($r.Output | Where-Object { "$_".Trim() }) | Select-Object -Last 1
    if ($r.ExitCode -ne 0 -or -not $line) {
        throw "wslpath failed for '$Path' (exit $($r.ExitCode)): $($r.Error -join ' ')"
    }
    return "$line".Trim()
}

function ConvertTo-ShellArgument {
    # Single-quoted for bash, so a path with a space or a URL with a query is
    # one word whatever it contains. install.ps1's, unchanged.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Test-DistroImported {
    $r = Invoke-Capture -File $script:WslExe -Arguments @('--list', '--quiet')
    return (@($r.Output | ForEach-Object { "$_".Trim() }) -contains $script:Distro)
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
    # Offline media carries every package's installer, gigabytes of them: a
    # disk that cannot hold the copy is said so here, not by a copy that stops
    # halfway with a message about one file.
    $size = Get-DirectorySize -Path $script:SourceRoot
    $free = Get-FreeSpace -Path $stateDir
    if ($size -gt $free) {
        throw ('Copying the payload needs {0} and {1} has {2} free' -f
            (Format-Size $size), [IO.Path]::GetPathRoot($stateDir), (Format-Size $free))
    }
    Write-Note ('copying the payload ({0}) to {1}' -f (Format-Size $size), $target)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $script:SourceRoot '*') -Destination $target -Recurse -Force
    Write-Note ('copied in {0:N0} s' -f $watch.Elapsed.TotalSeconds)
    Set-StateValue -State $State -Name 'payload' -Value $target
    Copy-Item -LiteralPath $setupScript -Destination $scriptCopy -Force
}

function Get-DirectorySize {
    param([Parameter(Mandatory)][string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [long]$sum }
    return [long]0
}

function Get-FreeSpace {
    # What the volume holding Path has free for this user, quotas included.
    param([Parameter(Mandatory)][string]$Path)
    return (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
}

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Test-OfflinePayload {
    <#
    .SYNOPSIS
        Whether the payload carries the winget packages' installers.

    .DESCRIPTION
        A fact of the payload rather than a switch: media built with
        winpkgs.installer.offline has installers.json at its root, and media
        built without does not. Asked of the copy on disk, which is what both
        applies install from and what the run after the reboot still has.
    #>
    param([Parameter(Mandatory)][string]$Payload)
    return (Test-Path -LiteralPath (Join-Path $Payload 'installers.json'))
}

function Test-SetupElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WslPackage {
    <#
    .SYNOPSIS
        WSL itself, from the MSI on the payload, unless it is already there.

    .DESCRIPTION
        Whether WSL is installed is a question about a file, not something to ask
        wsl.exe: the one in System32 is the placeholder, and running it is the
        thing to avoid. The MSI puts the real one in Program Files\WSL.

        msiexec's answers that matter here:
          1618  another installation holds the Windows Installer lock. At first
                logon that is Windows finishing its own setup, and it passes.
          1925  not an administrator. Reported as such, since the run assumes
                first logon's token is elevated and this is where it finds out.
          3010  installed; a restart is wanted. Carried on from, then checked.
    #>
    param([Parameter(Mandatory)][string]$Msi)

    if (Test-Path -LiteralPath $script:WslExe) {
        Write-Note "WSL is installed ($($script:WslExe))"
        return
    }
    if (-not (Test-Path -LiteralPath $Msi)) {
        throw "WSL is not installed and the payload has no MSI at $Msi"
    }

    $log = Join-Path $stateDir 'wsl-msi.log'
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    # One pre-quoted string: Start-Process on 5.1 joins an array with spaces and
    # quotes nothing, and the profile path this sits under may have a space.
    $line = '/i "{0}" /qn /norestart /l*v "{1}"' -f $Msi, $log
    $attempts = 10
    for ($attempt = 1; ; $attempt++) {
        Write-Note "installing WSL from $Msi"
        $code = (Start-Process -FilePath $msiexec -ArgumentList $line -Wait -PassThru).ExitCode
        if ($code -ne 1618 -or $attempt -ge $attempts) { break }
        Write-Note "  another installation holds the Windows Installer; waiting (attempt $attempt of $attempts)"
        Start-Sleep -Seconds 30
    }
    switch ($code) {
        0 { }
        3010 { Write-Note '  the installer wants a restart; carrying on, and WSL is checked below' }
        1618 { throw "Another installation kept the Windows Installer busy for $attempts attempts; WSL was not installed. See $log" }
        1925 { throw "Installing WSL needs an administrator and this run is not elevated (msiexec 1925). See $log" }
        default { throw "Installing WSL failed with msiexec exit code $code. See $log" }
    }

    if (-not (Test-Path -LiteralPath $script:WslExe)) {
        throw "The WSL installer reported success but there is no $($script:WslExe). See $log"
    }
    $r = Invoke-Capture -File $script:WslExe -Arguments @('--version')
    if ($r.ExitCode -ne 0) {
        throw "WSL is installed but does not answer (wsl --version exit $($r.ExitCode)); it may need a restart. See $log"
    }
    Write-Note "WSL is installed ($($script:WslExe))"
}

function Invoke-WslPhase {
    <#
    .SYNOPSIS
        The distro, and the configuration's own system inside it.

    .DESCRIPTION
        The stock NixOS-WSL rootfs is imported first because a distro has to
        exist before anything can be put in it. The configuration's WSL system is
        then substituted from the binary cache on the payload -- no evaluation,
        no network, no flake -- and activated exactly the way `activate.sh` does
        it when the flake is present: set the system profile, then
        switch-to-configuration.

        Substituted, not unpacked: NixOS mounts /nix/store read-only and only
        the daemon writes to it, which is why an earlier tarball of store paths
        failed on the first directory it tried to make.
    #>
    param([Parameter(Mandatory)]$State)

    $payload = Get-StateValue -State $State -Name 'payload'
    $wsl = Join-Path $payload 'wsl'
    $rootfs = Join-Path $wsl 'nixos.wsl'
    $cache = Join-Path $wsl 'cache'
    $toplevelFile = Join-Path $wsl 'toplevel'

    if (-not (Test-Path -LiteralPath $rootfs)) {
        throw "The payload has no distro image at $rootfs"
    }

    # Before anything calls wsl.exe at all.
    Install-WslPackage -Msi (Join-Path $wsl 'wsl.msi')

    if (Test-DistroImported) {
        Write-Note "the distro '$($script:Distro)' is already imported"
    } else {
        $distroPath = Join-Path $env:LOCALAPPDATA "WSL\$($script:Distro)"
        New-Item -ItemType Directory -Force -Path $distroPath | Out-Null
        Write-Note "importing $rootfs as '$($script:Distro)'"
        $code = Invoke-Tool -File $script:WslExe -Encoding utf8 -Arguments @(
            '--import', $script:Distro, $distroPath, $rootfs, '--version', '2')
        if ($code -ne 0) { throw "wsl --import failed with exit code $code" }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $cache 'nix-cache-info'))) {
        Write-Note 'no WSL system on the payload; leaving the stock distro as it is'
        return
    }

    $toplevel = (Get-Content -LiteralPath $toplevelFile -Raw).Trim()
    Write-Note "activating $toplevel in the distro"
    $script = @(
        'set -euo pipefail',
        # The cache is reached through a link with no space in its path: a
        # file:// store URL is a URL, and the profile the payload sits under
        # is "C:\Users\Some One" as often as not.
        ('ln -sfn ' + (ConvertTo-ShellArgument (ConvertTo-DistroPath $cache)) + ' /tmp/winpkgs-cache'),
        # The payload's cache as the only substituter -- nothing is fetched --
        # and unsigned, since it came off the same media as everything else.
        # nix-store rather than nix copy: the stock image has no experimental
        # features enabled, and this needs none.
        ('nix-store --realise ' + $toplevel + ' --option substituters file:///tmp/winpkgs-cache --option require-sigs false'),
        ('nix-env -p /nix/var/nix/profiles/system --set ' + $toplevel),
        ($toplevel + '/bin/switch-to-configuration boot')
    ) -join "`n"

    $scriptPath = Join-Path $env:TEMP ('winpkgs-setup-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($scriptPath, $script + "`n", (New-Object Text.UTF8Encoding $false))
    try {
        $code = Invoke-Tool -File $script:WslExe -Encoding utf8 -Arguments @(
            # bash -l: only a login shell sources the profile that puts
            # /run/current-system/sw/bin on PATH, and under --exec nothing else
            # does -- which left tar, nix-store and nix-env all "not found".
            # --exec itself stays, for the backslashes (see ConvertTo-DistroPath).
            '-d', $script:Distro, '-u', 'root', '--exec', 'bash', '-l', (ConvertTo-DistroPath $scriptPath))
        if ($code -ne 0) { throw "Activating the WSL system failed with exit code $code" }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    # The distro has to come back for the new system to be the one running.
    $null = Invoke-Tool -File $script:WslExe -Arguments @('--terminate', $script:Distro) -Encoding utf8
}

function Install-WinGetClientModule {
    <#
    .SYNOPSIS
        The Microsoft.WinGet.Client module, from the payload, for every host.

    .DESCRIPTION
        Machine-wide, because the two applies are not the same session: the
        system one is elevated and the home one comes back after a reboot as an
        ordinary user, and both have to find it. Windows PowerShell's Program
        Files directory is on its module path; PowerShell 7's is where the
        winpkgs command looks afterwards. The payload carries it laid out as
        Microsoft.WinGet.Client\<version>\, so this only copies.
    #>
    param([Parameter(Mandatory)][string]$Source)

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Note 'no Microsoft.WinGet.Client on the payload; it has to be installed some other way'
        return
    }
    $roots = @(
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'PowerShell\Modules')
    )
    foreach ($root in $roots) {
        $destination = Join-Path $root 'Microsoft.WinGet.Client'
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -Path (Join-Path $Source '*') -Destination $destination -Recurse -Force
        Write-Note "Microsoft.WinGet.Client -> $destination"
    }
}

function Update-SessionPath {
    <#
    .SYNOPSIS
        This process's PATH, from what the machine and the user say it is now.

    .DESCRIPTION
        A process keeps the PATH it was started with, and this one was started
        by FirstLogonCommands at the very first sign-in and runs for a long
        time. install.ps1's refresh, and the WindowsApps directory -- where
        winget's App Execution Alias lives -- added if the registry does not
        list it yet. A precaution, not a diagnosis: when winget first failed
        here, it was on PATH (see Wait-WinGetReady).
    #>
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (@($env:Path -split ';') -notcontains $apps) { $env:Path = $env:Path.TrimEnd(';') + ";$apps" }
}

function Test-WinGetUsable {
    # The first question the runtime asks winget, for a package that cannot
    # exist: it goes through the same COM path the applies use, and answers
    # nothing quickly.
    $null = Get-WinGetPackage -Id 'winpkgs.readiness.probe' -MatchOption Equals -ErrorAction Stop
}

function Wait-WinGetReady {
    <#
    .SYNOPSIS
        Wait until the WinGet client can talk to winget, and repair it if it
        cannot by itself.

    .DESCRIPTION
        Ready means the runtime's own first call works, not what
        Assert-WinGetPackageManager says. On the machine this was built
        against, the ISO's winget (1.11) worked for everything the runtime does
        -- from an elevated process and an unelevated one alike -- while Assert
        refused it for over half an hour, until something else had opened
        winget's package source once. Waiting on Assert waited for nothing the
        applies need, and the repair it led to failed too.

        The repair is the module's, installing the winget it was built for, so
        it needs a network; the applies after this need one for their packages
        anyway. Without -Latest: asking for the newest is what made it refuse
        the winget it had just installed, as not the version expected. Offline
        media never gets here (Invoke-WinGetPhase).
    #>
    param([int]$WaitSeconds = 180, [int]$IntervalSeconds = 15)

    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ($true) {
        Update-SessionPath
        try {
            Test-WinGetUsable
            Write-Note "winget is ready ($(Get-WinGetVersion))"
            return
        } catch {
            $last = $_.Exception.Message
        }
        if ((Get-Date) -ge $deadline) { break }
        Write-Note "  winget is not ready yet: $last"
        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Note "winget did not come up by itself within $WaitSeconds s ($last); repairing it"
    Repair-WinGetPackageManager -AllUsers -Force -ErrorAction Stop | Out-Host
    Update-SessionPath
    Test-WinGetUsable
    Write-Note "winget is ready after the repair ($(Get-WinGetVersion))"
}

function Invoke-WinGetPhase {
    <#
    .SYNOPSIS
        The WinGet client module, and winget answering -- or, from offline
        media, the module alone.

    .DESCRIPTION
        The module is installed either way: the first apply with a network
        hands the packages to winget, and that goes through it. Waiting for
        winget is not wanted offline: the applies never ask it anything, and
        the repair the wait falls back on fetches App Installer.
    #>
    param([Parameter(Mandatory)]$State)
    $payload = Get-StateValue -State $State -Name 'payload'
    Install-WinGetClientModule -Source (Join-Path $payload 'modules\Microsoft.WinGet.Client')
    if (Test-OfflinePayload -Payload $payload) {
        Write-Note 'the payload carries the packages'' installers: winget is not asked anything until an apply with a network'
        return
    }
    Wait-WinGetReady
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

        From offline media the apply is handed the payload's copy on disk as
        -Installers, and installs every winget package from the file carried
        for it. The copy, not the media: the home apply comes after the reboot,
        when the media may be gone.
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

    $arguments = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', $entry, 'apply', '-Config', $config)
    if (Test-OfflinePayload -Payload $payload) {
        Write-Note "applying the $Kind document, its winget packages from the installers on the payload"
        $arguments += @('-Installers', $payload)
    } else {
        Write-Note "applying the $Kind document"
    }
    $code = Invoke-Tool -File $windowsPowerShell -Arguments $arguments
    if ($code -eq $exitRebootRequired) {
        Write-Note "the $Kind document changed something that needs a reboot"
        return
    }
    if ($code -ne 0) { throw "Applying the $Kind document failed with exit code $code" }
}

#region the setup credential
<#
    The password in the answer file was never a secret -- Nix cannot keep one --
    it is a one-time credential, and it stops working at the first sign-in after
    the reboot. What replaces it is a blank password the account must change at
    its next logon: the first person at the console signs in with nothing and is
    made to choose one.

    Blank, not random. "Must change at next logon" still asks for the current
    password before it asks for a new one, so a random password nobody knows is
    not a forced change but a machine nobody can sign in to -- which is what an
    earlier version of this would have done. A blank one is known to whoever is
    at the keyboard and to nobody else: Windows lets a blank password sign in at
    the console only, never over the network.

    Retiring it needs an administrator and has to happen after the last
    automatic logon, and nothing in this run is both: the reboot that makes the
    home configuration apply as an ordinary user is also the end of the
    administrator token. So the elevated half registers a task that runs as
    SYSTEM at the next sign-in, does this, and deletes itself. Its script is in
    the task definition, not in a file in the user's profile that the user's own
    unelevated processes could rewrite before SYSTEM ran it.
#>

function Set-LocalAccountBlankPassword {
    # ADSI rather than net.exe: no prompt to answer, and a failure throws instead
    # of printing and exiting with a code nothing read. PasswordExpired is set
    # after the password, which would otherwise clear it.
    param([Parameter(Mandatory)][string]$User)
    $account = [ADSI]"WinNT://$env:COMPUTERNAME/$User,user"
    $account.SetPassword('')
    $account.Put('PasswordExpired', 1)
    $account.SetInfo()
}

function Disable-AutoLogon {
    # Cleared outright rather than left to a count running out, so it does not
    # matter how many times the run rebooted on the way.
    $logon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $logon -Name 'AutoAdminLogon' -Value '0' -Type String
    foreach ($name in 'DefaultPassword', 'AutoLogonCount') {
        Remove-ItemProperty -Path $logon -Name $name -ErrorAction SilentlyContinue
    }
}

function Invoke-RetireSetupCredential {
    <#
    .SYNOPSIS
        What the task does, as SYSTEM, at the first sign-in after the reboot.

    .DESCRIPTION
        The password first. If it cannot be changed, automatic logon and the task
        are both left as they were, so the next sign-in tries again and the
        machine stays reachable meanwhile by the setup password its builder
        knows. Nothing here can leave an account nobody can sign in to.
    #>
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath
    )
    Set-LocalAccountBlankPassword -User $User
    Disable-AutoLogon
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
}

function New-RetireCommand {
    <#
    .SYNOPSIS
        The task's whole script, for -EncodedCommand: the three functions above,
        and the call.
    #>
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$Log
    )
    $quote = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $definitions = foreach ($name in 'Set-LocalAccountBlankPassword', 'Disable-AutoLogon', 'Invoke-RetireSetupCredential') {
        "function $name {$((Get-Command -Name $name -CommandType Function).Definition)}"
    }
    $script = @(
        "`$ErrorActionPreference = 'Stop'",
        "try { Start-Transcript -LiteralPath $(& $quote $Log) -Append | Out-Null } catch { Write-Verbose 'No transcript' }"
    ) + $definitions + @(
        'try {',
        "    Invoke-RetireSetupCredential -User $(& $quote $User) -TaskName $(& $quote $TaskName) -TaskPath $(& $quote $TaskPath)",
        "    'the setup credential is retired: a blank password, to be changed at the next logon'",
        '} finally {',
        "    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }",
        '}'
    )
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script -join "`n"))
}

function Invoke-CredentialPhase {
    <#
    .SYNOPSIS
        Arrange for the setup credential to be retired at the next sign-in.
    #>
    param([Parameter(Mandatory)]$State)

    $user = Get-StateValue -State $State -Name 'user'
    if (-not $user) {
        # Nothing to retire is not the same as retiring nothing: this must not
        # invent a user name and lock somebody out of a machine.
        Write-Note 'no account recorded; the setup credential is left as it is'
        return
    }
    $taskName = 'retire-setup-credential'
    $taskPath = '\winpkgs\'
    $encoded = New-RetireCommand -User $user -TaskName $taskName -TaskPath $taskPath -Log (Join-Path $stateDir 'credential.log')

    $action = New-ScheduledTaskAction -Execute $windowsPowerShell `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    # The next sign-in is the automatic one after the reboot, and it has already
    # used the setup password by the time this fires; the delay is margin.
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$user"
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Note "the setup credential is retired at $user's next sign-in ($taskPath$taskName)"
}

#endregion

function Get-SetupPhases {
    <#
    .SYNOPSIS
        The run, in order, and which phase the reboot follows.

    .DESCRIPTION
        `RebootAfter` is on `credential`, the last phase that needs the
        administrator token first logon was given, and on nothing else; it is
        not about what the system apply asked for. Everything before the reboot
        needs that token and everything after it must not have one. The reboot
        is where the run stops being elevated, so it has to happen there whether
        or not anything changed that needs it.
    #>
    param([Parameter(Mandatory)]$State)
    return @(
        @{ Name = 'payload';  Label = 'the payload';               Action = { Invoke-PayloadPhase -State $State } },
        @{ Name = 'wsl';      Label = 'WSL and the distro';        Action = { Invoke-WslPhase -State $State } },
        # After wsl, not before: importing and activating the distro takes
        # minutes, and those are minutes the Store spends registering winget.
        @{ Name = 'winget';   Label = 'winget';                    Action = { Invoke-WinGetPhase -State $State } },
        @{ Name = 'system';     Label = 'the system configuration'; Action = { Invoke-DocumentPhase -State $State -Kind system } },
        # Registered while there is still an administrator to register it; it
        # runs after the reboot, at the sign-in that is the last automatic one.
        @{ Name = 'credential'; Label = 'the setup credential';     Action = { Invoke-CredentialPhase -State $State }; RebootAfter = $true },
        @{ Name = 'home';       Label = 'the home configuration';   Action = { Invoke-DocumentPhase -State $State -Kind home } }
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
    Write-Host "setup: the whole run is in $logPath" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }
    exit 1
}

# FirstLogonCommands gives this a console nobody is watching and closes it the
# moment the script ends, so without a transcript a failure leaves nothing
# behind -- which is how the first run to get this far stopped in the wsl phase
# with no record of why. Appended, so a resumed run adds to the same log.
$logPath = Join-Path $stateDir 'setup.log'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
try { Start-Transcript -LiteralPath $logPath -Append | Out-Null } catch { Write-Verbose 'No transcript' }

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
# The one thing the whole run assumes and no earlier run lived long enough to
# see: whether first logon's token is elevated. Written down every time.
Write-Note ("running as {0}, elevated: {1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, (Test-SetupElevated))

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
        try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }
        exit 0
    }
    Register-Resume
    Write-Host ''
    Write-Host 'Rebooting. The run continues at the next sign-in, as the user.' -ForegroundColor Cyan
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    exit 0
}

Write-Host ''
Write-Host 'setup: done.' -ForegroundColor Green
Write-Note 'At the next sign-in the password is blank, and must be changed.'
Write-Note "The whole run is in $logPath"
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' }

#endregion
