<#
    winpkgs/task - a scheduled task winpkgs defines, and that it exists.
    Machine scope.

    properties:
      path, name        the folder (ending in a backslash) and the task's name
      command           the program the task runs, unquoted
      arguments, workingDirectory
                        $null: none
      description, author
                        $null: none
      runAs             the account or group the task runs as, a SID or a name
      logonType         serviceAccount | interactiveToken | s4u | group: how it
                        runs as that account without a password
      runLevel          limited | highest
      triggers          @(@{ type = 'logon' | 'boot'; user; delay; enabled });
                        a logon trigger with no user fires for every user
      enabled           whether it may run
      multipleInstances parallel | queue | ignoreNew | stopExisting: what a
                        start does while the task is still running
      disallowStartIfOnBatteries, stopIfGoingOnBatteries, startWhenAvailable,
      allowStartOnDemand
      executionTimeLimit
                        an ISO 8601 duration; PT0S is none
      securityDescriptor
                        $null leaves it alone, or the task's discretionary ACL
                        in SDDL: who may read, run, change and delete it

    The definition is rendered as Task Scheduler XML and registered through
    the Task Scheduler's COM API (ITaskFolder::RegisterTask, create or update),
    which takes the security descriptor in the same call. A task that runs as
    SYSTEM and that users may rewrite lets them run anything as SYSTEM, so the
    descriptor must not arrive a step after the definition; schtasks.exe has
    no way to set one at all. What the XML says beyond the properties is fixed
    at Windows' defaults: no idle conditions, no network condition, priority 7.

    Windows hands back the XML it keeps rather than the XML it was given: it
    leaves out settings at their defaults, names a trigger's user where it was
    given a SID, and orders elements its own way. So both are read into the
    same fields, Windows' defaults filled in and accounts resolved to SIDs,
    and compared there. A security descriptor is compared by its explicit
    entries, by rights mask and SID, since Windows adds to what it is given:
    the entries the folder hands down, and read access for the task's own
    account (both seen on every task on the machine this was written on). A
    right is never compared by its name -- ConvertFrom-SddlString reports
    0x1200a9, read and execute, as including GenericWrite.

    Reading a task needs read access to it. A plan runs unelevated, and a
    task that the user may not read -- Windows' default for one in the root
    folder -- cannot be compared until the elevated apply, so every plan
    counts it as a change. A descriptor that lets users read it avoids that.

    A task winpkgs created is owned (the ledger's `scheduledTasks`, by full
    path) and deleted once it leaves the configuration. One that already
    exists and that winpkgs did not create is refused: the tasks already on a
    machine are Windows' or an application's, and a definition would replace
    them. Turning one of those on or off is winpkgs/scheduledTask's.

    WINPKGS_TASK_ROOT names a directory that stands in for the Task Scheduler
    (tests): task \A\B\name is <root>\A\B\name.xml, its descriptor name.sddl
    beside it, stored as Windows stores one; a name.denied file makes reading
    the task fail as access denied does. WINPKGS_TASK_LOG records every
    registration and deletion.
#>

$script:TaskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$script:TaskLogonTypes = @{ s4u = 2; interactiveToken = 3; group = 4; serviceAccount = 5 }
$script:TaskMultipleInstances = @{ parallel = 'Parallel'; queue = 'Queue'; ignoreNew = 'IgnoreNew'; stopExisting = 'StopExisting' }
# SYSTEM, LOCAL SERVICE, NETWORK SERVICE: the accounts a task runs as with no
# password and no session.
$script:TaskServiceAccounts = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$script:TaskAccountAliases = @{ system = 'S-1-5-18'; localsystem = 'S-1-5-18'; localservice = 'S-1-5-19'; networkservice = 'S-1-5-20' }
# ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, E_ACCESSDENIED as HRESULTs.
$script:TaskNotFound = @(-2147024894, -2147024893)
$script:TaskAccessDenied = -2147024891

# What the plan compares, and says, in this order.
$script:TaskFields = @(
    'actions', 'triggers', 'runAs', 'logonType', 'runLevel', 'enabled', 'description', 'author',
    'multipleInstances', 'disallowStartIfOnBatteries', 'stopIfGoingOnBatteries', 'startWhenAvailable',
    'allowStartOnDemand', 'executionTimeLimit', 'allowHardTerminate', 'runOnlyIfNetworkAvailable',
    'runOnlyIfIdle', 'wakeToRun', 'hidden', 'priority'
)

