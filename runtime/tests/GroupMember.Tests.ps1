# winpkgs/groupMember against a stand-in for the accounts database: a JSON
# file of groups, their members and the accounts a name resolves to, and a
# log of every add and remove. Changing a real group's membership takes
# elevation and changes who may do what on the machine the suite runs on.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $env:WINPKGS_GROUP_STATE = Join-Path $TestDrive 'accounts.json'
    $env:WINPKGS_GROUP_LOG = Join-Path $TestDrive 'sam.log'
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    $script:HyperV = 'S-1-5-32-578'
    $script:Admins = 'S-1-5-32-544'
    $script:Caleb = 'S-1-5-21-1-2-3-1001'
    $script:Other = 'S-1-5-21-1-2-3-1002'
    $script:Gone = 'S-1-5-21-1-2-3-1003'     # an account that no longer exists

    function Reset-Sam {
        @{
            groups   = @{
                $HyperV = @{ name = 'Hyper-V-Administratoren'; members = @() }     # a German Windows
                $Admins = @{ name = 'Administratoren'; members = @($Caleb) }
                'S-1-5-21-1-2-3-1050' = @{ name = 'docker-users'; members = @($Gone) }
            }
            accounts = @{ 'caleb' = $Caleb; 'other' = $Other }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Encoding utf8
        Remove-Item -LiteralPath $env:WINPKGS_GROUP_LOG -ErrorAction SilentlyContinue
    }

    function Get-Log {
        if (Test-Path -LiteralPath $env:WINPKGS_GROUP_LOG) { return @(Get-Content -LiteralPath $env:WINPKGS_GROUP_LOG) }
        return @()
    }

    function Members([string]$Sid) {
        $db = Get-Content -LiteralPath $env:WINPKGS_GROUP_STATE -Raw | ConvertFrom-WinPkgsJson
        return @($db['groups'][$Sid]['members'])
    }

    function Invoke-Member([string]$Operation, [hashtable]$Properties, [hashtable]$Current, [hashtable]$Context = @{}) {
        $args = @{ Type = 'winpkgs/groupMember'; Operation = $Operation; Properties = $Properties; Context = $Context }
        if ($Current) { $args['Current'] = $Current }
        Invoke-WinPkgsResource @args
    }

    function Converge([hashtable]$Properties, [hashtable]$Context = @{}) {
        $current = Invoke-Member Get $Properties
        Invoke-Member Set $Properties -Current $current -Context $Context
    }
}

