<#
    winpkgs/groupMember - one account's membership of one local group: a user
    in Hyper-V Administrators, Remote Desktop Users, docker-users. Machine
    scope.

    properties:
      group   the group: a SID (S-1-5-32-578) or a name (docker-users)
      member  the account: a name (caleb, DOMAIN\user,
              MicrosoftAccount\me@outlook.com) or a SID

    Both are resolved on the machine and compared as SIDs. Built-in groups
    have localised names and one SID everywhere, and an account can be renamed
    while its SID stays, so the SID is the identity and the name is what the
    plan shows. Read with Get-LocalGroupMember, which needs no elevation;
    changed with Add-/Remove-LocalGroupMember.

    A member winpkgs added is owned (`owned.groupMembers`, as
    "<group SID>/<member SID>") and removed again when it leaves the
    configuration (prune); one that was already a member is managed, never
    removed. Nothing here creates a group or an account: one that is not there
    is an error naming it.

    Membership reaches an account's logon token at its next sign-in. The apply
    cannot hurry that, so the plan says so.

    WINPKGS_GROUP_STATE names a JSON file standing in for the accounts
    database (tests):
      { "groups":   { "<sid>": { "name": "...", "members": [ "<sid>" ] } },
        "accounts": { "<name>": "<sid>" } }
    WINPKGS_GROUP_LOG records every add and remove.
#>

function Test-WinPkgsSid {
    param([string]$Value)
    return ($Value -match '^S-1-\d+(-\d+)+$')
}

# --- the accounts database, or its stand-in -----------------------------------

function Read-WinPkgsGroupStandIn {
    if (-not (Test-Path -LiteralPath $env:WINPKGS_GROUP_STATE)) { return @{ groups = @{}; accounts = @{} } }
    $db = Get-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    if (-not ($db['groups'] -is [hashtable])) { $db['groups'] = @{} }
    if (-not ($db['accounts'] -is [hashtable])) { $db['accounts'] = @{} }
    return $db
}

function Save-WinPkgsGroupStandIn {
    param([hashtable]$Db)
    $Db | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Encoding utf8
}

function Write-WinPkgsGroupLog {
    param([string]$Line)
    if ($env:WINPKGS_GROUP_LOG) { Add-Content -LiteralPath $env:WINPKGS_GROUP_LOG -Value $Line }
}

function Find-WinPkgsLocalGroup {
    <#
    .SYNOPSIS
        @{ sid; name } for a local group given by SID or name; $null when
        there is no such group.
    #>
    param([Parameter(Mandatory)][string]$Group)

    if ($env:WINPKGS_GROUP_STATE) {
        $groups = (Read-WinPkgsGroupStandIn)['groups']
        if (Test-WinPkgsSid $Group) {
            if ($groups.ContainsKey($Group)) { return @{ sid = $Group; name = [string]$groups[$Group]['name'] } }
            return $null
        }
        foreach ($sid in $groups.Keys) {
            if ([string]$groups[$sid]['name'] -ieq $Group) { return @{ sid = $sid; name = [string]$groups[$sid]['name'] } }
        }
        return $null
    }

    $found = if (Test-WinPkgsSid $Group) { Get-LocalGroup -SID $Group -ErrorAction SilentlyContinue }
             else { Get-LocalGroup -Name $Group -ErrorAction SilentlyContinue }
    if (-not $found) { return $null }
    return @{ sid = $found.SID.Value; name = $found.Name }
}

function Resolve-WinPkgsAccount {
    <#
    .SYNOPSIS
        @{ sid; name } for an account given by name or SID; $null when no
        such account exists. A SID that names nothing this machine can
        translate is still an identity, and is returned with itself as its
        name: a member that was deleted is exactly what a prune has to remove.
    #>
    param([Parameter(Mandatory)][string]$Member)

    if ($env:WINPKGS_GROUP_STATE) {
        $accounts = (Read-WinPkgsGroupStandIn)['accounts']
        if (Test-WinPkgsSid $Member) {
            foreach ($name in $accounts.Keys) { if ([string]$accounts[$name] -eq $Member) { return @{ sid = $Member; name = $name } } }
            return @{ sid = $Member; name = $Member }
        }
        foreach ($name in $accounts.Keys) {
            if ($name -ieq $Member) { return @{ sid = [string]$accounts[$name]; name = $name } }
        }
        return $null
    }

    if (Test-WinPkgsSid $Member) {
        $sid = New-Object Security.Principal.SecurityIdentifier $Member
        try { $name = $sid.Translate([Security.Principal.NTAccount]).Value } catch { $name = $Member }
        return @{ sid = $sid.Value; name = $name }
    }
    try {
        $sid = (New-Object Security.Principal.NTAccount $Member).Translate([Security.Principal.SecurityIdentifier])
    } catch {
        return $null
    }
    return @{ sid = $sid.Value; name = $sid.Translate([Security.Principal.NTAccount]).Value }
}

function Get-WinPkgsLocalGroupMemberSid {
    # The SIDs of a group's members.
    param([Parameter(Mandatory)][string]$GroupSid)
    if ($env:WINPKGS_GROUP_STATE) {
        $groups = (Read-WinPkgsGroupStandIn)['groups']
        if (-not $groups.ContainsKey($GroupSid)) { return @() }
        return @($groups[$GroupSid]['members'] | ForEach-Object { [string]$_ })
    }
    return @(Get-LocalGroupMember -SID $GroupSid -ErrorAction Stop | ForEach-Object { $_.SID.Value })
}