function Get-WinPkgsTaskFullPath {
    param([Parameter(Mandatory)][hashtable]$Properties)
    return ([string]$Properties['path']) + ([string]$Properties['name'])
}

function Split-WinPkgsTaskFullPath {
    # "\A\B\name" -> folder "\A\B\", name "name".
    param([Parameter(Mandatory)][string]$FullPath)
    $at = $FullPath.LastIndexOf('\')
    return @{ path = $FullPath.Substring(0, $at + 1); name = $FullPath.Substring($at + 1) }
}

function Resolve-WinPkgsTaskAccount {
    # An account or group as a SID, however it is written; one that does not
    # resolve, as written, lower-cased.
    param([string]$Account)
    if ([string]::IsNullOrEmpty($Account)) { return '' }
    if ($Account -match '^S-1-') { return $Account.ToUpperInvariant() }
    $alias = (($Account -replace '^NT AUTHORITY\\', '') -replace ' ', '').ToLowerInvariant()
    if ($script:TaskAccountAliases.ContainsKey($alias)) { return $script:TaskAccountAliases[$alias] }
    try {
        return (New-Object System.Security.Principal.NTAccount $Account).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $Account.ToLowerInvariant()
    }
}

function ConvertTo-WinPkgsTaskSeconds {
    # An ISO 8601 duration as seconds, so PT3M and PT180S are one limit.
    param([string]$Duration)
    if ([string]::IsNullOrEmpty($Duration)) { return '' }
    try { return [string][int64][System.Xml.XmlConvert]::ToTimeSpan($Duration).TotalSeconds }
    catch { return $Duration }
}

function Get-WinPkgsTaskHResult {
    # The HRESULT of a failed COM call, however PowerShell wrapped it.
    param([Parameter(Mandatory)]$ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e -is [System.Runtime.InteropServices.COMException]) { return $e.HResult }
        $e = $e.InnerException
    }
    return $ErrorRecord.Exception.HResult
}

# --- the XML ------------------------------------------------------------------------

function Add-WinPkgsTaskElement {
    param([Parameter(Mandatory)]$Parent, [Parameter(Mandatory)][string]$Name, $Value)
    $e = $Parent.OwnerDocument.CreateElement($Name, $script:TaskNamespace)
    if ($Value -is [bool]) { $Value = if ($Value) { 'true' } else { 'false' } }
    if ($null -ne $Value) { $e.InnerText = [string]$Value }
    return $Parent.AppendChild($e)
}

