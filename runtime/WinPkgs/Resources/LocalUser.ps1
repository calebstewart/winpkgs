<#
    winpkgs/localUser - a local account that `users.users` declares: created
    when the machine has none by that name, and its declared settings kept.
    Machine scope.

    properties:
      name                   the account name (me, Caleb Stewart)
      fullName               the full name Windows shows, or null to leave it
      passwordNeverExpires   true | false | null (leave it)
      userMayChangePassword  true | false | null (leave it)
      initialPassword        the password an account winpkgs creates starts
                             with; null or '' for none (a blank password)

    The password is only ever written when the account is created. It is not a
    secret -- it is in the configuration, and so in the Nix store -- and it is
    made to be changed: a created account's password is expired, so the first
    sign-in asks for a new one. Windows cannot expire the password of an
    account whose password never expires or who may not change it, so for
    those it is left as it is. An account that already existed is managed:
    its name and settings, never its password.

    A group membership is winpkgs/groupMember's, not this resource's. An
    account winpkgs created is owned (`owned.users`, by SID) and deleted when
    it leaves the configuration only under `winpkgs.prune.users`, which is off
    by default: a profile, its files and what was encrypted for it outlive the
    account, and a new account by the same name is not the same account.

    Created through ADSI, which can expire a password in the same breath and
    works under Windows PowerShell; read and changed with
    Get-/Set-/Remove-LocalUser. The stand-in for tests is winpkgs/groupMember's
    (WINPKGS_GROUP_STATE), whose `accounts` a new account joins so that
    memberships resolve it.
#>

function Get-WinPkgsLocalUserRecord {
    # The account by name, as the resource compares it; $null when none.
    param([Parameter(Mandatory)][string]$Name)
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        foreach ($sid in $db['users'].Keys) {
            $u = $db['users'][$sid]
            if ([string]$u['name'] -ieq $Name) {
                return @{
                    sid                   = $sid
                    name                  = [string]$u['name']
                    fullName              = [string]$u['fullName']
                    passwordNeverExpires  = [bool]$u['passwordNeverExpires']
                    userMayChangePassword = [bool]$u['userMayChangePassword']
                }
            }
        }
        return $null
    }
    $found = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $found) { return $null }
    return @{
        sid                   = $found.SID.Value
        name                  = $found.Name
        fullName              = [string]$found.FullName
        # Get-LocalUser has no such property: an expiry date is how it says so.
        passwordNeverExpires  = ($null -eq $found.PasswordExpires)
        userMayChangePassword = [bool]$found.UserMayChangePassword
    }
}

function New-WinPkgsLocalUserRecord {
    # Creates the account with its password; returns its SID.
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Password)
    Write-WinPkgsGroupLog "create-user $Name"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $sid = New-WinPkgsStandInSid -Database $db
        $db['users'][$sid] = @{
            name = $Name; fullName = ''; password = [string]$Password; passwordExpired = $false
            passwordNeverExpires = $false; userMayChangePassword = $true
        }
        $db['accounts'][$Name] = $sid
        Save-WinPkgsGroupStandIn -Db $db
        return $sid
    }
    $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
    $account = $computer.Create('user', $Name)
    $account.SetPassword([string]$Password)
    $account.SetInfo()
    return (Get-LocalUser -Name $Name -ErrorAction Stop).SID.Value
}

function Set-WinPkgsLocalUserSetting {
    # Only what is given: fullName, passwordNeverExpires, userMayChangePassword.
    param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][hashtable]$Settings)
    if ($Settings.Count -eq 0) { return }
    Write-WinPkgsGroupLog ("set-user $Sid " + (($Settings.Keys | Sort-Object) -join ','))
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        foreach ($k in $Settings.Keys) { $db['users'][$Sid][$k] = $Settings[$k] }
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    $set = @{ SID = $Sid; ErrorAction = 'Stop' }
    if ($Settings.ContainsKey('fullName')) { $set['FullName'] = [string]$Settings['fullName'] }
    if ($Settings.ContainsKey('passwordNeverExpires')) { $set['PasswordNeverExpires'] = [bool]$Settings['passwordNeverExpires'] }
    if ($Settings.ContainsKey('userMayChangePassword')) { $set['UserMayChangePassword'] = [bool]$Settings['userMayChangePassword'] }
    Set-LocalUser @set
}

function Set-WinPkgsLocalUserPasswordExpired {
    # "Must change password at next logon". After everything else that is set
    # on the account: writing the password again would clear it.
    param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][string]$Name)
    Write-WinPkgsGroupLog "expire-user $Sid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $db['users'][$Sid]['passwordExpired'] = $true
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    $account = [ADSI]"WinNT://$env:COMPUTERNAME/$Name,user"
    $account.Put('PasswordExpired', 1)
    $account.SetInfo()
}

