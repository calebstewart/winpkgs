<#
    winpkgs/service - a Windows service's definition, and that it exists.
    Machine scope.

    properties:
      name            the service's name
      displayName
      description     $null leaves it alone
      command         the image path: the command line the SCM runs
      type            own | userOwn. userOwn is a per-user service template:
                      Windows starts an instance of it, <name>_<suffix>, in each
                      session that signs in, running as that user.
      startType       automatic | delayedAutomatic | manual | disabled
      account         the account an own-process service runs as; $null is
                      LocalSystem. A template's instances run as their user.
      failureActions  $null leaves them alone, or
                      @{ reset = <seconds>; actions = @(@{ action = 'restart' | 'reboot' | 'none'; delay = <ms> }) }
      revision        $null, or a string; when it differs from the one last
                      applied, whatever runs the service is restarted -- the
                      service itself, or every running instance of a template.
                      NixOS's restartTriggers.

    Read from the service's registry key, which needs no elevation, so a plan
    runs unelevated. Changed through the service control manager's API rather
    than sc.exe, whose `binPath=` needs embedded quotes that Windows PowerShell
    5.1 -- which an elevated apply may run under -- strips from a native
    command's arguments.

    A template's instances copy its definition when they are created, at
    sign-in, and never again; a change is therefore also made to every instance
    that exists. Creating a template starts nothing: its first instance
    appears at the next sign-in. Creating an own-process service that starts
    automatically also starts it, as a NixOS switch would.

    A service's type is not changed in place; declaring a different one is an
    error that says to remove the service first.

    A service winpkgs created is owned (the ledger's `services`) and deleted,
    instances first, once it leaves the configuration. One that already
    existed is managed but never deleted.

    WINPKGS_SERVICE_ROOT puts services under another registry key and stands
    that key in for the SCM as well: definitions are written there directly,
    a value `WinPkgsTestRunning` = 1 means running, and WINPKGS_SERVICE_LOG
    records starts, stops and deletions (tests).
#>

$script:ServiceTypes = @{ 0x10 = 'own'; 0x20 = 'share'; 0x50 = 'userOwn'; 0x60 = 'userShare' }
$script:ServiceTypeCodes = @{ own = 0x10; userOwn = 0x50 }
$script:FailureActionCodes = @{ none = 0; restart = 1; reboot = 2; run = 3 }

function Get-WinPkgsServiceRoot {
    if ($env:WINPKGS_SERVICE_ROOT) { return $env:WINPKGS_SERVICE_ROOT }
    return 'HKLM\SYSTEM\CurrentControlSet\Services'
}

function Get-WinPkgsServiceKeyPath {
    param([Parameter(Mandatory)][string]$Name)
    return ConvertTo-WinPkgsRegistryPath -Key "$(Get-WinPkgsServiceRoot)\$Name"
}

# --- the failure-actions value --------------------------------------------------

function ConvertFrom-WinPkgsFailureActions {
    # SERVICE_FAILURE_ACTIONS as the SCM stores it: reset period, two unused
    # pointer fields, the action count, an offset, then (type, delay) pairs.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 20) { return $null }
    $names = @{ 0 = 'none'; 1 = 'restart'; 2 = 'reboot'; 3 = 'run' }
    $count = [BitConverter]::ToUInt32($Bytes, 12)
    $actions = @()
    for ($i = 0; $i -lt $count -and (28 + 8 * $i) -le $Bytes.Length; $i++) {
        $actions += , @{
            action = $names[[int][BitConverter]::ToUInt32($Bytes, 20 + 8 * $i)]
            delay  = [int64][BitConverter]::ToUInt32($Bytes, 24 + 8 * $i)
        }
    }
    return @{ reset = [int64][BitConverter]::ToUInt32($Bytes, 0); actions = $actions }
}

function ConvertTo-WinPkgsFailureActions {
    param([hashtable]$FailureActions)
    $actions = @($FailureActions['actions'])
    $bytes = New-Object byte[] (20 + 8 * $actions.Count)
    [BitConverter]::GetBytes([uint32]$FailureActions['reset']).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([uint32]$actions.Count).CopyTo($bytes, 12)
    [BitConverter]::GetBytes([uint32]20).CopyTo($bytes, 16)
    for ($i = 0; $i -lt $actions.Count; $i++) {
        [BitConverter]::GetBytes([uint32]$script:FailureActionCodes[[string]$actions[$i]['action']]).CopyTo($bytes, 20 + 8 * $i)
        [BitConverter]::GetBytes([uint32]$actions[$i]['delay']).CopyTo($bytes, 24 + 8 * $i)
    }
    return , $bytes
}

function Test-WinPkgsFailureActionsEqual {
    param([hashtable]$Expected, [hashtable]$Actual)
    if ($null -eq $Actual) { return (@($Expected['actions']).Count -eq 0 -and [int64]$Expected['reset'] -eq 0) }
    if ([int64]$Expected['reset'] -ne [int64]$Actual['reset']) { return $false }
    $e = @($Expected['actions']); $a = @($Actual['actions'])
    if ($e.Count -ne $a.Count) { return $false }
    for ($i = 0; $i -lt $e.Count; $i++) {
        if ([string]$e[$i]['action'] -ne [string]$a[$i]['action']) { return $false }
        if ([int64]$e[$i]['delay'] -ne [int64]$a[$i]['delay']) { return $false }
    }
    return $true
}

# --- reading ----------------------------------------------------------------------

function Read-WinPkgsServiceDefinition {
    # $null if there is no such service.
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-WinPkgsServiceKeyPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $key = Get-Item -LiteralPath $path
    $names = @($key.GetValueNames())
    $raw = {
        param($n)
        if ($names -notcontains $n) { return $null }
        return $key.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
    }
    $typeCode = [int64](& $raw 'Type')
    if ($names -notcontains 'Type') { return $null }
    $type = $script:ServiceTypes[[int]($typeCode -band 0x7F)]
    if (-not $type) { $type = 'other' }
    $start = [int](& $raw 'Start')
    $startType = switch ($start) {
        0 { 'boot' } 1 { 'system' } 3 { 'manual' } 4 { 'disabled' }
        2 { if ([int](& $raw 'DelayedAutostart') -eq 1) { 'delayedAutomatic' } else { 'automatic' } }
        default { "start $start" }
    }
    return @{
        type           = $type
        instance       = [bool]($typeCode -band 0x80)
        startType      = $startType
        command        = [string](& $raw 'ImagePath')
        displayName    = [string](& $raw 'DisplayName')
        description    = & $raw 'Description'
        account        = [string](& $raw 'ObjectName')
        failureActions = ConvertFrom-WinPkgsFailureActions -Bytes (& $raw 'FailureActions')
        revision       = & $raw 'WinPkgsRevision'
    }
}

function Get-WinPkgsServiceInstanceNames {
    # A template's instances: <name>_<suffix>, flagged as instances.
    param([Parameter(Mandatory)][string]$Name)
    $root = ConvertTo-WinPkgsRegistryPath -Key (Get-WinPkgsServiceRoot)
    $pattern = '^' + [regex]::Escape($Name) + '_[0-9A-Fa-f]+$'
    foreach ($child in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        if ($child.PSChildName -notmatch $pattern) { continue }
        $definition = Read-WinPkgsServiceDefinition -Name $child.PSChildName
        if ($definition -and $definition['instance']) { $child.PSChildName }
    }
}

function Test-WinPkgsServiceRunning {
    param([Parameter(Mandatory)][string]$Name)
    if ($env:WINPKGS_SERVICE_ROOT) {
        $key = Get-Item -LiteralPath (Get-WinPkgsServiceKeyPath -Name $Name) -ErrorAction SilentlyContinue
        return ($null -ne $key -and [int]$key.GetValue('WinPkgsTestRunning', 0) -eq 1)
    }
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# --- the service control manager ------------------------------------------------

function Initialize-WinPkgsScm {
    if ('WinPkgs.Native.Scm' -as [type]) { return }
    # C# 5: Windows PowerShell compiles this with the .NET Framework's csc.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace WinPkgs.Native {
    public static class Scm {
        const uint ManagerAccess = 0xF003F;
        const uint ServiceAccess = 0xF01FF;
        public const uint NoChange = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential)]
        struct Status { public uint Type, State, Accepted, Win32Exit, SpecificExit, CheckPoint, WaitHint; }
        [StructLayout(LayoutKind.Sequential)]
        struct Action { public uint Type; public uint Delay; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FailureActions { public uint Reset; public string RebootMessage; public string Command; public uint Count; public IntPtr Actions; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Description { public string Text; }
        [StructLayout(LayoutKind.Sequential)]
        struct Delayed { public int Value; }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateServiceW(IntPtr manager, string name, string display, uint access, uint type,
            uint start, uint error, string path, string group, IntPtr tag, string dependencies, string account, string password);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ChangeServiceConfigW(IntPtr service, uint type, uint start, uint error, string path,
            string group, IntPtr tag, string dependencies, string account, string password, string display);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfig2W")]
        static extern bool SetDescription(IntPtr service, uint level, ref Description info);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfig2W")]
        static extern bool SetFailureActions(IntPtr service, uint level, ref FailureActions info);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfig2W")]
        static extern bool SetDelayed(IntPtr service, uint level, ref Delayed info);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool DeleteService(IntPtr service);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CloseServiceHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool StartServiceW(IntPtr service, uint count, IntPtr arguments);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool ControlService(IntPtr service, uint control, ref Status status);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool QueryServiceStatus(IntPtr service, ref Status status);

        static void Check(bool ok) { if (!ok) throw new Win32Exception(); }

        // PowerShell hands $null to a string parameter as "", and to the SCM ""
        // is an account (or display name) of that name: an empty string here
        // means none.
        public static string OrNull(string s) { return string.IsNullOrEmpty(s) ? null : s; }

        static IntPtr Manager() {
            IntPtr manager = OpenSCManagerW(null, null, ManagerAccess);
            if (manager == IntPtr.Zero) throw new Win32Exception();
            return manager;
        }

        delegate void WithService(IntPtr service);

        static void Use(string name, WithService body) {
            IntPtr manager = Manager();
            try {
                IntPtr service = OpenServiceW(manager, name, ServiceAccess);
                if (service == IntPtr.Zero) throw new Win32Exception();
                try { body(service); } finally { CloseServiceHandle(service); }
            } finally { CloseServiceHandle(manager); }
        }

        public static void Create(string name, string display, uint type, uint start, string command, string account) {
            IntPtr manager = Manager();
            try {
                IntPtr service = CreateServiceW(manager, name, OrNull(display), ServiceAccess, type, start, 1, command,
                    null, IntPtr.Zero, null, OrNull(account), null);
                if (service == IntPtr.Zero) throw new Win32Exception();
                CloseServiceHandle(service);
            } finally { CloseServiceHandle(manager); }
        }

        // A null or empty string, or NoChange, leaves that part of the definition alone.
        public static void Change(string name, uint start, string command, string display, string account) {
            Use(name, delegate(IntPtr s) {
                Check(ChangeServiceConfigW(s, NoChange, start, NoChange, OrNull(command), null, IntPtr.Zero, null,
                    OrNull(account), null, OrNull(display)));
            });
        }

        public static void Describe(string name, string text) {
            Use(name, delegate(IntPtr s) {
                Description d = new Description(); d.Text = text;
                Check(SetDescription(s, 1, ref d));
            });
        }

        public static void DelayAutoStart(string name, bool delayed) {
            Use(name, delegate(IntPtr s) {
                Delayed d = new Delayed(); d.Value = delayed ? 1 : 0;
                Check(SetDelayed(s, 3, ref d));
            });
        }

        public static void OnFailure(string name, uint reset, uint[] types, uint[] delays) {
            Use(name, delegate(IntPtr s) {
                int size = Marshal.SizeOf(typeof(Action));
                IntPtr buffer = Marshal.AllocHGlobal(size * Math.Max(1, types.Length));
                try {
                    for (int i = 0; i < types.Length; i++) {
                        Action a = new Action(); a.Type = types[i]; a.Delay = delays[i];
                        Marshal.StructureToPtr(a, new IntPtr(buffer.ToInt64() + i * size), false);
                    }
                    FailureActions f = new FailureActions();
                    f.Reset = reset; f.Count = (uint)types.Length; f.Actions = buffer;
                    Check(SetFailureActions(s, 2, ref f));
                } finally { Marshal.FreeHGlobal(buffer); }
            });
        }

        public static void Delete(string name) {
            Use(name, delegate(IntPtr s) { Check(DeleteService(s)); });
        }

        public static void Start(string name) {
            Use(name, delegate(IntPtr s) {
                if (!StartServiceW(s, 0, IntPtr.Zero)) {
                    int error = Marshal.GetLastWin32Error();
                    if (error != 1056) throw new Win32Exception(error);  // already running
                }
            });
        }

        // Ask the service to stop and wait, up to the timeout, until it has.
        public static void Stop(string name, int timeoutMs) {
            Use(name, delegate(IntPtr s) {
                Status status = new Status();
                if (!ControlService(s, 1, ref status)) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 1062) return;  // not running
                    throw new Win32Exception(error);
                }
                DateTime giveUp = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                while (status.State != 1) {
                    if (DateTime.UtcNow > giveUp) throw new TimeoutException("the service did not stop within " + timeoutMs + " ms");
                    Thread.Sleep(200);
                    Check(QueryServiceStatus(s, ref status));
                }
            });
        }
    }
}
'@
}