function ConvertTo-WinPkgsTaskXml {
    # The declared definition as Task Scheduler XML, schema 1.2.
    param([Parameter(Mandatory)][hashtable]$Properties)
    $full = Get-WinPkgsTaskFullPath -Properties $Properties
    $doc = New-Object System.Xml.XmlDocument
    $task = $doc.AppendChild($doc.CreateElement('Task', $script:TaskNamespace))
    $task.SetAttribute('version', '1.2')

    $info = Add-WinPkgsTaskElement $task 'RegistrationInfo'
    if ($Properties['author']) { [void](Add-WinPkgsTaskElement $info 'Author' $Properties['author']) }
    if ($Properties['description']) { [void](Add-WinPkgsTaskElement $info 'Description' $Properties['description']) }

    $triggers = Add-WinPkgsTaskElement $task 'Triggers'
    foreach ($t in @($Properties['triggers'])) {
        if ($null -eq $t) { continue }
        $element = switch ([string]$t['type']) {
            'logon' { 'LogonTrigger' }
            'boot' { 'BootTrigger' }
            default { throw "Unknown trigger type '$($t['type'])' for scheduled task $full." }
        }
        $trigger = Add-WinPkgsTaskElement $triggers $element
        $on = if ($null -ne $t['enabled']) { [bool]$t['enabled'] } else { $true }
        [void](Add-WinPkgsTaskElement $trigger 'Enabled' $on)
        if ($t['delay']) { [void](Add-WinPkgsTaskElement $trigger 'Delay' $t['delay']) }
        if ($element -eq 'LogonTrigger' -and $t['user']) { [void](Add-WinPkgsTaskElement $trigger 'UserId' $t['user']) }
    }

    $logon = [string]$Properties['logonType']
    $principal = Add-WinPkgsTaskElement (Add-WinPkgsTaskElement $task 'Principals') 'Principal'
    $principal.SetAttribute('id', 'Author')
    [void](Add-WinPkgsTaskElement $principal $(if ($logon -eq 'group') { 'GroupId' } else { 'UserId' }) $Properties['runAs'])
    # A service account's and a group's logon type is given to RegisterTask,
    # not written: the schema has no word for either.
    if ($logon -eq 'interactiveToken') { [void](Add-WinPkgsTaskElement $principal 'LogonType' 'InteractiveToken') }
    if ($logon -eq 's4u') { [void](Add-WinPkgsTaskElement $principal 'LogonType' 'S4U') }
    [void](Add-WinPkgsTaskElement $principal 'RunLevel' $(if ($Properties['runLevel'] -eq 'highest') { 'HighestAvailable' } else { 'LeastPrivilege' }))

    $multiple = $script:TaskMultipleInstances[[string]$Properties['multipleInstances']]
    if (-not $multiple) { throw "Unknown multipleInstances '$($Properties['multipleInstances'])' for scheduled task $full." }
    $settings = Add-WinPkgsTaskElement $task 'Settings'
    [void](Add-WinPkgsTaskElement $settings 'MultipleInstancesPolicy' $multiple)
    [void](Add-WinPkgsTaskElement $settings 'DisallowStartIfOnBatteries' ([bool]$Properties['disallowStartIfOnBatteries']))
    [void](Add-WinPkgsTaskElement $settings 'StopIfGoingOnBatteries' ([bool]$Properties['stopIfGoingOnBatteries']))
    [void](Add-WinPkgsTaskElement $settings 'AllowHardTerminate' $true)
    [void](Add-WinPkgsTaskElement $settings 'StartWhenAvailable' ([bool]$Properties['startWhenAvailable']))
    [void](Add-WinPkgsTaskElement $settings 'RunOnlyIfNetworkAvailable' $false)
    [void](Add-WinPkgsTaskElement $settings 'AllowStartOnDemand' ([bool]$Properties['allowStartOnDemand']))
    [void](Add-WinPkgsTaskElement $settings 'Enabled' ([bool]$Properties['enabled']))
    [void](Add-WinPkgsTaskElement $settings 'Hidden' $false)
    [void](Add-WinPkgsTaskElement $settings 'RunOnlyIfIdle' $false)
    [void](Add-WinPkgsTaskElement $settings 'WakeToRun' $false)
    [void](Add-WinPkgsTaskElement $settings 'ExecutionTimeLimit' $Properties['executionTimeLimit'])
    [void](Add-WinPkgsTaskElement $settings 'Priority' 7)

    $actions = Add-WinPkgsTaskElement $task 'Actions'
    $actions.SetAttribute('Context', 'Author')
    $exec = Add-WinPkgsTaskElement $actions 'Exec'
    [void](Add-WinPkgsTaskElement $exec 'Command' $Properties['command'])
    if ($Properties['arguments']) { [void](Add-WinPkgsTaskElement $exec 'Arguments' $Properties['arguments']) }
    if ($Properties['workingDirectory']) { [void](Add-WinPkgsTaskElement $exec 'WorkingDirectory' $Properties['workingDirectory']) }

    return $doc.OuterXml
}