function Test-WinPkgsLocalUserSidExists {
    param([Parameter(Mandatory)][string]$Sid)
    if ($env:WINPKGS_GROUP_STATE) { return (Read-WinPkgsGroupStandIn)['users'].ContainsKey($Sid) }
    return [bool](Get-LocalUser -SID $Sid -ErrorAction SilentlyContinue)
}

function Remove-WinPkgsLocalUserRecord {
    param([Parameter(Mandatory)][string]$Sid)
    Write-WinPkgsGroupLog "delete-user $Sid"
    if ($env:WINPKGS_GROUP_STATE) {
        $db = Read-WinPkgsGroupStandIn
        $name = [string]$db['users'][$Sid]['name']
        $db['users'].Remove($Sid)
        if ($name) { $db['accounts'].Remove($name) }
        Save-WinPkgsGroupStandIn -Db $db
        return
    }
    Remove-LocalUser -SID $Sid -ErrorAction Stop
}

# --- the resource -------------------------------------------------------------

function Get-WinPkgsLocalUserDrift {
    # The declared settings the account does not have, as Set-LocalUser's
    # arguments would carry them.
    param([hashtable]$Properties, [hashtable]$Current)
    $drift = @{}
    $fullName = $Properties['fullName']
    if ($null -ne $fullName -and [string]$Current['fullName'] -cne [string]$fullName) { $drift['fullName'] = [string]$fullName }
    foreach ($flag in 'passwordNeverExpires', 'userMayChangePassword') {
        $want = $Properties[$flag]
        if ($null -ne $want -and [bool]$Current[$flag] -ne [bool]$want) { $drift[$flag] = [bool]$want }
    }
    return $drift
}

function Get-WinPkgsLocalUser {
    # By name, or -- for a prune, whose properties are the ledger's -- by SID.
    param([hashtable]$Properties, [hashtable]$Context)
    if (-not $Properties['name'] -and $Properties['sid']) {
        return @{ exists = (Test-WinPkgsLocalUserSidExists -Sid ([string]$Properties['sid'])); sid = [string]$Properties['sid'] }
    }
    $found = Get-WinPkgsLocalUserRecord -Name ([string]$Properties['name'])
    if (-not $found) { return @{ exists = $false } }
    $found['exists'] = $true
    return $found
}

function Test-WinPkgsLocalUser {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    return ((Get-WinPkgsLocalUserDrift -Properties $Properties -Current $Current).Count -eq 0)
}

function Set-WinPkgsLocalUser {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $name = [string]$Properties['name']
    if ($Current['exists']) {
        Set-WinPkgsLocalUserSetting -Sid $Current['sid'] -Settings (Get-WinPkgsLocalUserDrift -Properties $Properties -Current $Current)
        return
    }

    $sid = New-WinPkgsLocalUserRecord -Name $name -Password ([string]$Properties['initialPassword'])
    # Owned from the moment it exists, so a failure below cannot leave an
    # account winpkgs made and does not know about.
    Add-WinPkgsOwned -Context $Context -Backend 'users' -Id $sid
    $created = Get-WinPkgsLocalUserRecord -Name $name
    Set-WinPkgsLocalUserSetting -Sid $sid -Settings (Get-WinPkgsLocalUserDrift -Properties $Properties -Current $created)
    if ($Properties['passwordNeverExpires'] -ne $true -and $Properties['userMayChangePassword'] -ne $false) {
        Set-WinPkgsLocalUserPasswordExpired -Sid $sid -Name $name
    }
}

function Remove-WinPkgsLocalUser {
    # Prune, under winpkgs.prune.users: winpkgs created the account and the
    # configuration no longer names it. Properties are the ledger's SID and
    # the name it had. The profile directory is left where it is.
    param([hashtable]$Properties, [hashtable]$Context)
    $sid = [string]$Properties['sid']
    if (Test-WinPkgsLocalUserSidExists -Sid $sid) { Remove-WinPkgsLocalUserRecord -Sid $sid }
    Remove-WinPkgsOwned -Context $Context -Backend 'users' -Id $sid
}

function Format-WinPkgsLocalUserChange {
    # Never the password: the plan is printed, and logged.
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) {
        $how = if ($Properties['initialPassword']) { 'the initial password' } else { 'a blank password' }
        if ($Properties['passwordNeverExpires'] -ne $true -and $Properties['userMayChangePassword'] -ne $false) {
            $how += ', to be changed at the first sign-in'
        }
        return "no such account -> created with $how"
    }
    $drift = Get-WinPkgsLocalUserDrift -Properties $Properties -Current $Current
    if ($drift.Count -eq 0) { return 'exists' }
    return ((@($drift.Keys | Sort-Object) | ForEach-Object { "$_ -> $($drift[$_])" }) -join '; ')
}

Register-WinPkgsResource -Type 'winpkgs/localUser' `
    -Get 'Get-WinPkgsLocalUser' -Test 'Test-WinPkgsLocalUser' -Set 'Set-WinPkgsLocalUser' `
    -Remove 'Remove-WinPkgsLocalUser' -Describe 'Format-WinPkgsLocalUserChange'
