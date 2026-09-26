<#
    winpkgs/localGroup - a local group that `users.groups` declares: created
    when the machine has none by that name, its description kept when one is
    declared. Machine scope. Built-in groups never reach this resource: they
    exist everywhere, and the module only declares their members.

    properties:
      name         the group's name (docker-users, developers)
      description  its description, or null to leave it alone

    A group winpkgs created is owned (`owned.groups`, by SID) and deleted again
    when it leaves the configuration (prune); one that already existed --
    because an installer made it, or somebody did by hand -- is managed, never
    deleted. Its members are winpkgs/groupMember's, not this resource's.

    Read and changed with Get-/New-/Set-/Remove-LocalGroup. The stand-in for
    tests is winpkgs/groupMember's (WINPKGS_GROUP_STATE).
#>

function New-WinPkgsStandInSid {
    # A fresh SID for the stand-in's new accounts and groups.
    param([Parameter(Mandatory)][hashtable]$Database)
    $taken = @($Database['groups'].Keys) + @($Database['accounts'].Values)
    $rid = 2000
    while ("S-1-5-21-0-0-0-$rid" -in $taken) { $rid++ }
    return "S-1-5-21-0-0-0-$rid"
}

function Get-WinPkgsLocalGroupRecord {
    # @{ sid; name; description } for a local group by name; $null when none.
    param([Parameter(Mandatory)][string]$Name)
    if ($env:WINPKGS_GROUP_STATE) {
        $groups = (Read-WinPkgsGroupStandIn)['groups']
        foreach ($sid in $groups.Keys) {
            if ([string]$groups[$sid]['name'] -ieq $Name) {
                return @{ sid = $sid; name = [string]$groups[$sid]['name']; description = [string]$groups[$sid]['description'] }
            }
        }
        return $null
    }
    $found = Get-LocalGroup -Name $Name -ErrorAction SilentlyContinue
    if (-not $found) { return $null }
    return @{ sid = $found.SID.Value; name = $found.Name; description = [string]$found.Description }
}

function New-WinPkgsLocalGroupRecord {
    # Creates the group; returns its SID.
    param([Parameter(Mandatory)][string]$Name, [string]$Description)
    Write-WinPkgsGroupLog "create-group $Name"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $sid = New-WinPkgsStandInSid -Database $db
        $db['groups'][$sid] = @{ name = $Name; description = [string]$Description; members = @() }
        Save-WinPkgsGroupStandIn -Db $db
        return $sid
    }
    $new = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($Description) { $new['Description'] = $Description }
    return (New-LocalGroup @new).SID.Value
}

function Set-WinPkgsLocalGroupDescription {
    param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][AllowEmptyString()][string]$Description)
    Write-WinPkgsGroupLog "describe-group $Sid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $db['groups'][$Sid]['description'] = $Description
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    Set-LocalGroup -SID $Sid -Description $Description -ErrorAction Stop
}

function Remove-WinPkgsLocalGroupRecord {
    param([Parameter(Mandatory)][string]$Sid)
    Write-WinPkgsGroupLog "delete-group $Sid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $db['groups'].Remove($Sid)
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    Remove-LocalGroup -SID $Sid -ErrorAction Stop
}

function Test-WinPkgsLocalGroupSidExists {
    param([Parameter(Mandatory)][string]$Sid)
    if ($env:WINPKGS_GROUP_STATE) { return (Read-WinPkgsGroupStandIn)['groups'].ContainsKey($Sid) }
    return [bool](Get-LocalGroup -SID $Sid -ErrorAction SilentlyContinue)
}

# --- the resource -------------------------------------------------------------

function Format-WinPkgsSidName {
    # What the machine calls a group or account the ledger knows by SID; the
    # SID itself when it calls it nothing any more.
    param([Parameter(Mandatory)][string]$Sid)
    $group = Find-WinPkgsLocalGroup -Group $Sid
    if ($group) { return $group.name }
    return (Resolve-WinPkgsAccount -Member $Sid).name
}

function Get-WinPkgsLocalGroup {
    # By name, or -- for a prune, whose properties are the ledger's -- by SID.
    param([hashtable]$Properties, [hashtable]$Context)
    if (-not $Properties['name'] -and $Properties['sid']) {
        return @{ exists = (Test-WinPkgsLocalGroupSidExists -Sid ([string]$Properties['sid'])); sid = [string]$Properties['sid'] }
    }
    $found = Get-WinPkgsLocalGroupRecord -Name ([string]$Properties['name'])
    if (-not $found) { return @{ exists = $false } }
    return @{ exists = $true; sid = $found.sid; name = $found.name; description = $found.description }
}

function Test-WinPkgsLocalGroup {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $description = $Properties['description']
    return ($null -eq $description -or [string]$Current['description'] -ceq [string]$description)
}

function Set-WinPkgsLocalGroup {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $description = $Properties['description']
    if (-not $Current['exists']) {
        $sid = New-WinPkgsLocalGroupRecord -Name ([string]$Properties['name']) -Description ([string]$description)
        Add-WinPkgsOwned -Context $Context -Backend 'groups' -Id $sid
        return
    }
    if ($null -ne $description -and [string]$Current['description'] -cne [string]$description) {
        Set-WinPkgsLocalGroupDescription -Sid $Current['sid'] -Description ([string]$description)
    }
}

function Remove-WinPkgsLocalGroup {
    # Prune: winpkgs created the group and the configuration no longer names
    # it. Properties are the ledger's: its SID, and the name it had.
    param([hashtable]$Properties, [hashtable]$Context)
    $sid = [string]$Properties['sid']
    if (Test-WinPkgsLocalGroupSidExists -Sid $sid) { Remove-WinPkgsLocalGroupRecord -Sid $sid }
    Remove-WinPkgsOwned -Context $Context -Backend 'groups' -Id $sid
}

function Format-WinPkgsLocalGroupChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) { return 'no such group -> created' }
    if (-not (Test-WinPkgsLocalGroup -Properties $Properties -Current $Current)) { return 'description -> as declared' }
    return 'exists'
}

Register-WinPkgsResource -Type 'winpkgs/localGroup' `
    -Get 'Get-WinPkgsLocalGroup' -Test 'Test-WinPkgsLocalGroup' -Set 'Set-WinPkgsLocalGroup' `
    -Remove 'Remove-WinPkgsLocalGroup' -Describe 'Format-WinPkgsLocalGroupChange'
