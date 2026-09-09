<#
    winpkgs/scheduledTask - whether one scheduled task is allowed to run.
    Machine scope.

    properties: path (the folder, ending in a backslash), name, enabled

    Only the enabled flag. The task itself -- its triggers, its action, its
    principal -- is Windows', and a configuration that redefined those would be
    replacing a part of the operating system rather than settling a preference.
    Turning one off is the whole of what is wanted here: Windows ships tasks
    that undo settings, and `\Microsoft\Windows\AppxDeploymentClient\UCPD
    velocity` is the one this was written for -- it runs UCPDMgr.exe at every
    logon and sets the User Choice Protection Driver back.

    A task that is not there at all counts as satisfied when the declared state
    is disabled: something already removed cannot run. Asking to enable one that
    does not exist is an error, because nothing here can create it.
#>

function Get-WinPkgsScheduledTaskState {
    param([hashtable]$Properties, [hashtable]$Context)
    $task = Get-ScheduledTask -TaskPath ([string]$Properties['path']) `
                              -TaskName ([string]$Properties['name']) -ErrorAction SilentlyContinue
    if (-not $task) { return @{ exists = $false } }
    # Settings.Enabled is the flag; State also reports Running and Ready, which
    # are about this moment rather than about whether it may run at all.
    return @{ exists = $true; enabled = [bool]$task.Settings.Enabled }
}

function Test-WinPkgsScheduledTask {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $wanted = [bool]$Properties['enabled']
    if (-not $Current['exists']) { return (-not $wanted) }
    return ([bool]$Current['enabled'] -eq $wanted)
}

function Set-WinPkgsScheduledTaskState {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $path = [string]$Properties['path']
    $name = [string]$Properties['name']
    $wanted = [bool]$Properties['enabled']
    if (-not $Current['exists']) {
        if (-not $wanted) { return }
        throw "No scheduled task $path$name to enable."
    }
    if ($wanted) {
        Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
    }
}

function Restore-WinPkgsScheduledTask {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    if (-not $Before['exists']) { return }
    $path = [string]$Properties['path']
    $name = [string]$Properties['name']
    if ([bool]$Before['enabled']) {
        Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
    }
}

function Format-WinPkgsScheduledTaskChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $to = if ([bool]$Properties['enabled']) { 'enabled' } else { 'disabled' }
    if (-not $Current['exists']) { return "not present -> $to" }
    $from = if ([bool]$Current['enabled']) { 'enabled' } else { 'disabled' }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/scheduledTask' `
    -Get 'Get-WinPkgsScheduledTaskState' -Test 'Test-WinPkgsScheduledTask' `
    -Set 'Set-WinPkgsScheduledTaskState' -Restore 'Restore-WinPkgsScheduledTask' `
    -Describe 'Format-WinPkgsScheduledTaskChange'