function Write-WinPkgsServiceLog {
    param([string]$Line)
    if ($env:WINPKGS_SERVICE_LOG) { Add-Content -LiteralPath $env:WINPKGS_SERVICE_LOG -Value $Line }
}

function Save-WinPkgsServiceDefinition {
    <#
        Create a service, or change one, to $Definition. Keys that are $null
        (description, failureActions, account on a change) are left alone.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Definition,
        [switch]$Create
    )
    $startCode = switch ([string]$Definition['startType']) {
        'automatic' { 2 } 'delayedAutomatic' { 2 } 'manual' { 3 } 'disabled' { 4 }
        default { throw "Unknown start type '$($Definition['startType'])' for service $Name." }
    }
    $delayed = ([string]$Definition['startType'] -eq 'delayedAutomatic')

    if ($env:WINPKGS_SERVICE_ROOT) {
        $path = Get-WinPkgsServiceKeyPath -Name $Name
        if ($Create) {
            New-Item -Path $path -Force | Out-Null
            Set-ItemProperty -LiteralPath $path -Name 'Type' -Value $script:ServiceTypeCodes[[string]$Definition['type']] -Type DWord
            Write-WinPkgsServiceLog "create $Name"
        } elseif (-not (Test-Path -LiteralPath $path)) {
            throw "No service $Name to change."
        }
        Set-ItemProperty -LiteralPath $path -Name 'Start' -Value $startCode -Type DWord
        Set-ItemProperty -LiteralPath $path -Name 'DelayedAutostart' -Value ([int]$delayed) -Type DWord
        if ($Definition.ContainsKey('command')) { Set-ItemProperty -LiteralPath $path -Name 'ImagePath' -Value ([string]$Definition['command']) -Type ExpandString }
        if ($Definition['displayName']) { Set-ItemProperty -LiteralPath $path -Name 'DisplayName' -Value ([string]$Definition['displayName']) -Type String }
        if ($null -ne $Definition['description']) { Set-ItemProperty -LiteralPath $path -Name 'Description' -Value ([string]$Definition['description']) -Type String }
        $account = if ($Definition['account']) { [string]$Definition['account'] } elseif ($Create) { 'LocalSystem' } else { $null }
        if ($account) { Set-ItemProperty -LiteralPath $path -Name 'ObjectName' -Value $account -Type String }
        if ($null -ne $Definition['failureActions']) {
            Set-ItemProperty -LiteralPath $path -Name 'FailureActions' -Value (ConvertTo-WinPkgsFailureActions -FailureActions $Definition['failureActions']) -Type Binary
        }
        return
    }

    Initialize-WinPkgsScm
    $command = [string]$Definition['command']
    $account = if ($Definition['account']) { [string]$Definition['account'] } else { $null }
    if ($Create) {
        [WinPkgs.Native.Scm]::Create($Name, [string]$Definition['displayName'], [uint32]$script:ServiceTypeCodes[[string]$Definition['type']], [uint32]$startCode, $command, $account)
    } else {
        $display = if ($Definition['displayName']) { [string]$Definition['displayName'] } else { $null }
        [WinPkgs.Native.Scm]::Change($Name, [uint32]$startCode, $command, $display, $account)
    }
    if ($startCode -eq 2) { [WinPkgs.Native.Scm]::DelayAutoStart($Name, $delayed) }
    if ($null -ne $Definition['description']) { [WinPkgs.Native.Scm]::Describe($Name, [string]$Definition['description']) }
    if ($null -ne $Definition['failureActions']) {
        $actions = @($Definition['failureActions']['actions'])
        $types = [uint32[]]@($actions | ForEach-Object { $script:FailureActionCodes[[string]$_['action']] })
        $delays = [uint32[]]@($actions | ForEach-Object { [uint32]$_['delay'] })
        [WinPkgs.Native.Scm]::OnFailure($Name, [uint32]$Definition['failureActions']['reset'], $types, $delays)
    }
}

