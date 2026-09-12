# winpkgs/service against a stand-in. WINPKGS_SERVICE_ROOT puts the services
# under a test key in HKCU, which then also plays the service control manager:
# creating a real service takes elevation, and a test suite has no business
# creating one on the machine it runs on. What the stand-in cannot show is the
# SCM API itself; the registry layout it writes is the one Windows keeps.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $script:TestKey = "Software\winpkgs-tests\services-$PID"
    $script:KeyRoot = "Registry::HKEY_CURRENT_USER\$TestKey"
    $env:WINPKGS_SERVICE_ROOT = "HKCU\$TestKey"
    $env:WINPKGS_SERVICE_LOG = Join-Path $TestDrive 'scm.log'
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    function Reset-Scm {
        Remove-Item -LiteralPath $KeyRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $KeyRoot -Force | Out-Null
        Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG -ErrorAction SilentlyContinue
    }

    function Get-Log {
        if (Test-Path -LiteralPath $env:WINPKGS_SERVICE_LOG) { return @(Get-Content -LiteralPath $env:WINPKGS_SERVICE_LOG) }
        return @()
    }

    # A service as Windows would have it; Type 0xD0 is an instance of a template.
    function New-FakeService {
        param([string]$Name, [int]$Type = 0x10, [int]$Start = 3, [string]$Command = 'C:\old.exe',
              [string]$Account = 'LocalSystem', [switch]$Running, [byte[]]$FailureActions, [string]$Revision)
        $path = "$KeyRoot\$Name"
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -LiteralPath $path -Name Type -Value $Type -Type DWord
        Set-ItemProperty -LiteralPath $path -Name Start -Value $Start -Type DWord
        Set-ItemProperty -LiteralPath $path -Name ImagePath -Value $Command -Type ExpandString
        Set-ItemProperty -LiteralPath $path -Name DisplayName -Value $Name -Type String
        Set-ItemProperty -LiteralPath $path -Name ObjectName -Value $Account -Type String
        if ($FailureActions) { Set-ItemProperty -LiteralPath $path -Name FailureActions -Value $FailureActions -Type Binary }
        if ($Revision) { Set-ItemProperty -LiteralPath $path -Name WinPkgsRevision -Value $Revision -Type String }
        if ($Running) { Set-ItemProperty -LiteralPath $path -Name WinPkgsTestRunning -Value 1 -Type DWord }
    }

    function Value([string]$Name, [string]$Value) {
        (Get-Item -LiteralPath "$KeyRoot\$Name").GetValue($Value, $null, 'DoNotExpandEnvironmentNames')
    }

    function Steward([hashtable]$Override = @{}) {
        $p = @{
            name = 'steward'; displayName = 'steward'; description = 'A per-user service manager'
            command = '"C:\Program Files\steward\steward.exe"'; type = 'userOwn'; startType = 'automatic'
            account = $null; revision = 'r1'
            failureActions = @{ reset = 60; actions = @(@{ action = 'restart'; delay = 5000 }, @{ action = 'restart'; delay = 5000 }) }
        }
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        return $p
    }

    function Invoke-Service([string]$Operation, [hashtable]$Properties, [hashtable]$Current, [hashtable]$Before, [hashtable]$Context = @{}) {
        $args = @{ Type = 'winpkgs/service'; Operation = $Operation; Properties = $Properties; Context = $Context }
        if ($Current) { $args['Current'] = $Current }
        if ($Before) { $args['Before'] = $Before }
        Invoke-WinPkgsResource @args
    }

    function Converge([hashtable]$Properties, [hashtable]$Context = @{}) {
        $current = Invoke-Service Get $Properties
        Invoke-Service Set $Properties -Current $current -Context $Context
    }

    # W32Time's value on the machine this was written on: reset a day, then
    # restart after a minute, restart after two, nothing.
    $script:W32TimeFailureActions = [byte[]](0x80, 0x51, 0x01, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x03, 0, 0, 0, 0x14, 0, 0, 0,
        0x01, 0, 0, 0, 0x60, 0xEA, 0, 0, 0x01, 0, 0, 0, 0xC0, 0xD4, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

AfterAll {
    Remove-Item -LiteralPath $KeyRoot -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'WINPKGS_SERVICE_ROOT', 'WINPKGS_SERVICE_LOG', 'WINPKGS_STATE_DIR') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

Describe 'winpkgs/service' {
    BeforeEach { Reset-Scm }

    Context 'reading a service' {
        It 'reports one that is not there' {
            (Invoke-Service Get @{ name = 'nothere' })['exists'] | Should -BeFalse
        }

        It 'reads its definition from the key, failure actions included' {
            New-FakeService -Name 'w32time' -Type 0x20 -Start 2 -Command '%SystemRoot%\system32\svchost.exe -k LocalService' `
                -Account 'NT AUTHORITY\LocalService' -FailureActions $W32TimeFailureActions
            Set-ItemProperty -LiteralPath "$KeyRoot\w32time" -Name DelayedAutostart -Value 1 -Type DWord
            $s = Invoke-Service Get @{ name = 'w32time' }
            $s['exists'] | Should -BeTrue
            $s['type'] | Should -Be 'share'
            $s['startType'] | Should -Be 'delayedAutomatic'
            $s['command'] | Should -Be '%SystemRoot%\system32\svchost.exe -k LocalService'   # not expanded
            $s['account'] | Should -Be 'NT AUTHORITY\LocalService'
            $s['failureActions']['reset'] | Should -Be 86400
            @($s['failureActions']['actions']).Count | Should -Be 3
            $s['failureActions']['actions'][0]['action'] | Should -Be 'restart'
            $s['failureActions']['actions'][1]['delay'] | Should -Be 120000
            $s['failureActions']['actions'][2]['action'] | Should -Be 'none'
        }

        It 'finds a template''s instances, and only its own' {
            New-FakeService -Name 'steward' -Type 0x50 -Start 2
            New-FakeService -Name 'steward_9eb32b' -Type 0xD0 -Start 2
            New-FakeService -Name 'steward_extra' -Type 0x10       # not hex, not an instance
            New-FakeService -Name 'stewardess_1' -Type 0xD0        # another template's
            $s = Invoke-Service Get @{ name = 'steward' }
            $s['type'] | Should -Be 'userOwn'
            @($s['instances']).Count | Should -Be 1
            $s['instances'][0]['name'] | Should -Be 'steward_9eb32b'
            $s['instances'][0]['instance'] | Should -BeTrue
        }
    }

    Context 'what counts as being in state' {
        It 'is satisfied by exactly the declared definition' {
            $p = Steward
            Converge $p
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeTrue
        }

        It 'notices each part that differs' {
            Converge (Steward)
            foreach ($o in @(
                    @{ command = '"C:\Program Files\steward\new\steward.exe"' },
                    @{ startType = 'manual' },
                    @{ description = 'something else' },
                    @{ displayName = 'Steward' },
                    @{ failureActions = @{ reset = 60; actions = @(@{ action = 'restart'; delay = 1000 }) } },
                    @{ revision = 'r2' })) {
                $p = Steward $o
                Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeFalse -Because ($o.Keys -join ',')
            }
        }

        It 'leaves what is not declared alone' {
            New-FakeService -Name 'svc' -Start 2 -Command 'C:\svc.exe' -FailureActions $W32TimeFailureActions
            Set-ItemProperty -LiteralPath "$KeyRoot\svc" -Name Description -Value 'theirs'
            $p = @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'automatic'; description = $null; failureActions = $null; revision = $null }
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeTrue
        }

        It 'takes no account as LocalSystem for an own-process service' {
            New-FakeService -Name 'svc' -Start 2 -Command 'C:\svc.exe' -Account 'LocalSystem'
            $p = @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'automatic' }
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeTrue
            $p['account'] = 'NT AUTHORITY\LocalService'
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeFalse
        }

        It 'is not satisfied while an instance runs an old definition' {
            Converge (Steward)
            New-FakeService -Name 'steward_9eb32b' -Type 0xD0 -Start 2 -Command '"C:\Program Files\steward\old\steward.exe"'
            $p = Steward
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeFalse
        }
    }

    Context 'creating one' {
        It 'creates the template, owns it, and starts nothing' {
            $state = Read-WinPkgsState -Kind system
            Converge (Steward) -Context @{ State = $state }
            Value 'steward' 'Type' | Should -Be 0x50
            Value 'steward' 'Start' | Should -Be 2
            Value 'steward' 'ImagePath' | Should -Be '"C:\Program Files\steward\steward.exe"'
            Value 'steward' 'Description' | Should -Be 'A per-user service manager'
            Value 'steward' 'WinPkgsRevision' | Should -Be 'r1'
            $fa = (Invoke-Service Get @{ name = 'steward' })['failureActions']
            $fa['reset'] | Should -Be 60
            @($fa['actions']).Count | Should -Be 2
            @($state['owned']['services']) | Should -Contain 'steward'
            Get-Log | Should -Be @('create steward')
        }

        It 'starts an own-process service that starts automatically, as a switch would' {
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'automatic' }
            Get-Log | Should -Be @('create svc', 'start svc')
            Value 'svc' 'ObjectName' | Should -Be 'LocalSystem'
        }

        It 'does not start one that is not automatic' {
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'manual' }
            Get-Log | Should -Be @('create svc')
        }
    }

    Context 'changing one' {
        It 'changes the template and every instance, and restarts the instances that run' {
            Converge (Steward)
            New-FakeService -Name 'steward_aaaa' -Type 0xD0 -Start 2 -Command '"C:\old.exe"' -Running
            New-FakeService -Name 'steward_bbbb' -Type 0xD0 -Start 2 -Command '"C:\old.exe"'
            Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG
            $p = Steward @{ command = '"C:\Program Files\steward\v2\steward.exe"'; revision = 'r2' }
            Converge $p
            foreach ($n in 'steward', 'steward_aaaa', 'steward_bbbb') {
                Value $n 'ImagePath' | Should -Be '"C:\Program Files\steward\v2\steward.exe"'
            }
            Value 'steward_aaaa' 'Type' | Should -Be 0xD0          # an instance stays an instance
            Get-Log | Should -Be @('stop steward_aaaa', 'start steward_aaaa')
            Invoke-Service Test $p -Current (Invoke-Service Get $p) | Should -BeTrue
        }

        It 'restarts for a new revision alone' {
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'manual'; revision = 'a' }
            Set-ItemProperty -LiteralPath "$KeyRoot\svc" -Name WinPkgsTestRunning -Value 1 -Type DWord
            Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'manual'; revision = 'b' }
            Get-Log | Should -Be @('stop svc', 'start svc')
            Value 'svc' 'WinPkgsRevision' | Should -Be 'b'
        }

        It 'ends what it restarts with the restart control, when there is one' {
            Converge (Steward @{ restartControl = 128 })
            New-FakeService -Name 'steward_aaaa' -Type 0xD0 -Start 2 -Command '"C:\Program Files\steward\steward.exe"' -Running
            Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG
            Converge (Steward @{ restartControl = 128; revision = 'r2' })
            Get-Log | Should -Be @('stop steward_aaaa with control 128', 'start steward_aaaa')
        }

        It 'stops a service that does not accept the restart control the ordinary way' {
            # The build being replaced may predate the control.
            Converge (Steward @{ restartControl = 128 })
            New-FakeService -Name 'steward_aaaa' -Type 0xD0 -Start 2 -Command '"C:\Program Files\steward\steward.exe"' -Running
            Set-ItemProperty -LiteralPath "$KeyRoot\steward_aaaa" -Name WinPkgsTestRejects -Value 1 -Type DWord
            Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG
            Converge (Steward @{ restartControl = 128; revision = 'r2' })
            Get-Log | Should -Be @('stop steward_aaaa', 'start steward_aaaa')
        }

        It 'does not restart for a description, or what is not running' {
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'manual'; description = 'one' }
            Converge @{ name = 'svc'; command = 'C:\svc2.exe'; startType = 'manual'; description = 'two' }
            Get-Log | Should -Be @('create svc')
        }

        It 'refuses to change a service''s type in place' {
            New-FakeService -Name 'steward' -Type 0x10 -Start 2
            { Converge (Steward) } | Should -Throw '*cannot be changed in place*'
        }

        It 'does not own a service it did not create' {
            New-FakeService -Name 'svc' -Start 3 -Command 'C:\svc.exe'
            $state = Read-WinPkgsState -Kind system
            Converge @{ name = 'svc'; command = 'C:\svc.exe'; startType = 'automatic' } -Context @{ State = $state }
            Value 'svc' 'Start' | Should -Be 2
            @($state['owned']['services']) | Should -Not -Contain 'svc'
        }
    }

    Context 'rollback and prune' {
        It 'deletes a service it created, instances first, and forgets owning it' {
            $state = Read-WinPkgsState -Kind system
            Converge (Steward) -Context @{ State = $state }
            New-FakeService -Name 'steward_aaaa' -Type 0xD0 -Start 2
            Remove-Item -LiteralPath $env:WINPKGS_SERVICE_LOG
            Invoke-Service Restore @{ name = 'steward' } -Before @{ exists = $false } -Context @{ State = $state }
            Test-Path -LiteralPath "$KeyRoot\steward" | Should -BeFalse
            Test-Path -LiteralPath "$KeyRoot\steward_aaaa" | Should -BeFalse
            Get-Log | Should -Be @('delete steward_aaaa', 'delete steward')
            @($state['owned']['services']) | Should -Not -Contain 'steward'
        }

        It 'puts back a definition it changed' {
            New-FakeService -Name 'svc' -Start 3 -Command 'C:\before.exe' -Revision 'old'
            $p = @{ name = 'svc'; command = 'C:\after.exe'; startType = 'automatic'; revision = 'new' }
            $before = Invoke-Service Get $p
            Invoke-Service Set $p -Current $before
            Invoke-Service Restore $p -Before $before
            Value 'svc' 'ImagePath' | Should -Be 'C:\before.exe'
            Value 'svc' 'Start' | Should -Be 3
            Value 'svc' 'WinPkgsRevision' | Should -Be 'old'
        }

        It 'brings back a service a prune deleted, owned again' {
            $state = Read-WinPkgsState -Kind system
            Converge (Steward) -Context @{ State = $state }
            $before = Invoke-Service Get @{ name = 'steward' }
            $before['owned'] = $true
            Invoke-Service Restore @{ name = 'steward' } -Before @{ exists = $false } -Context @{ State = $state }
            Invoke-Service Restore @{ name = 'steward' } -Before $before -Context @{ State = $state }
            Value 'steward' 'Type' | Should -Be 0x50
            Value 'steward' 'ImagePath' | Should -Be '"C:\Program Files\steward\steward.exe"'
            @($state['owned']['services']) | Should -Contain 'steward'
        }

        It 'plans a remove for an owned service the document no longer declares, and only that' {
            $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            @{ owned = @{ winget = @(); files = @(); services = @('steward', 'kept') } } | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
            New-FakeService -Name 'kept' -Start 3 -Command 'C:\kept.exe'
            $doc = @{
                kind = 'system'; root = $TestDrive
                settings = @{ prune = @{ winget = $false; files = $false; services = $true } }
                resources = @(@{ type = 'winpkgs/service'; id = 'Service kept'; scope = 'machine'
                                 properties = @{ name = 'kept'; command = 'C:\kept.exe'; startType = 'manual' } })
            }
            $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
            $removes.Count | Should -Be 1
            $removes[0].Id | Should -Be 'Service steward'
            $removes[0].Resource['properties']['name'] | Should -Be 'steward'
            $doc['settings']['prune']['services'] = $false
            @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
        }
    }

    Context 'what a plan says' {
        It 'describes a new service, and the parts of one that change' {
            Invoke-Service Describe (Steward) -Current @{ exists = $false } |
                Should -Be 'not present -> userOwn, automatic: "C:\Program Files\steward\steward.exe"'
            Converge (Steward)
            $p = Steward @{ startType = 'manual'; revision = 'r2' }
            Invoke-Service Describe $p -Current (Invoke-Service Get $p) | Should -Be 'automatic -> manual; new revision (restarts it)'
        }
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/service'
    }
}

# The stand-in skips the SCM API, so nothing above compiles it. Calling it
# would take elevation; compiling it, and what reaches it from PowerShell, do not.
Describe 'winpkgs/service: the SCM API' {
    It 'compiles on this host' {
        InModuleScope WinPkgs { Initialize-WinPkgsScm }
        'WinPkgs.Native.Scm' -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'passes no account as none, not as an account named ""' {
        # PowerShell converts $null to "" on its way into a string parameter.
        InModuleScope WinPkgs { Initialize-WinPkgsScm }
        $null -eq [WinPkgs.Native.Scm]::OrNull($null) | Should -BeTrue
        $null -eq [WinPkgs.Native.Scm]::OrNull('') | Should -BeTrue
        [WinPkgs.Native.Scm]::OrNull('NT AUTHORITY\LocalService') | Should -Be 'NT AUTHORITY\LocalService'
    }
}
