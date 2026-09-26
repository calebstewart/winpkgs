# winpkgs/localUser and winpkgs/localGroup against winpkgs/groupMember's
# stand-in for the accounts database. Creating a real account takes elevation
# and leaves an account behind on the machine the suite runs on.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $env:WINPKGS_GROUP_STATE = Join-Path $TestDrive 'accounts.json'
    $env:WINPKGS_GROUP_LOG = Join-Path $TestDrive 'sam.log'
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    $script:Users = 'S-1-5-32-545'
    $script:Admins = 'S-1-5-32-544'
    $script:Caleb = 'S-1-5-21-1-2-3-1001'
    $script:Docker = 'S-1-5-21-1-2-3-1050'

    function Reset-Sam {
        @{
            groups   = @{
                $Admins = @{ name = 'Administrators'; description = 'Built-in'; members = @($Caleb) }
                $Users  = @{ name = 'Users'; description = 'Built-in'; members = @($Caleb) }
                $Docker = @{ name = 'docker-users'; description = 'Docker'; members = @() }
            }
            accounts = @{ 'caleb' = $Caleb }
            users    = @{
                $Caleb = @{ name = 'caleb'; fullName = 'Caleb'; password = 'secret'; passwordExpired = $false
                            passwordNeverExpires = $true; userMayChangePassword = $true }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Encoding utf8
        Remove-Item -LiteralPath $env:WINPKGS_GROUP_LOG -ErrorAction SilentlyContinue
    }

    function Get-Log {
        if (Test-Path -LiteralPath $env:WINPKGS_GROUP_LOG) { return @(Get-Content -LiteralPath $env:WINPKGS_GROUP_LOG) }
        return @()
    }

    function Sam { Get-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Raw | ConvertFrom-WinPkgsJson }

    function UserNamed([string]$Name) {
        $db = Sam
        foreach ($sid in $db['users'].Keys) { if ($db['users'][$sid]['name'] -eq $Name) { return $db['users'][$sid] + @{ sid = $sid } } }
        return $null
    }

    function Invoke-Res([string]$Type, [string]$Operation, [hashtable]$Properties, [hashtable]$Current, [hashtable]$Context = @{}) {
        $a = @{ Type = $Type; Operation = $Operation; Properties = $Properties; Context = $Context }
        if ($Current) { $a['Current'] = $Current }
        Invoke-WinPkgsResource @a
    }

    function Converge([string]$Type, [hashtable]$Properties, [hashtable]$Context = @{}) {
        $current = Invoke-Res $Type Get $Properties
        if (-not (Invoke-Res $Type Test $Properties -Current $current)) {
            Invoke-Res $Type Set $Properties -Current $current -Context $Context
        }
    }

    function New-UserProps([hashtable]$Extra = @{}) {
        $p = @{ name = 'guest'; fullName = $null; passwordNeverExpires = $null; userMayChangePassword = $null; initialPassword = 'winpkgs-setup' }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        return $p
    }
}

AfterAll {
    foreach ($v in 'WINPKGS_GROUP_STATE', 'WINPKGS_GROUP_LOG', 'WINPKGS_STATE_DIR') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'winpkgs/localUser' {
    BeforeEach { Reset-Sam }

    Context 'an account that is not there' {
        It 'is created with the initial password, expired, and owned' {
            $state = Read-WinPkgsState -Kind system
            Converge 'winpkgs/localUser' (New-UserProps @{ fullName = 'A Guest' }) -Context @{ State = $state }
            $u = UserNamed 'guest'
            $u['password'] | Should -Be 'winpkgs-setup'
            $u['passwordExpired'] | Should -BeTrue
            $u['fullName'] | Should -Be 'A Guest'
            @($state['owned']['users']) | Should -Be @($u['sid'])
            # Expired last: setting anything after the password would clear it.
            (Get-Log)[-1] | Should -Be "expire-user $($u['sid'])"
        }

        It 'is created with a blank password when there is no initial one, still to be changed' {
            Converge 'winpkgs/localUser' (New-UserProps @{ initialPassword = $null })
            $u = UserNamed 'guest'
            $u['password'] | Should -Be ''
            $u['passwordExpired'] | Should -BeTrue
        }

        It 'is not expired when Windows would never ask for the change' {
            Converge 'winpkgs/localUser' (New-UserProps @{ passwordNeverExpires = $true })
            (UserNamed 'guest')['passwordExpired'] | Should -BeFalse
            Reset-Sam
            Converge 'winpkgs/localUser' (New-UserProps @{ userMayChangePassword = $false })
            $u = UserNamed 'guest'
            $u['passwordExpired'] | Should -BeFalse
            $u['userMayChangePassword'] | Should -BeFalse
        }

        It 'joins the accounts a membership resolves, so the same apply can add it to a group' {
            $state = Read-WinPkgsState -Kind system
            $member = @{ group = $Users; member = 'guest' }
            # Read before the account exists, as the plan is.
            $planned = Invoke-Res 'winpkgs/groupMember' Get $member
            $planned['accountExists'] | Should -BeFalse
            Converge 'winpkgs/localUser' (New-UserProps) -Context @{ State = $state }
            Invoke-Res 'winpkgs/groupMember' Set $member -Current $planned -Context @{ State = $state }
            (Sam)['groups'][$Users]['members'] | Should -Contain (UserNamed 'guest')['sid']
        }

        It 'says how it will be created, and never the password' {
            $p = New-UserProps
            $d = Invoke-Res 'winpkgs/localUser' Describe $p -Current (Invoke-Res 'winpkgs/localUser' Get $p)
            $d | Should -Be 'no such account -> created with the initial password, to be changed at the first sign-in'
            $d | Should -Not -Match 'winpkgs-setup'
        }
    }

    Context 'an account that is already there' {
        It 'is in state when nothing declared differs, whatever it was created with' {
            $p = New-UserProps @{ name = 'CALEB' }
            Invoke-Res 'winpkgs/localUser' Test $p -Current (Invoke-Res 'winpkgs/localUser' Get $p) | Should -BeTrue
        }

        It 'has its declared settings kept, and its password left alone, and is not owned' {
            $state = Read-WinPkgsState -Kind system
            Converge 'winpkgs/localUser' (New-UserProps @{ name = 'caleb'; fullName = 'Caleb Stewart'; passwordNeverExpires = $false }) -Context @{ State = $state }
            $u = UserNamed 'caleb'
            $u['fullName'] | Should -Be 'Caleb Stewart'
            $u['passwordNeverExpires'] | Should -BeFalse
            $u['password'] | Should -Be 'secret'
            $u['passwordExpired'] | Should -BeFalse
            @($state['owned']['users']) | Should -Be @()
            Get-Log | Should -Be @("set-user $Caleb fullName,passwordNeverExpires")
        }
    }

    Context 'prune' {
        It 'deletes an account it created, and forgets it' {
            $state = Read-WinPkgsState -Kind system
            Converge 'winpkgs/localUser' (New-UserProps) -Context @{ State = $state }
            $sid = (UserNamed 'guest')['sid']
            Invoke-Res 'winpkgs/localUser' Remove @{ sid = $sid } -Context @{ State = $state }
            UserNamed 'guest' | Should -BeNullOrEmpty
            (Sam)['accounts'].ContainsKey('guest') | Should -BeFalse
            @($state['owned']['users']) | Should -Be @()
        }

        It 'plans a remove only under prune.users, for an owned account no longer declared' {
            $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $state = Read-WinPkgsState -Kind system
            Converge 'winpkgs/localUser' (New-UserProps) -Context @{ State = $state }
            Converge 'winpkgs/localUser' (New-UserProps @{ name = 'other' }) -Context @{ State = $state }
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
            $doc = @{
                kind = 'system'; root = $TestDrive
                settings = @{ prune = @{ users = $false } }
                resources = @(@{ type = 'winpkgs/localUser'; id = 'User other'; scope = 'machine'; properties = New-UserProps @{ name = 'other' } })
            }
            @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
            $doc['settings']['prune']['users'] = $true
            $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
            $removes.Count | Should -Be 1
            $removes[0].Id | Should -Be 'User guest'
            $removes[0].Resource['properties']['sid'] | Should -Be (UserNamed 'guest')['sid']
        }
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/localUser'
    }
}

Describe 'winpkgs/localGroup' {
    BeforeEach { Reset-Sam }

    It 'creates a group that is not there, owns it, and describes it' {
        $state = Read-WinPkgsState -Kind system
        $p = @{ name = 'developers'; description = 'People who build things' }
        Invoke-Res 'winpkgs/localGroup' Describe $p -Current (Invoke-Res 'winpkgs/localGroup' Get $p) | Should -Be 'no such group -> created'
        Converge 'winpkgs/localGroup' $p -Context @{ State = $state }
        $g = Invoke-Res 'winpkgs/localGroup' Get $p
        $g['exists'] | Should -BeTrue
        $g['description'] | Should -Be 'People who build things'
        @($state['owned']['groups']) | Should -Be @($g['sid'])
    }

    It 'manages one that is already there: its description when declared, never ownership' {
        $state = Read-WinPkgsState -Kind system
        Invoke-Res 'winpkgs/localGroup' Test @{ name = 'Docker-Users'; description = $null } -Current (Invoke-Res 'winpkgs/localGroup' Get @{ name = 'docker-users' }) | Should -BeTrue
        Converge 'winpkgs/localGroup' @{ name = 'docker-users'; description = 'Containers' } -Context @{ State = $state }
        (Sam)['groups'][$Docker]['description'] | Should -Be 'Containers'
        @($state['owned']['groups']) | Should -Be @()
        Get-Log | Should -Be @("describe-group $Docker")
    }

    It 'lets a membership in the same apply find the group it created' {
        $state = Read-WinPkgsState -Kind system
        $member = @{ group = 'developers'; member = 'caleb' }
        $planned = Invoke-Res 'winpkgs/groupMember' Get $member
        $planned['groupExists'] | Should -BeFalse
        Converge 'winpkgs/localGroup' @{ name = 'developers'; description = $null } -Context @{ State = $state }
        Invoke-Res 'winpkgs/groupMember' Set $member -Current $planned -Context @{ State = $state }
        $sid = (Invoke-Res 'winpkgs/localGroup' Get @{ name = 'developers' })['sid']
        (Sam)['groups'][$sid]['members'] | Should -Be @($Caleb)
    }

    It 'prunes a group it created and no longer declared, and only under prune.groups' {
        $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $state = Read-WinPkgsState -Kind system
        Converge 'winpkgs/localGroup' @{ name = 'developers'; description = $null } -Context @{ State = $state }
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
        $sid = (Invoke-Res 'winpkgs/localGroup' Get @{ name = 'developers' })['sid']
        $doc = @{ kind = 'system'; root = $TestDrive; settings = @{ prune = @{ groups = $false } }; resources = @() }
        @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
        $doc['settings']['prune']['groups'] = $true
        $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
        $removes.Count | Should -Be 1
        $removes[0].Id | Should -Be 'Group developers'

        Invoke-Res 'winpkgs/localGroup' Get $removes[0].Resource['properties'] | ForEach-Object { $_['exists'] } | Should -BeTrue
        Invoke-Res 'winpkgs/localGroup' Remove $removes[0].Resource['properties'] -Context @{ State = $state }
        (Sam)['groups'].ContainsKey($sid) | Should -BeFalse
        @($state['owned']['groups']) | Should -Be @()
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/localGroup'
    }
}