AfterAll {
    foreach ($v in 'WINPKGS_GROUP_STATE', 'WINPKGS_GROUP_LOG', 'WINPKGS_STATE_DIR') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'winpkgs/groupMember' {
    BeforeEach { Reset-Sam }

    Context 'reading a membership' {
        It 'finds a built-in group by SID whatever the machine calls it, and the account by name' {
            $s = Invoke-Member Get @{ group = $HyperV; member = 'caleb' }
            $s['groupExists'] | Should -BeTrue
            $s['accountExists'] | Should -BeTrue
            $s['exists'] | Should -BeFalse
            $s['group'] | Should -Be 'Hyper-V-Administratoren'
            $s['memberSid'] | Should -Be $Caleb
        }

        It 'finds a group by name, and a member by SID' {
            $s = Invoke-Member Get @{ group = 'docker-users'; member = $Gone }
            $s['groupExists'] | Should -BeTrue
            $s['exists'] | Should -BeTrue
            $s['groupSid'] | Should -Be 'S-1-5-21-1-2-3-1050'
        }

        It 'compares by SID, so a member is one whatever it was spelled as' {
            (Invoke-Member Get @{ group = 'Administratoren'; member = 'CALEB' })['exists'] | Should -BeTrue
            (Invoke-Member Get @{ group = $Admins; member = $Caleb })['exists'] | Should -BeTrue
            (Invoke-Member Get @{ group = $Admins; member = 'other' })['exists'] | Should -BeFalse
        }

        It 'reports a group that is not there' {
            $s = Invoke-Member Get @{ group = 'no-such-group'; member = 'caleb' }
            $s['exists'] | Should -BeFalse
            $s['groupExists'] | Should -BeFalse
        }

        It 'reports an account that is not there' {
            $s = Invoke-Member Get @{ group = $HyperV; member = 'nobody' }
            $s['exists'] | Should -BeFalse
            $s['groupExists'] | Should -BeTrue
            $s['accountExists'] | Should -BeFalse
        }
    }

    Context 'what counts as being in state' {
        It 'is being a member, and nothing else' {
            Invoke-Member Test @{ } -Current @{ exists = $true } | Should -BeTrue
            Invoke-Member Test @{ } -Current @{ exists = $false; groupExists = $true; accountExists = $true } | Should -BeFalse
            Invoke-Member Test @{ } -Current @{ exists = $false; groupExists = $false } | Should -BeFalse
        }
    }

    Context 'adding one' {
        It 'adds the member by SID and owns the membership' {
            $state = Read-WinPkgsState -Kind system
            Converge @{ group = $HyperV; member = 'caleb' } -Context @{ State = $state }
            Members $HyperV | Should -Be @($Caleb)
            Get-Log | Should -Be @("add $HyperV $Caleb")
            @($state['owned']['groupMembers']) | Should -Be @("$HyperV/$Caleb")
            $p = @{ group = $HyperV; member = 'caleb' }
            Invoke-Member Test $p -Current (Invoke-Member Get $p) | Should -BeTrue
        }

        It 'does not own a member that was already there: a plan for one is a noop' {
            $p = @{ group = $Admins; member = 'caleb' }
            Invoke-Member Test $p -Current (Invoke-Member Get $p) | Should -BeTrue
            Get-Log | Should -Be @()
        }

        It 'refuses a group that is not there, rather than creating one' {
            { Converge @{ group = 'no-such-group'; member = 'caleb' } } | Should -Throw "*No local group 'no-such-group'*"
            Get-Log | Should -Be @()
        }

        It 'refuses an account that is not there, naming it' {
            { Converge @{ group = $HyperV; member = 'nobody' } } | Should -Throw "*No account named 'nobody'*"
            Get-Log | Should -Be @()
        }
    }

    Context 'prune' {
        It 'removes a member it added and forgets it' {
            $state = Read-WinPkgsState -Kind system
            Converge @{ group = $HyperV; member = 'caleb' } -Context @{ State = $state }
            Remove-Item -LiteralPath $env:WINPKGS_GROUP_LOG
            Invoke-Member Remove @{ group = $HyperV; member = $Caleb } -Context @{ State = $state }
            Members $HyperV | Should -Be @()
            Get-Log | Should -Be @("remove $HyperV $Caleb")
            @($state['owned']['groupMembers']) | Should -Not -Contain "$HyperV/$Caleb"
        }

        It 'removes a member whose account is gone: what a deleted user leaves behind' {
            $state = Read-WinPkgsState -Kind system
            $state['owned']['groupMembers'] = @("S-1-5-21-1-2-3-1050/$Gone")
            Invoke-Member Remove @{ group = 'S-1-5-21-1-2-3-1050'; member = $Gone } -Context @{ State = $state }
            Members 'S-1-5-21-1-2-3-1050' | Should -Be @()
            @($state['owned']['groupMembers']) | Should -Be @()
        }

        It 'forgets one that was already removed by hand, without touching the group' {
            $state = Read-WinPkgsState -Kind system
            $state['owned']['groupMembers'] = @("$HyperV/$Caleb")
            Invoke-Member Remove @{ group = $HyperV; member = $Caleb } -Context @{ State = $state }
            Get-Log | Should -Be @()
            @($state['owned']['groupMembers']) | Should -Be @()
        }

        It 'plans a remove for an owned membership the document no longer declares, matching names to SIDs' {
            $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            @{ owned = @{ winget = @(); files = @(); services = @(); features = @()
                          groupMembers = @("$HyperV/$Caleb", "$HyperV/$Other") } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
            $doc = @{
                kind = 'system'; root = $TestDrive
                settings = @{ prune = @{ winget = $false; files = $false; services = $false; features = $false; groupMembers = $true } }
                resources = @(@{ type = 'winpkgs/groupMember'; id = 'Group Hyper-V Administrators: caleb'; scope = 'machine'
                                 properties = @{ group = $HyperV; member = 'caleb' } })
            }
            $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
            $removes.Count | Should -Be 1
            $removes[0].Id | Should -Be 'Group Hyper-V-Administratoren: other'
            $removes[0].Resource['properties']['group'] | Should -Be $HyperV
            $removes[0].Resource['properties']['member'] | Should -Be $Other
            $doc['settings']['prune']['groupMembers'] = $false
            @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
        }
    }

    Context 'what a plan says' {
        It 'says the membership waits for a sign-in, and names what is missing' {
            $p = @{ group = $HyperV; member = 'caleb' }
            Invoke-Member Describe $p -Current (Invoke-Member Get $p) |
                Should -Be 'caleb is not a member -> member; from their next sign-in'
            $p = @{ group = 'no-such-group'; member = 'caleb' }
            Invoke-Member Describe $p -Current (Invoke-Member Get $p) | Should -Be 'no local group no-such-group'
            $p = @{ group = $HyperV; member = 'nobody' }
            Invoke-Member Describe $p -Current (Invoke-Member Get $p) | Should -Be 'no account named nobody'
        }
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/groupMember'
    }
}

# What the stand-in cannot show: that the machine resolves the names the module
# carries, unelevated. Reads only.
Describe 'winpkgs/groupMember: the machine' {
    BeforeAll {
        $script:SavedState = $env:WINPKGS_GROUP_STATE
        Remove-Item Env:\WINPKGS_GROUP_STATE -ErrorAction SilentlyContinue
    }
    AfterAll { $env:WINPKGS_GROUP_STATE = $SavedState }

    It 'finds the built-in Administrators group by its well-known SID' {
        InModuleScope WinPkgs {
            $g = Find-WinPkgsLocalGroup -Group 'S-1-5-32-544'
            $g.sid | Should -Be 'S-1-5-32-544'
            $g.name | Should -Not -BeNullOrEmpty
        }
    }

    It 'resolves the current user, and reads a group''s members, without elevation' {
        InModuleScope WinPkgs {
            $me = Resolve-WinPkgsAccount -Member $env:USERNAME
            $me.sid | Should -Match '^S-1-5-21-'
            $null -eq (Find-WinPkgsLocalGroup -Group 'winpkgs-no-such-group') | Should -BeTrue
            $null -eq (Resolve-WinPkgsAccount -Member 'winpkgs-no-such-account') | Should -BeTrue
            # Administrators always has at least one member.
            @(Get-WinPkgsLocalGroupMemberSid -GroupSid 'S-1-5-32-544').Count | Should -BeGreaterThan 0
        }
    }
}