function Read-WinPkgsTaskXml {
    <#
        A task's XML as the fields winpkgs compares, all strings: Windows'
        defaults filled in where it leaves a setting out, accounts as SIDs,
        durations as seconds. Whatever winpkgs does not write -- a trigger
        type, an action type, a trigger's start boundary -- is carried as it
        is, so a task that has one never matches a definition.
    #>
    param([Parameter(Mandatory)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $ns = New-Object System.Xml.XmlNamespaceManager $doc.NameTable
    $ns.AddNamespace('t', $script:TaskNamespace)
    $text = {
        param([string]$XPath, [string]$Default)
        $n = $doc.SelectSingleNode($XPath, $ns)
        if ($null -eq $n) { return $Default }
        return $n.InnerText.Trim()
    }
    $flag = { param([string]$XPath, [string]$Default) ([string](& $text $XPath $Default)).ToLowerInvariant() }
    $s = '/t:Task/t:Settings/t:'

    $triggers = foreach ($t in @($doc.SelectNodes('/t:Task/t:Triggers/*', $ns))) {
        $child = { param($n) $c = $t.SelectSingleNode("t:$n", $ns); if ($null -eq $c) { $null } else { $c.InnerText.Trim() } }
        $on = & $child 'Enabled'
        $on = if ($null -eq $on) { 'true' } else { $on.ToLowerInvariant() }
        $delay = ConvertTo-WinPkgsTaskSeconds (& $child 'Delay')
        $rest = @(if ($delay -and $delay -ne '0') { "delay ${delay}s" })
        $rest += "enabled $on"
        $rest += @($t.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -notin 'Enabled', 'Delay', 'UserId' } |
            ForEach-Object { "$($_.LocalName) $($_.InnerText.Trim())" })
        switch ($t.LocalName) {
            'LogonTrigger' {
                $user = & $child 'UserId'
                $who = if ($user) { "user $(Resolve-WinPkgsTaskAccount $user)" } else { 'any user' }
                (@("logon", $who) + $rest) -join ', '
            }
            'BootTrigger' { (@('boot') + $rest) -join ', ' }
            default { "$($t.LocalName): $($t.InnerXml)" }
        }
    }

    $command = ''; $arguments = ''; $directory = ''
    $actions = foreach ($a in @($doc.SelectNodes('/t:Task/t:Actions/*', $ns))) {
        if ($a.LocalName -ne 'Exec') { "$($a.LocalName): $($a.InnerXml)"; continue }
        $part = { param($n) $c = $a.SelectSingleNode("t:$n", $ns); if ($null -eq $c) { '' } else { $c.InnerText.Trim() } }
        if (-not $command) { $command = & $part 'Command'; $arguments = & $part 'Arguments'; $directory = & $part 'WorkingDirectory' }
        "exec $(& $part 'Command') | $(& $part 'Arguments') | $(& $part 'WorkingDirectory')"
    }

    $group = & $text '/t:Task/t:Principals/t:Principal/t:GroupId' ''
    $user = & $text '/t:Task/t:Principals/t:Principal/t:UserId' ''
    $runAs = Resolve-WinPkgsTaskAccount $(if ($group) { $group } else { $user })
    $logon = if ($group) { 'group' }
        elseif ($script:TaskServiceAccounts -contains $runAs) { 'serviceAccount' }
        else {
            switch (& $text '/t:Task/t:Principals/t:Principal/t:LogonType' '') {
                'S4U' { 's4u' }
                'Password' { 'password' }
                'InteractiveTokenOrPassword' { 'interactiveTokenOrPassword' }
                default { 'interactiveToken' }
            }
        }

    $multiple = & $text "${s}MultipleInstancesPolicy" 'IgnoreNew'
    foreach ($k in $script:TaskMultipleInstances.Keys) { if ($script:TaskMultipleInstances[$k] -eq $multiple) { $multiple = $k } }

    return @{
        description                = & $text '/t:Task/t:RegistrationInfo/t:Description' ''
        author                     = & $text '/t:Task/t:RegistrationInfo/t:Author' ''
        command                    = $command
        arguments                  = $arguments
        workingDirectory           = $directory
        actions                    = @($actions) -join '; '
        triggers                   = @($triggers) -join '; '
        runAs                      = $runAs
        logonType                  = $logon
        runLevel                   = if ((& $text '/t:Task/t:Principals/t:Principal/t:RunLevel' '') -eq 'HighestAvailable') { 'highest' } else { 'limited' }
        enabled                    = & $flag "${s}Enabled" 'true'
        multipleInstances          = $multiple
        disallowStartIfOnBatteries = & $flag "${s}DisallowStartIfOnBatteries" 'true'
        stopIfGoingOnBatteries     = & $flag "${s}StopIfGoingOnBatteries" 'true'
        startWhenAvailable         = & $flag "${s}StartWhenAvailable" 'false'
        allowStartOnDemand         = & $flag "${s}AllowStartOnDemand" 'true'
        executionTimeLimit         = ConvertTo-WinPkgsTaskSeconds (& $text "${s}ExecutionTimeLimit" 'PT72H')
        allowHardTerminate         = & $flag "${s}AllowHardTerminate" 'true'
        runOnlyIfNetworkAvailable  = & $flag "${s}RunOnlyIfNetworkAvailable" 'false'
        runOnlyIfIdle              = & $flag "${s}RunOnlyIfIdle" 'false'
        wakeToRun                  = & $flag "${s}WakeToRun" 'false'
        hidden                     = & $flag "${s}Hidden" 'false'
        priority                   = & $text "${s}Priority" '7'
    }
}

# --- the security descriptor -------------------------------------------------------

function ConvertTo-WinPkgsTaskMask {
    # A rights mask with its generic rights mapped to the file rights they
    # stand for, which is how Windows keeps a task's.
    param([int64]$Mask)
    $m = $Mask -band [int64]4294967295
    $mapped = $m -band [int64]268435455
    if ($m -band [int64]2147483648) { $mapped = $mapped -bor 0x120089 }   # GENERIC_READ -> FR
    if ($m -band [int64]1073741824) { $mapped = $mapped -bor 0x120116 }   # GENERIC_WRITE -> FW
    if ($m -band [int64]536870912) { $mapped = $mapped -bor 0x1200A0 }    # GENERIC_EXECUTE -> FX
    if ($m -band [int64]268435456) { $mapped = $mapped -bor 0x1F01FF }    # GENERIC_ALL -> FA
    return $mapped
}

function Get-WinPkgsTaskAces {
    # A DACL's own entries -- not what the folder hands down -- as
    # "kind flags mask SID" strings, sorted, and whether it is protected.
    param([Parameter(Mandatory)][string]$Sddl)
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor -ArgumentList @($Sddl)
    # As integers: Windows PowerShell will not cast these enums to a bool.
    $inherited = [int][System.Security.AccessControl.AceFlags]::Inherited
    $aces = @(foreach ($ace in @($sd.DiscretionaryAcl)) {
        if ($null -eq $ace -or ([int]$ace.AceFlags -band $inherited) -ne 0) { continue }
        if ($ace -is [System.Security.AccessControl.CommonAce]) {
            '{0} {1} 0x{2:x} {3}' -f $ace.AceQualifier, [int]$ace.AceFlags, (ConvertTo-WinPkgsTaskMask $ace.AccessMask), $ace.SecurityIdentifier.Value
        } else {
            "$($ace.AceType) $([int]$ace.AceFlags)"
        }
    })
    $protected = ([int]$sd.ControlFlags -band [int][System.Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
    return @{ protected = $protected; aces = @($aces | Sort-Object) }
}

function Test-WinPkgsTaskSecurityEqual {
    <#
        Whether a task's descriptor is the declared one, by meaning: the same
        explicit entries, rights compared as masks and trustees as SIDs. What
        Windows adds itself is left out of the comparison -- the entries the
        folder hands down, and read access for the account the task runs as.
    #>
    param([Parameter(Mandatory)][string]$Expected, [string]$Actual, [string]$RunAsSid)
    if ([string]::IsNullOrEmpty($Actual)) { return $false }
    $e = Get-WinPkgsTaskAces -Sddl $Expected
    $a = Get-WinPkgsTaskAces -Sddl $Actual
    if ($e['protected'] -ne $a['protected']) { return $false }
    $has = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in $a['aces']) { $has.Add($x) }
    $added = 'AccessAllowed 0 0x120089 ' + $RunAsSid
    if ($RunAsSid -and $e['aces'] -notcontains $added) { [void]$has.Remove($added) }
    return ((@($e['aces']) -join "`n") -ceq (@($has) -join "`n"))
}

# --- the Task Scheduler, or its stand-in ---------------------------------------------

function Write-WinPkgsTaskLog {
    param([string]$Line)
    if ($env:WINPKGS_TASK_LOG) { Add-Content -LiteralPath $env:WINPKGS_TASK_LOG -Value $Line }
}

function Get-WinPkgsTaskStandInPath {
    param([string]$Path, [string]$Name, [string]$Extension)
    return [System.IO.Path]::Combine($env:WINPKGS_TASK_ROOT, $Path.Trim('\'), "$Name$Extension")
}

function Connect-WinPkgsTaskScheduler {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    return $scheduler
}

function Get-WinPkgsTaskFolder {
    # A folder by path, "\" for the root; -Create makes what is missing.
    param([Parameter(Mandatory)]$Scheduler, [Parameter(Mandatory)][string]$Path, [switch]$Create)
    $folder = $Scheduler.GetFolder('\')
    foreach ($segment in @($Path.Split('\') | Where-Object { $_ })) {
        try { $folder = $folder.GetFolder($segment) }
        catch {
            if (-not $Create -or (Get-WinPkgsTaskHResult $_) -notin $script:TaskNotFound) { throw }
            $folder = $folder.CreateFolder($segment, $null)
        }
    }
    return $folder
}

function Read-WinPkgsTaskRegistration {
    # $null if there is no such task, @{ denied = $true } if it may not be
    # read, else @{ xml; securityDescriptor } -- the descriptor only when asked.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [switch]$WithSecurity)
    if ($env:WINPKGS_TASK_ROOT) {
        if (Test-Path -LiteralPath (Get-WinPkgsTaskStandInPath $Path $Name '.denied')) { return @{ denied = $true } }
        $file = Get-WinPkgsTaskStandInPath $Path $Name '.xml'
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        $read = @{ xml = [System.IO.File]::ReadAllText($file) }
        if ($WithSecurity) {
            $sddl = Get-WinPkgsTaskStandInPath $Path $Name '.sddl'
            $read['securityDescriptor'] = if (Test-Path -LiteralPath $sddl) { [System.IO.File]::ReadAllText($sddl).Trim() } else { $null }
        }
        return $read
    }
    $scheduler = Connect-WinPkgsTaskScheduler
    try {
        $task = (Get-WinPkgsTaskFolder -Scheduler $scheduler -Path $Path).GetTask($Name)
        $read = @{ xml = [string]$task.Xml }
        # DACL_SECURITY_INFORMATION; needs READ_CONTROL, as reading the task does.
        if ($WithSecurity) { $read['securityDescriptor'] = [string]$task.GetSecurityDescriptor(4) }
        return $read
    } catch {
        $hr = Get-WinPkgsTaskHResult $_
        if ($hr -in $script:TaskNotFound) { return $null }
        if ($hr -eq $script:TaskAccessDenied) { return @{ denied = $true } }
        throw
    }
}

function Save-WinPkgsTaskRegistration {
    <#
        Register a task, or replace one's definition, in one call with its
        descriptor ($null leaves it as Windows has it). -ValidateOnly asks the
        Task Scheduler itself to check the definition and registers nothing,
        which needs no elevation; the stand-in never does that part.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Properties,
        [switch]$ValidateOnly
    )
    $path = [string]$Properties['path']
    $name = [string]$Properties['name']
    $xml = ConvertTo-WinPkgsTaskXml -Properties $Properties
    $logon = $script:TaskLogonTypes[[string]$Properties['logonType']]
    if (-not $logon) { throw "Unknown logon type '$($Properties['logonType'])' for scheduled task $path$name." }
    # Untyped: a [string] would turn $null into "", which is a descriptor.
    $sddl = $Properties['securityDescriptor']
    if ($null -ne $sddl) {
        # The Task Scheduler's own check of a definition does not look at it.
        try { [void](New-Object System.Security.AccessControl.RawSecurityDescriptor -ArgumentList @([string]$sddl)) }
        catch { throw "Scheduled task ${path}${name}: the security descriptor '$sddl' is not valid SDDL." }
    }

    if ($env:WINPKGS_TASK_ROOT -and -not $ValidateOnly) {
        Write-WinPkgsTaskLog "register $path$name"
        $file = Get-WinPkgsTaskStandInPath $path $name '.xml'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        [System.IO.File]::WriteAllText($file, $xml)
        # As Windows keeps one: the declared entries, what the root folder
        # hands down, and read access for the account the task runs as.
        $sddlFile = Get-WinPkgsTaskStandInPath $path $name '.sddl'
        if ($null -ne $sddl -or -not (Test-Path -LiteralPath $sddlFile)) {
            $own = if ($null -ne $sddl) { ([string]$sddl).Substring(2) } else { '' }
            $handedDown = if ($own.StartsWith('P')) { '' } else { '(A;ID;0x1f019f;;;BA)(A;ID;0x1f019f;;;SY)' }
            $runAs = Resolve-WinPkgsTaskAccount ([string]$Properties['runAs'])
            [System.IO.File]::WriteAllText($sddlFile, "D:$own$handedDown(A;;FR;;;$runAs)")
        }
        return
    }

    $scheduler = Connect-WinPkgsTaskScheduler
    # TASK_VALIDATE_ONLY, or TASK_CREATE_OR_UPDATE. No password: every logon
    # type here takes none.
    if ($ValidateOnly) {
        $folder = $scheduler.GetFolder('\')
        $flags = 1
    } else {
        $folder = Get-WinPkgsTaskFolder -Scheduler $scheduler -Path $path -Create
        $flags = 6
    }
    $registered = $folder.RegisterTask($name, $xml, $flags, [string]$Properties['runAs'], $null, $logon, $sddl)
    if (-not $ValidateOnly -and $null -ne $sddl) {
        # RegisterTask puts a descriptor on a task it creates and ignores the
        # one it is given for a task it updates (seen on 25H2, 2026-09-14), so
        # a changed descriptor is set on its own as well.
        $registered.SetSecurityDescriptor([string]$sddl, 0)
    }
}

function Remove-WinPkgsTaskRegistration {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Write-WinPkgsTaskLog "delete $Path$Name"
    if ($env:WINPKGS_TASK_ROOT) {
        foreach ($extension in '.xml', '.sddl') {
            Remove-Item -LiteralPath (Get-WinPkgsTaskStandInPath $Path $Name $extension) -Force -ErrorAction SilentlyContinue
        }
        return
    }
    $scheduler = Connect-WinPkgsTaskScheduler
    try { (Get-WinPkgsTaskFolder -Scheduler $scheduler -Path $Path).DeleteTask($Name, 0) }
    catch { if ((Get-WinPkgsTaskHResult $_) -notin $script:TaskNotFound) { throw } }
}

# --- the resource -------------------------------------------------------------------

function Test-WinPkgsTaskOwned {
    # The live ledger during an apply, a fresh read during a plan.
    param([Parameter(Mandatory)][string]$FullPath, [hashtable]$Context)
    $state = if ($Context -and $Context['State']) { $Context['State'] }
        else { Read-WinPkgsState -Kind $(if ($Context -and $Context['Kind']) { $Context['Kind'] } else { 'system' }) }
    return (@($state['owned']['scheduledTasks']) -contains $FullPath)
}

function Get-WinPkgsTaskDifferences {
    # What in $Current differs from what is declared, by field name.
    param([Parameter(Mandatory)][hashtable]$Properties, [Parameter(Mandatory)][hashtable]$Wanted, [Parameter(Mandatory)][hashtable]$Current)
    $diffs = @($script:TaskFields | Where-Object { [string]$Wanted[$_] -cne [string]$Current[$_] })
    if ($null -ne $Properties['securityDescriptor'] -and
        -not (Test-WinPkgsTaskSecurityEqual -Expected ([string]$Properties['securityDescriptor']) -Actual $Current['securityDescriptor'] -RunAsSid $Wanted['runAs'])) {
        $diffs += 'securityDescriptor'
    }
    return , $diffs
}

function Get-WinPkgsTask {
    param([hashtable]$Properties, [hashtable]$Context)
    $full = Get-WinPkgsTaskFullPath -Properties $Properties
    $owned = Test-WinPkgsTaskOwned -FullPath $full -Context $Context
    $read = Read-WinPkgsTaskRegistration -Path ([string]$Properties['path']) -Name ([string]$Properties['name']) `
        -WithSecurity:($null -ne $Properties['securityDescriptor'])
    if ($null -eq $read) { return @{ exists = $false; owned = $owned } }
    if ($read['denied']) { return @{ exists = $true; readable = $false; owned = $owned } }
    $current = Read-WinPkgsTaskXml -Xml $read['xml']
    $current['exists'] = $true
    $current['readable'] = $true
    $current['owned'] = $owned
    if ($read.ContainsKey('securityDescriptor')) { $current['securityDescriptor'] = $read['securityDescriptor'] }
    return $current
}

function Test-WinPkgsTask {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists'] -or -not $Current['owned'] -or -not $Current['readable']) { return $false }
    $wanted = Read-WinPkgsTaskXml -Xml (ConvertTo-WinPkgsTaskXml -Properties $Properties)
    return ((Get-WinPkgsTaskDifferences -Properties $Properties -Wanted $wanted -Current $Current).Count -eq 0)
}

function Set-WinPkgsTask {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $full = Get-WinPkgsTaskFullPath -Properties $Properties
    if ($Current['exists'] -and -not ($Current['owned'] -or (Test-WinPkgsTaskOwned -FullPath $full -Context $Context))) {
        throw ("Scheduled task $full already exists, and winpkgs did not create it: a definition would replace " +
               "Windows' or an application's task. Delete it first to have winpkgs define it, or declare only " +
               'whether it may run (windows.scheduledTasks."..." = true or false).')
    }
    Save-WinPkgsTaskRegistration -Properties $Properties
    if (-not $Current['exists']) { Add-WinPkgsOwned -Context $Context -Backend 'scheduledTasks' -Id $full }
}

function Remove-WinPkgsTask {
    param([hashtable]$Properties, [hashtable]$Context)
    $full = Get-WinPkgsTaskFullPath -Properties $Properties
    Remove-WinPkgsTaskRegistration -Path ([string]$Properties['path']) -Name ([string]$Properties['name'])
    Remove-WinPkgsOwned -Context $Context -Backend 'scheduledTasks' -Id $full
}

function Format-WinPkgsTaskTriggers {
    param($Triggers)
    $said = @(foreach ($t in @($Triggers)) {
        if ($null -eq $t) { continue }
        $when = if ($t['type'] -eq 'boot') { 'at boot' } elseif ($t['user']) { "at $($t['user'])'s logon" } else { 'at any user''s logon' }
        if ($t['delay']) { $when += " (after $($t['delay']))" }
        if ($null -ne $t['enabled'] -and -not $t['enabled']) { $when += ' (off)' }
        $when
    })
    if ($said.Count -eq 0) { return 'on demand only' }
    return ($said -join ', ')
}

function Format-WinPkgsTaskChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) {
        $run = (@($Properties['command'], $Properties['arguments']) | Where-Object { $_ }) -join ' '
        return "not present -> $run, $(Format-WinPkgsTaskTriggers $Properties['triggers']), as $($Properties['runAs'])"
    }
    if (-not $Current['owned']) { return 'exists, and winpkgs did not create it: refused' }
    if (-not $Current['readable']) { return 'cannot be read without elevation; compared when applied' }
    $wanted = Read-WinPkgsTaskXml -Xml (ConvertTo-WinPkgsTaskXml -Properties $Properties)
    $parts = foreach ($d in (Get-WinPkgsTaskDifferences -Properties $Properties -Wanted $wanted -Current $Current)) {
        switch ($d) {
            'actions' {
                if ($wanted['command'] -cne $Current['command']) { "command $($Current['command']) -> $($wanted['command'])" }
                elseif ($wanted['arguments'] -cne $Current['arguments']) { 'arguments' }
                elseif ($wanted['workingDirectory'] -cne $Current['workingDirectory']) { 'working directory' }
                else { 'actions' }
            }
            'triggers' { "triggers -> $(Format-WinPkgsTaskTriggers $Properties['triggers'])" }
            'securityDescriptor' { 'security descriptor' }
            'description' { 'description' }
            default { "$d $($Current[$d]) -> $($wanted[$d])" }
        }
    }
    return (@($parts) -join '; ')
}

Register-WinPkgsResource -Type 'winpkgs/task' `
    -Get 'Get-WinPkgsTask' -Test 'Test-WinPkgsTask' -Set 'Set-WinPkgsTask' `
    -Remove 'Remove-WinPkgsTask' -Describe 'Format-WinPkgsTaskChange'
