# winpkgs/task against a stand-in. WINPKGS_TASK_ROOT is a directory that plays
# the Task Scheduler: registering a task takes elevation, and a test suite has
# no business registering one on the machine it runs on. What the stand-in
# cannot show is the COM API itself; the last Describe asks the real Task
# Scheduler to check every shape of definition the resource writes, which
# registers nothing and needs no elevation.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $env:WINPKGS_TASK_ROOT = Join-Path $TestDrive 'tasks'
    $env:WINPKGS_TASK_LOG = Join-Path $TestDrive 'tasks.log'
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    function Reset-Scheduler {
        Remove-Item -LiteralPath $env:WINPKGS_TASK_ROOT -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $env:WINPKGS_TASK_ROOT | Out-Null
        Remove-Item -LiteralPath $env:WINPKGS_TASK_LOG -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $env:WINPKGS_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    function Get-Log {
        if (Test-Path -LiteralPath $env:WINPKGS_TASK_LOG) { return @(Get-Content -LiteralPath $env:WINPKGS_TASK_LOG) }
        return @()
    }

    function File([string]$Path, [string]$Name, [string]$Extension) {
        [System.IO.Path]::Combine($env:WINPKGS_TASK_ROOT, $Path.Trim('\'), "$Name$Extension")
    }

    # A task as Windows keeps it: its XML, and its descriptor.
    function New-FakeTask([string]$Path = '\', [string]$Name, [string]$Xml, [string]$Sddl) {
        $file = File $Path $Name '.xml'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        [System.IO.File]::WriteAllText($file, $Xml)
        if ($Sddl) { [System.IO.File]::WriteAllText((File $Path $Name '.sddl'), $Sddl) }
    }

    function Stored([string]$Path = '\', [string]$Name = 'winpkgs-test-task') {
        [System.IO.File]::ReadAllText((File $Path $Name '.sddl'))
    }

    $script:ReadOnlySddl = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)'

    # The definition a 25H2 VM was given on 2026-09-14 ...
    function Props([hashtable]$Override = @{}) {
        $p = @{
            path = '\'; name = 'winpkgs-test-task'
            description = 'winpkgs test task'; author = 'winpkgs'
            command = 'C:\Windows\System32\cmd.exe'; arguments = '/c exit 0'; workingDirectory = $null
            runAs = 'S-1-5-18'; logonType = 'serviceAccount'; runLevel = 'highest'
            triggers = @(@{ type = 'logon'; user = $null; delay = $null; enabled = $true })
            enabled = $true; multipleInstances = 'queue'
            disallowStartIfOnBatteries = $false; stopIfGoingOnBatteries = $false; startWhenAvailable = $false
            allowStartOnDemand = $true; executionTimeLimit = 'PT3M'
            securityDescriptor = $ReadOnlySddl
        }
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        return $p
    }

    # ... and what it kept, word for word: settings at their defaults left out,
    # its own order, the descriptor echoed, a logon trigger with nothing in it.
    $script:KeptXml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <SecurityDescriptor>D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)</SecurityDescriptor>
    <Author>winpkgs</Author>
    <Description>winpkgs test task</Description>
    <URI>\winpkgs-test-task</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Triggers>
    <LogonTrigger />
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\cmd.exe</Command>
      <Arguments>/c exit 0</Arguments>
    </Exec>
  </Actions>
</Task>
'@
    # Its descriptor: the declared entries, what the root folder handed down,
    # and read access Windows added for SYSTEM, the account it runs as.
    $script:KeptSddl = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)(A;ID;0x1f019f;;;BA)(A;ID;0x1f019f;;;SY)(A;ID;FA;;;BA)(A;;FR;;;SY)'

    function Owning([string[]]$Paths) {
        $state = Read-WinPkgsState -Kind system
        $state['owned']['scheduledTasks'] = @($Paths)
        return @{ State = $state; Kind = 'system' }
    }

    # The ledger as an apply leaves it, for a plan to read.
    function Save-State([hashtable]$State) {
        $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
    }

    function Invoke-Task([string]$Operation, [hashtable]$Properties, [hashtable]$Current, [hashtable]$Context = @{ Kind = 'system' }) {
        $args = @{ Type = 'winpkgs/task'; Operation = $Operation; Properties = $Properties; Context = $Context }
        if ($Current) { $args['Current'] = $Current }
        Invoke-WinPkgsResource @args
    }

    function InState([hashtable]$Properties, [hashtable]$Context) {
        Invoke-Task Test $Properties -Current (Invoke-Task Get $Properties -Context $Context) -Context $Context
    }

    function Converge([hashtable]$Properties, [hashtable]$Context) {
        $current = Invoke-Task Get $Properties -Context $Context
        Invoke-Task Set $Properties -Current $current -Context $Context
    }
}