function Remove-WinPkgsServiceDefinition {
    param([Parameter(Mandatory)][string]$Name)
    Write-WinPkgsServiceLog "delete $Name"
    if ($env:WINPKGS_SERVICE_ROOT) {
        Remove-Item -LiteralPath (Get-WinPkgsServiceKeyPath -Name $Name) -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Initialize-WinPkgsScm
    if (Test-WinPkgsServiceRunning -Name $Name) { [WinPkgs.Native.Scm]::Stop($Name, 30000) }
    [WinPkgs.Native.Scm]::Delete($Name)
}

function Start-WinPkgsServiceProcess {
    param([Parameter(Mandatory)][string]$Name)
    Write-WinPkgsServiceLog "start $Name"
    if ($env:WINPKGS_SERVICE_ROOT) {
        Set-ItemProperty -LiteralPath (Get-WinPkgsServiceKeyPath -Name $Name) -Name 'WinPkgsTestRunning' -Value 1 -Type DWord
        return
    }
    Initialize-WinPkgsScm
    [WinPkgs.Native.Scm]::Start($Name)
}

function Restart-WinPkgsServiceProcess {
    param([Parameter(Mandatory)][string]$Name)
    Write-WinPkgsServiceLog "restart $Name"
    if ($env:WINPKGS_SERVICE_ROOT) { return }
    Initialize-WinPkgsScm
    [WinPkgs.Native.Scm]::Stop($Name, 30000)
    [WinPkgs.Native.Scm]::Start($Name)
}

function Write-WinPkgsServiceRevision {
    # Kept beside the definition it describes; the SCM ignores values it does
    # not know.
    param([Parameter(Mandatory)][string]$Name, $Revision)
    $path = Get-WinPkgsServiceKeyPath -Name $Name
    if ($null -eq $Revision) {
        Remove-ItemProperty -LiteralPath $path -Name 'WinPkgsRevision' -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -LiteralPath $path -Name 'WinPkgsRevision' -Value ([string]$Revision) -Type String
    }
}

# --- the resource -------------------------------------------------------------------

function Get-WinPkgsServiceWanted {
    # The declared definition, with the defaults filled in.
    param([hashtable]$Properties)
    $name = [string]$Properties['name']
    return @{
        type           = if ($Properties['type']) { [string]$Properties['type'] } else { 'own' }
        startType      = if ($Properties['startType']) { [string]$Properties['startType'] } else { 'automatic' }
        command        = [string]$Properties['command']
        displayName    = if ($Properties['displayName']) { [string]$Properties['displayName'] } else { $name }
        description    = $Properties['description']
        account        = $Properties['account']
        failureActions = $Properties['failureActions']
    }
}

function Test-WinPkgsAccountEqual {
    param($Wanted, [string]$Actual)
    $normal = {
        param($a)
        if ([string]::IsNullOrEmpty([string]$a) -or [string]$a -eq 'LocalSystem') { return 'localsystem' }
        return ([string]$a).ToLowerInvariant()
    }
    return ((& $normal $Wanted) -eq (& $normal $Actual))
}

function Get-WinPkgsServiceDifferences {
    # What in $Current differs from $Wanted, by name: the parts a change sets.
    param([hashtable]$Wanted, [hashtable]$Current, [switch]$Instance)
    $diffs = @()
    if (-not $Instance) {
        if ($Wanted['type'] -ne $Current['type']) { $diffs += 'type' }
        if ($Wanted['displayName'] -cne $Current['displayName']) { $diffs += 'displayName' }
        if ($Wanted['type'] -eq 'own' -and -not (Test-WinPkgsAccountEqual -Wanted $Wanted['account'] -Actual $Current['account'])) { $diffs += 'account' }
    }
    if ($Wanted['startType'] -ne $Current['startType']) { $diffs += 'startType' }
    if ($Wanted['command'] -cne $Current['command']) { $diffs += 'command' }
    if ($null -ne $Wanted['description'] -and [string]$Wanted['description'] -cne [string]$Current['description']) { $diffs += 'description' }
    if ($null -ne $Wanted['failureActions'] -and -not (Test-WinPkgsFailureActionsEqual -Expected $Wanted['failureActions'] -Actual $Current['failureActions'])) {
        $diffs += 'failureActions'
    }
    return , $diffs
}

function Get-WinPkgsService {
    param([hashtable]$Properties, [hashtable]$Context)
    $name = [string]$Properties['name']
    $current = Read-WinPkgsServiceDefinition -Name $name
    if (-not $current) { return @{ exists = $false } }
    $current['exists'] = $true
    if ($current['type'] -eq 'userOwn') {
        $current['instances'] = @(foreach ($i in @(Get-WinPkgsServiceInstanceNames -Name $name)) {
            $d = Read-WinPkgsServiceDefinition -Name $i
            $d['name'] = $i
            $d
        })
    }
    return $current
}

function Test-WinPkgsService {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $wanted = Get-WinPkgsServiceWanted -Properties $Properties
    if ((Get-WinPkgsServiceDifferences -Wanted $wanted -Current $Current).Count -gt 0) { return $false }
    foreach ($instance in @($Current['instances'])) {
        if (-not $instance) { continue }
        if ((Get-WinPkgsServiceDifferences -Wanted $wanted -Current $instance -Instance).Count -gt 0) { return $false }
    }
    if ($null -ne $Properties['revision'] -and [string]$Properties['revision'] -cne [string]$Current['revision']) { return $false }
    return $true
}

function Set-WinPkgsService {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $name = [string]$Properties['name']
    $wanted = Get-WinPkgsServiceWanted -Properties $Properties
    $created = -not $Current['exists']
    $restart = $false

    if ($created) {
        Save-WinPkgsServiceDefinition -Name $name -Definition $wanted -Create
        Add-WinPkgsOwned -Context $Context -Backend 'services' -Id $name
    } else {
        if ($wanted['type'] -ne $Current['type']) {
            throw ("Service $name is $($Current['type']) and is declared $($wanted['type']); a service's type " +
                   'cannot be changed in place. Remove it from the configuration, apply, and declare it again.')
        }
        $diffs = Get-WinPkgsServiceDifferences -Wanted $wanted -Current $Current
        if ($diffs.Count -gt 0) { Save-WinPkgsServiceDefinition -Name $name -Definition $wanted }
        # A new program or a new account means what runs is not what is declared.
        $restart = ($diffs -contains 'command') -or ($diffs -contains 'account')
        foreach ($instance in @($Current['instances'])) {
            if (-not $instance) { continue }
            $instanceDiffs = Get-WinPkgsServiceDifferences -Wanted $wanted -Current $instance -Instance
            if ($instanceDiffs.Count -eq 0) { continue }
            $forInstance = @{}
            foreach ($k in 'startType', 'command', 'description', 'failureActions') { $forInstance[$k] = $wanted[$k] }
            Save-WinPkgsServiceDefinition -Name $instance['name'] -Definition $forInstance
            if ($instanceDiffs -contains 'command') { $restart = $true }
        }
    }

    if ($null -ne $Properties['revision']) {
        if ([string]$Properties['revision'] -cne [string]$Current['revision'] -and -not $created) { $restart = $true }
        Write-WinPkgsServiceRevision -Name $name -Revision $Properties['revision']
    }

    if ($restart) {
        $running = if ($wanted['type'] -eq 'userOwn') {
            @(Get-WinPkgsServiceInstanceNames -Name $name | Where-Object { Test-WinPkgsServiceRunning -Name $_ })
        } elseif (Test-WinPkgsServiceRunning -Name $name) { @($name) } else { @() }
        foreach ($target in $running) {
            Write-Host "    restarting $target"
            try { Restart-WinPkgsServiceProcess -Name $target }
            catch { Write-Warning "Could not restart ${target}: $($_.Exception.Message). It runs the old definition until it next starts." }
        }
    }

    if ($created) {
        if ($wanted['type'] -eq 'userOwn') {
            Write-Host "    $name is a per-user service template: its first instance starts at the next sign-in"
        } elseif ($wanted['startType'] -in 'automatic', 'delayedAutomatic') {
            Start-WinPkgsServiceProcess -Name $name
        }
    }
}

function Restore-WinPkgsService {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $name = [string]$Properties['name']
    $now = Read-WinPkgsServiceDefinition -Name $name
    if (-not $Before['exists']) {
        if (-not $now) { return }
        # Instances first: a template cannot outlive them cleanly.
        if ($now['type'] -eq 'userOwn') {
            foreach ($i in @(Get-WinPkgsServiceInstanceNames -Name $name)) { Remove-WinPkgsServiceDefinition -Name $i }
        }
        Remove-WinPkgsServiceDefinition -Name $name
        Remove-WinPkgsOwned -Context $Context -Backend 'services' -Id $name
        return
    }
    $definition = @{}
    foreach ($k in 'type', 'startType', 'command', 'displayName', 'description', 'account', 'failureActions') { $definition[$k] = $Before[$k] }
    if (-not $now) {
        Save-WinPkgsServiceDefinition -Name $name -Definition $definition -Create
    } else {
        Save-WinPkgsServiceDefinition -Name $name -Definition $definition
    }
    Write-WinPkgsServiceRevision -Name $name -Revision $Before['revision']
    if ($Before['owned']) { Add-WinPkgsOwned -Context $Context -Backend 'services' -Id $name }
}

function Format-WinPkgsServiceChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $wanted = Get-WinPkgsServiceWanted -Properties $Properties
    if (-not $Current['exists']) {
        return "not present -> $($wanted['type']), $($wanted['startType']): $($wanted['command'])"
    }
    $parts = @()
    foreach ($d in (Get-WinPkgsServiceDifferences -Wanted $wanted -Current $Current)) {
        switch ($d) {
            'command' { $parts += "command $($Current['command']) -> $($wanted['command'])" }
            'startType' { $parts += "$($Current['startType']) -> $($wanted['startType'])" }
            'failureActions' { $parts += 'failure actions' }
            default { $parts += $d }
        }
    }
    $stale = @(@($Current['instances']) | Where-Object { $_ -and (Get-WinPkgsServiceDifferences -Wanted $wanted -Current $_ -Instance).Count -gt 0 })
    if ($stale.Count -gt 0) { $parts += "$($stale.Count) instance(s) out of date" }
    if ($null -ne $Properties['revision'] -and [string]$Properties['revision'] -cne [string]$Current['revision']) { $parts += 'new revision (restarts it)' }
    return ($parts -join '; ')
}

Register-WinPkgsResource -Type 'winpkgs/service' `
    -Get 'Get-WinPkgsService' -Test 'Test-WinPkgsService' -Set 'Set-WinPkgsService' `
    -Restore 'Restore-WinPkgsService' -Describe 'Format-WinPkgsServiceChange'