function Add-WinPkgsLocalGroupMember {
    param([Parameter(Mandatory)][string]$GroupSid, [Parameter(Mandatory)][string]$MemberSid)
    Write-WinPkgsGroupLog "add $GroupSid $MemberSid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $db['groups'][$GroupSid]['members'] = @(@($db['groups'][$GroupSid]['members']) + @($MemberSid) | Select-Object -Unique)
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    Add-LocalGroupMember -SID $GroupSid -Member $MemberSid -ErrorAction Stop
}

function Remove-WinPkgsLocalGroupMember {
    param([Parameter(Mandatory)][string]$GroupSid, [Parameter(Mandatory)][string]$MemberSid)
    Write-WinPkgsGroupLog "remove $GroupSid $MemberSid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $db['groups'][$GroupSid]['members'] = @($db['groups'][$GroupSid]['members'] | Where-Object { [string]$_ -ne $MemberSid })
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    Remove-LocalGroupMember -SID $GroupSid -Member $MemberSid -ErrorAction Stop
}

# --- the ledger's key for a membership ----------------------------------------

function ConvertTo-WinPkgsGroupMemberKey {
    param([Parameter(Mandatory)][string]$GroupSid, [Parameter(Mandatory)][string]$MemberSid)
    return "$GroupSid/$MemberSid"
}

function ConvertFrom-WinPkgsGroupMemberKey {
    param([Parameter(Mandatory)][string]$Key)
    $parts = $Key.Split('/', 2)
    return @{ group = $parts[0]; member = $parts[1] }
}

function Resolve-WinPkgsGroupMemberKey {
    # The key a declared membership would have in the ledger, or $null when
    # its group or account cannot be found.
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Member)
    $g = Find-WinPkgsLocalGroup -Group $Group
    if (-not $g) { return $null }
    $a = Resolve-WinPkgsAccount -Member $Member
    if (-not $a) { return $null }
    return ConvertTo-WinPkgsGroupMemberKey -GroupSid $g.sid -MemberSid $a.sid
}

function Format-WinPkgsGroupMemberId {
    # "Group <name>: <account>", with names where the machine knows them.
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Member)
    $g = Find-WinPkgsLocalGroup -Group $Group
    $a = Resolve-WinPkgsAccount -Member $Member
    $groupName = if ($g) { $g.name } else { $Group }
    $memberName = if ($a) { $a.name } else { $Member }
    return "Group ${groupName}: $memberName"
}

# --- the resource -------------------------------------------------------------

function Get-WinPkgsGroupMember {
    param([hashtable]$Properties, [hashtable]$Context)
    $group = Find-WinPkgsLocalGroup -Group ([string]$Properties['group'])
    if (-not $group) { return @{ exists = $false; groupExists = $false; accountExists = $false } }
    $account = Resolve-WinPkgsAccount -Member ([string]$Properties['member'])
    if (-not $account) { return @{ exists = $false; groupExists = $true; accountExists = $false; group = $group.name; groupSid = $group.sid } }
    $members = Get-WinPkgsLocalGroupMemberSid -GroupSid $group.sid
    return @{
        exists        = ($account.sid -in $members)
        groupExists   = $true
        accountExists = $true
        group         = $group.name
        groupSid      = $group.sid
        member        = $account.name
        memberSid     = $account.sid
    }
}

function Test-WinPkgsGroupMember {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return [bool]$Current['exists']
}

function Set-WinPkgsGroupMember {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['groupExists']) {
        throw "No local group '$($Properties['group'])' on this machine. winpkgs does not create groups; 'Get-LocalGroup' lists them."
    }
    if (-not $Current['accountExists']) {
        throw "No account named '$($Properties['member'])' on this machine or its domain. winpkgs does not create accounts."
    }
    Add-WinPkgsLocalGroupMember -GroupSid $Current['groupSid'] -MemberSid $Current['memberSid']
    Add-WinPkgsOwned -Context $Context -Backend 'groupMembers' -Id (ConvertTo-WinPkgsGroupMemberKey -GroupSid $Current['groupSid'] -MemberSid $Current['memberSid'])
}

function Remove-WinPkgsGroupMember {
    # Prune: winpkgs added the member and the configuration no longer names it.
    param([hashtable]$Properties, [hashtable]$Context)
    $group = Find-WinPkgsLocalGroup -Group ([string]$Properties['group'])
    $account = Resolve-WinPkgsAccount -Member ([string]$Properties['member'])
    if ($group -and $account) {
        if ($account.sid -in (Get-WinPkgsLocalGroupMemberSid -GroupSid $group.sid)) {
            Remove-WinPkgsLocalGroupMember -GroupSid $group.sid -MemberSid $account.sid
        }
        Remove-WinPkgsOwned -Context $Context -Backend 'groupMembers' -Id (ConvertTo-WinPkgsGroupMemberKey -GroupSid $group.sid -MemberSid $account.sid)
    }
    # However it was spelled: a prune's properties are the ledger's SIDs.
    Remove-WinPkgsOwned -Context $Context -Backend 'groupMembers' -Id (ConvertTo-WinPkgsGroupMemberKey -GroupSid ([string]$Properties['group']) -MemberSid ([string]$Properties['member']))
}

function Format-WinPkgsGroupMemberChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['groupExists']) { return "no local group $($Properties['group'])" }
    if (-not $Current['accountExists']) { return "no account named $($Properties['member'])" }
    if ($Current['exists']) { return "$($Current['member']) is a member" }
    return "$($Current['member']) is not a member -> member; from their next sign-in"
}

Register-WinPkgsResource -Type 'winpkgs/groupMember' `
    -Get 'Get-WinPkgsGroupMember' -Test 'Test-WinPkgsGroupMember' -Set 'Set-WinPkgsGroupMember' `
    -Remove 'Remove-WinPkgsGroupMember' -Describe 'Format-WinPkgsGroupMemberChange'