AfterAll {
    foreach ($v in 'WINPKGS_TASK_ROOT', 'WINPKGS_TASK_LOG', 'WINPKGS_STATE_DIR') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

Describe 'winpkgs/task' {
    BeforeEach { Reset-Scheduler }

    Context 'reading a task' {
        It 'reports one that is not there' {
            $c = Invoke-Task Get (Props)
            $c['exists'] | Should -BeFalse
            $c['owned'] | Should -BeFalse
        }

        It 'is in state against what Windows kept for the same definition' {
            New-FakeTask -Name 'winpkgs-test-task' -Xml $KeptXml -Sddl $KeptSddl
            InState (Props) (Owning '\winpkgs-test-task') | Should -BeTrue
        }

        It 'fills in the settings Windows leaves out at their defaults' {
            $read = InModuleScope WinPkgs {
                Read-WinPkgsTaskXml -Xml '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Actions><Exec><Command>x.exe</Command></Exec></Actions></Task>'
            }
            $read['enabled'] | Should -Be 'true'
            $read['disallowStartIfOnBatteries'] | Should -Be 'true'
            $read['stopIfGoingOnBatteries'] | Should -Be 'true'
            $read['allowStartOnDemand'] | Should -Be 'true'
            $read['multipleInstances'] | Should -Be 'ignoreNew'
            $read['executionTimeLimit'] | Should -Be '259200'    # PT72H
            $read['priority'] | Should -Be '7'
            $read['runLevel'] | Should -Be 'limited'
            $read['logonType'] | Should -Be 'serviceAccount'
            $read['triggers'] | Should -Be ''
        }

        It 'reads accounts as SIDs, however they are written' {
            # Windows gives a trigger's user by name when it was given a SID.
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $xml = { param($who, $trigger) "<Task version=`"1.2`" xmlns=`"http://schemas.microsoft.com/windows/2004/02/mit/task`"><Triggers><LogonTrigger><UserId>$trigger</UserId></LogonTrigger></Triggers><Principals><Principal><UserId>$who</UserId></Principal></Principals><Actions><Exec><Command>x.exe</Command></Exec></Actions></Task>" }
            $byName = InModuleScope WinPkgs -Parameters @{ X = (& $xml 'NT AUTHORITY\SYSTEM' $me.Name) } { param($X) Read-WinPkgsTaskXml -Xml $X }
            $bySid = InModuleScope WinPkgs -Parameters @{ X = (& $xml 'S-1-5-18' $me.User.Value) } { param($X) Read-WinPkgsTaskXml -Xml $X }
            $byName['runAs'] | Should -Be 'S-1-5-18'
            $byName['triggers'] | Should -Be $bySid['triggers']
            $bySid['triggers'] | Should -Be "logon, user $($me.User.Value), enabled true"
            (InModuleScope WinPkgs { Resolve-WinPkgsTaskAccount 'LocalService' }) | Should -Be 'S-1-5-19'
        }

        It 'counts what it does not write as a difference' {
            # A start boundary on the trigger, a second action: someone else's edits.
            $bounded = $KeptXml.Replace('<LogonTrigger />', '<LogonTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary></LogonTrigger>')
            New-FakeTask -Name 'winpkgs-test-task' -Xml $bounded -Sddl $KeptSddl
            InState (Props) (Owning '\winpkgs-test-task') | Should -BeFalse
            $twice = $KeptXml.Replace('</Exec>', '</Exec><Exec><Command>C:\evil.exe</Command></Exec>')
            New-FakeTask -Name 'winpkgs-test-task' -Xml $twice -Sddl $KeptSddl
            InState (Props) (Owning '\winpkgs-test-task') | Should -BeFalse
        }

        It 'reports a task it may not read, and never counts it as in state' {
            New-FakeTask -Name 'winpkgs-test-task' -Xml $KeptXml -Sddl $KeptSddl
            New-Item -ItemType File -Path (File '\' 'winpkgs-test-task' '.denied') | Out-Null
            $ctx = Owning '\winpkgs-test-task'
            $c = Invoke-Task Get (Props) -Context $ctx
            $c['exists'] | Should -BeTrue
            $c['readable'] | Should -BeFalse
            Invoke-Task Test (Props) -Current $c -Context $ctx | Should -BeFalse
            Invoke-Task Describe (Props) -Current $c | Should -Be 'cannot be read without elevation; compared when applied'
        }

        It 'reads ownership from the ledger on disk during a plan' {
            $ctx = Owning '\winpkgs-test-task'
            Save-State $ctx['State']
            New-FakeTask -Name 'winpkgs-test-task' -Xml $KeptXml -Sddl $KeptSddl
            (Invoke-Task Get (Props) -Context @{ Kind = 'system' })['owned'] | Should -BeTrue
        }
    }

    Context 'the security descriptor' {
        BeforeEach {
            $script:Equal = {
                param([string]$Expected, [string]$Actual, [string]$RunAs = 'S-1-5-18')
                InModuleScope WinPkgs -Parameters @{ E = $Expected; A = $Actual; R = $RunAs } {
                    param($E, $A, $R)
                    Test-WinPkgsTaskSecurityEqual -Expected $E -Actual $A -RunAsSid $R
                }
            }
        }

        It 'leaves out what Windows adds: what the folder hands down, and read for the account the task runs as' {
            & $Equal $ReadOnlySddl $KeptSddl | Should -BeTrue
            # A group principal's read entry, as on a task that runs as Users.
            & $Equal 'D:(A;;FA;;;BA)' 'D:(A;;FA;;;BA)(A;ID;0x1f019f;;;SY)(A;;FR;;;BU)' 'S-1-5-32-545' | Should -BeTrue
        }

        It 'tells read-and-execute from write by the mask, not by the name of a right' {
            # ConvertFrom-SddlString lists "GenericWrite" for 0x1200a9, which
            # has no write bit; a test written on its names would pass here.
            # The same entries, the same trustees; only AU's mask differs.
            & $Equal $ReadOnlySddl 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1f019f;;;AU)' | Should -BeFalse
            & $Equal 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1f019f;;;AU)' $ReadOnlySddl | Should -BeFalse
            & $Equal $ReadOnlySddl ($KeptSddl + '(A;;FW;;;AU)') | Should -BeFalse
        }

        It 'reads trustees as SIDs and rights as masks, however they are spelled' {
            & $Equal $ReadOnlySddl 'D:(A;;0x1f01ff;;;S-1-5-32-544)(A;;FA;;;S-1-5-18)(A;;FRFX;;;S-1-5-11)' | Should -BeTrue
            # Generic rights mean the file rights they map to.
            & $Equal 'D:(A;;GA;;;BA)(A;;GRGX;;;AU)' 'D:(A;;FA;;;BA)(A;;0x1200a9;;;AU)' 'S-1-5-18' | Should -BeTrue
        }

        It 'forgives read only for the account the task runs as, and only read' {
            & $Equal $ReadOnlySddl ($ReadOnlySddl + '(A;;FR;;;BU)') | Should -BeFalse
            & $Equal $ReadOnlySddl ($ReadOnlySddl + '(A;;FA;;;SY)(A;;FA;;;SY)') | Should -BeFalse
            # Declared, it is compared like any other entry.
            & $Equal ($ReadOnlySddl + '(A;;FR;;;SY)') $KeptSddl | Should -BeTrue
        }

        It 'counts a protected descriptor as different from one that inherits' {
            & $Equal 'D:P(A;;FA;;;BA)' 'D:(A;;FA;;;BA)(A;ID;FA;;;SY)' | Should -BeFalse
            & $Equal 'D:P(A;;FA;;;BA)' 'D:PAI(A;;FA;;;BA)' | Should -BeTrue
        }
    }

    Context 'creating one' {
        It 'registers it with its descriptor, owns it, and says so' {
            $ctx = Owning @()
            Converge (Props) $ctx
            Get-Log | Should -Be @('register \winpkgs-test-task')
            @($ctx['State']['owned']['scheduledTasks']) | Should -Be @('\winpkgs-test-task')
            Stored | Should -Be 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)(A;ID;0x1f019f;;;BA)(A;ID;0x1f019f;;;SY)(A;;FR;;;S-1-5-18)'
            InState (Props) $ctx | Should -BeTrue
        }

        It 'writes the settings Windows gets wrong by default' {
            Converge (Props) (Owning @())
            $xml = [System.IO.File]::ReadAllText((File '\' 'winpkgs-test-task' '.xml'))
            $xml | Should -Match '<MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>'
            $xml | Should -Match '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
            # A logon trigger for every user: no UserId in it.
            $xml | Should -Match '<LogonTrigger><Enabled>true</Enabled></LogonTrigger>'
        }

        It 'puts it in its folder' {
            $p = Props @{ path = '\winpkgs\sub\'; name = 'nested' }
            $ctx = Owning @()
            Converge $p $ctx
            Test-Path -LiteralPath (File '\winpkgs\sub\' 'nested' '.xml') | Should -BeTrue
            @($ctx['State']['owned']['scheduledTasks']) | Should -Be @('\winpkgs\sub\nested')
        }

        It 'refuses a descriptor that is not SDDL, before registering anything' {
            { Converge (Props @{ securityDescriptor = 'D:(A;;FA;;;NOTASID)' }) (Owning @()) } | Should -Throw '*not valid SDDL*'
            Get-Log | Should -Be @()
        }
    }

    Context 'changing one' {
        It 'registers an owned task again when it differs, and is then in state' {
            $ctx = Owning @()
            Converge (Props) $ctx
            $p = Props @{ multipleInstances = 'parallel'; arguments = '/c exit 1' }
            InState $p $ctx | Should -BeFalse
            Converge $p $ctx
            InState $p $ctx | Should -BeTrue
            Get-Log | Should -Be @('register \winpkgs-test-task', 'register \winpkgs-test-task')
        }

        It 'changes the descriptor' {
            $ctx = Owning @()
            Converge (Props) $ctx
            $open = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1f019f;;;AU)'
            Converge (Props @{ securityDescriptor = $open }) $ctx
            Stored | Should -BeLike 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1f019f;;;AU)*'
            InState (Props) $ctx | Should -BeFalse
        }

        It 'does not compare a descriptor that is not declared, nor change it' {
            $ctx = Owning @()
            Converge (Props) $ctx
            InState (Props @{ securityDescriptor = $null }) $ctx | Should -BeTrue
            Converge (Props @{ securityDescriptor = $null; arguments = '/c exit 2' }) $ctx
            Stored | Should -BeLike 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)*'
        }

        It 'refuses a task it did not create, and registers nothing' {
            New-FakeTask -Name 'winpkgs-test-task' -Xml $KeptXml -Sddl $KeptSddl
            $ctx = Owning @()
            InState (Props @{ arguments = '/c whoami' }) $ctx | Should -BeFalse
            { Converge (Props @{ arguments = '/c whoami' }) $ctx } | Should -Throw '*winpkgs did not create it*'
            Get-Log | Should -Be @()
            @($ctx['State']['owned']['scheduledTasks']) | Should -Be @()
        }
    }

    Context 'prune' {
        It 'deletes a task it created, and forgets owning it' {
            $ctx = Owning @()
            Converge (Props) $ctx
            Invoke-Task Remove @{ path = '\'; name = 'winpkgs-test-task' } -Context $ctx
            Test-Path -LiteralPath (File '\' 'winpkgs-test-task' '.xml') | Should -BeFalse
            @($ctx['State']['owned']['scheduledTasks']) | Should -Be @()
            Get-Log | Should -Be @('register \winpkgs-test-task', 'delete \winpkgs-test-task')
        }

        It 'forgets owning one that is already gone' {
            $ctx = Owning '\winpkgs-test-task'
            Invoke-Task Remove @{ path = '\'; name = 'winpkgs-test-task' } -Context $ctx
            @($ctx['State']['owned']['scheduledTasks']) | Should -Be @()
        }

        It 'plans a remove for an owned task the document no longer declares, and only that' {
            Save-State (Owning '\winpkgs-test-task', '\kept', '\steward\gone')['State']
            $doc = @{
                kind = 'system'; root = $TestDrive
                settings = @{ prune = @{ winget = $false; files = $false; services = $false; scheduledTasks = $true } }
                resources = @(@{ type = 'winpkgs/task'; id = 'Task \kept'; scope = 'machine'; properties = (Props @{ name = 'kept' }) })
            }
            $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove' | Sort-Object Id)
            @($removes.Id) | Should -Be @('Task \steward\gone', 'Task \winpkgs-test-task')
            $removes[0].Resource['properties']['path'] | Should -Be '\steward\'
            $removes[0].Resource['properties']['name'] | Should -Be 'gone'
            $doc['settings']['prune']['scheduledTasks'] = $false
            @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
        }
    }

    Context 'what a plan says' {
        It 'describes a new task, and the parts of one that change' {
            Invoke-Task Describe (Props) -Current @{ exists = $false } |
                Should -Be 'not present -> C:\Windows\System32\cmd.exe /c exit 0, at any user''s logon, as S-1-5-18'
            $ctx = Owning @()
            Converge (Props) $ctx
            $p = Props @{ multipleInstances = 'parallel'; command = 'C:\other.exe'; securityDescriptor = 'D:(A;;FA;;;BA)' }
            Invoke-Task Describe $p -Current (Invoke-Task Get $p -Context $ctx) |
                Should -Be 'command C:\Windows\System32\cmd.exe -> C:\other.exe; multipleInstances queue -> parallel; security descriptor'
            $p = Props @{ triggers = @(@{ type = 'boot'; delay = 'PT30S'; enabled = $true }) }
            Invoke-Task Describe $p -Current (Invoke-Task Get $p -Context $ctx) | Should -Be 'triggers -> at boot (after PT30S)'
            $p = Props @{ workingDirectory = 'C:\' }
            Invoke-Task Describe $p -Current (Invoke-Task Get $p -Context $ctx) | Should -Be 'working directory'
        }

        It 'says when it would refuse' {
            New-FakeTask -Name 'winpkgs-test-task' -Xml $KeptXml -Sddl $KeptSddl
            Invoke-Task Describe (Props) -Current (Invoke-Task Get (Props) -Context (Owning @())) |
                Should -Be 'exists, and winpkgs did not create it: refused'
        }
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/task'
    }
}

# The stand-in takes any XML. Validation by the Task Scheduler itself registers
# nothing and needs no elevation, so every shape the resource writes is put to it.
Describe 'winpkgs/task: the Task Scheduler' {
    BeforeAll {
        $script:Validate = {
            param([hashtable]$Properties)
            $saved = $env:WINPKGS_TASK_ROOT
            try {
                $env:WINPKGS_TASK_ROOT = $null
                InModuleScope WinPkgs -Parameters @{ P = $Properties } { param($P) Save-WinPkgsTaskRegistration -Properties $P -ValidateOnly }
            } finally { $env:WINPKGS_TASK_ROOT = $saved }
        }
        $script:Me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }

    It 'accepts SYSTEM at every user''s logon, with a descriptor' {
        { & $Validate (Props) } | Should -Not -Throw
    }

    It 'accepts a group at boot, after a delay, with no descriptor' {
        { & $Validate (Props @{ runAs = 'S-1-5-32-545'; logonType = 'group'; runLevel = 'limited'; securityDescriptor = $null
                                triggers = @(@{ type = 'boot'; delay = 'PT30S'; enabled = $true }) }) } | Should -Not -Throw
    }

    It 'accepts a user, signed in or not, at their own logon, in a directory' {
        { & $Validate (Props @{ runAs = $Me; logonType = 'interactiveToken'; runLevel = 'limited'; workingDirectory = 'C:\'
                                triggers = @(@{ type = 'logon'; user = $Me; enabled = $false }) }) } | Should -Not -Throw
        { & $Validate (Props @{ runAs = $Me; logonType = 's4u'; runLevel = 'limited'; triggers = @() }) } | Should -Not -Throw
    }

    It 'accepts a service account by name, and every instance policy' {
        foreach ($m in 'parallel', 'queue', 'ignoreNew', 'stopExisting') {
            { & $Validate (Props @{ runAs = 'NT AUTHORITY\LocalService'; multipleInstances = $m; executionTimeLimit = 'PT0S' }) } | Should -Not -Throw
        }
    }

    It 'rejects what it would not register, so the checks above mean something' {
        { & $Validate (Props @{ executionTimeLimit = 'three minutes' }) } | Should -Throw
    }
}
