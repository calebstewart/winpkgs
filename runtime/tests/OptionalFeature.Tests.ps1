# winpkgs/optionalFeature against a stand-in for DISM: a file of feature states
# and a log of what was enabled and disabled. Enabling a real feature takes
# elevation and, for the ones worth declaring, a restart -- not something a
# test suite does to the machine it runs on.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $env:WINPKGS_FEATURE_STATE = Join-Path $TestDrive 'features.txt'
    $env:WINPKGS_FEATURE_LOG = Join-Path $TestDrive 'dism.log'
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    function Reset-Dism {
        Set-Content -LiteralPath $env:WINPKGS_FEATURE_STATE -Value @(
            'Microsoft-Hyper-V-All=disabled'
            'Containers-DisposableClientVM=disabled'
            'VirtualMachinePlatform=enabled'
        )
        Remove-Item -LiteralPath $env:WINPKGS_FEATURE_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\WINPKGS_FEATURE_RESTART -ErrorAction SilentlyContinue
        InModuleScope WinPkgs { $script:RestartRequired = $false; $script:RestartReasons.Clear() }
    }

    function Get-Log {
        if (Test-Path -LiteralPath $env:WINPKGS_FEATURE_LOG) { return @(Get-Content -LiteralPath $env:WINPKGS_FEATURE_LOG) }
        return @()
    }

    function State([string]$Name) {
        foreach ($line in Get-Content -LiteralPath $env:WINPKGS_FEATURE_STATE) {
            if ($line -match "^$([regex]::Escape($Name))=(.*)$") { return $Matches[1] }
        }
        return $null
    }

    function Invoke-Feature([string]$Operation, [hashtable]$Properties, [hashtable]$Current, [hashtable]$Context = @{}) {
        $args = @{ Type = 'winpkgs/optionalFeature'; Operation = $Operation; Properties = $Properties; Context = $Context }
        if ($Current) { $args['Current'] = $Current }
        Invoke-WinPkgsResource @args
    }

    function Converge([hashtable]$Properties, [hashtable]$Context = @{}) {
        $current = Invoke-Feature Get $Properties
        Invoke-Feature Set $Properties -Current $current -Context $Context
    }

    function HyperV([bool]$Enabled = $true) { @{ name = 'Microsoft-Hyper-V-All'; enabled = $Enabled } }
}

AfterAll {
    foreach ($v in 'WINPKGS_FEATURE_STATE', 'WINPKGS_FEATURE_LOG', 'WINPKGS_FEATURE_RESTART', 'WINPKGS_STATE_DIR') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'winpkgs/optionalFeature' {
    BeforeEach { Reset-Dism }

    Context 'reading a feature' {
        It 'reads its state' {
            (Invoke-Feature Get (HyperV))['state'] | Should -Be 'disabled'
            (Invoke-Feature Get @{ name = 'VirtualMachinePlatform' })['state'] | Should -Be 'enabled'
        }

        It 'reports one this Windows does not have' {
            $s = Invoke-Feature Get @{ name = 'Nope-Nope' }
            $s['exists'] | Should -BeFalse
            $s['state'] | Should -Be 'absent'
        }

        It 'maps what DISM calls the states to its own words' {
            InModuleScope WinPkgs {
                ConvertFrom-WinPkgsDismFeatureState -State 'Enabled' | Should -Be 'enabled'
                ConvertFrom-WinPkgsDismFeatureState -State 'Disabled' | Should -Be 'disabled'
                ConvertFrom-WinPkgsDismFeatureState -State 'DisabledWithPayloadRemoved' | Should -Be 'disabled'
                ConvertFrom-WinPkgsDismFeatureState -State 'EnablePending' | Should -Be 'enablePending'
                ConvertFrom-WinPkgsDismFeatureState -State 'DisablePending' | Should -Be 'disablePending'
                ConvertFrom-WinPkgsDismFeatureState -State 'NotPresent' | Should -Be 'absent'
                ConvertFrom-WinPkgsDismFeatureState -State 'Staged' | Should -Be 'unknown'
            }
        }
    }

    Context 'what counts as being in state' {
        It 'is satisfied by the declared state' {
            Invoke-Feature Test (HyperV $false) -Current @{ exists = $true; state = 'disabled' } | Should -BeTrue
            Invoke-Feature Test (HyperV $true) -Current @{ exists = $true; state = 'enabled' } | Should -BeTrue
            Invoke-Feature Test (HyperV $true) -Current @{ exists = $true; state = 'disabled' } | Should -BeFalse
            Invoke-Feature Test (HyperV $false) -Current @{ exists = $true; state = 'enabled' } | Should -BeFalse
        }

        It 'counts a change waiting on a restart as made: asking again would only ask for the restart again' {
            Invoke-Feature Test (HyperV $true) -Current @{ exists = $true; state = 'enablePending' } | Should -BeTrue
            Invoke-Feature Test (HyperV $false) -Current @{ exists = $true; state = 'disablePending' } | Should -BeTrue
            Invoke-Feature Test (HyperV $false) -Current @{ exists = $true; state = 'enablePending' } | Should -BeFalse
        }

        It 'counts a feature that is not there as disabled' {
            Invoke-Feature Test @{ name = 'Nope'; enabled = $false } -Current @{ exists = $false; state = 'absent' } | Should -BeTrue
            Invoke-Feature Test @{ name = 'Nope'; enabled = $true } -Current @{ exists = $false; state = 'absent' } | Should -BeFalse
        }

        It 'is not satisfied by a state it does not understand' {
            Invoke-Feature Test (HyperV $true) -Current @{ exists = $true; state = 'unknown' } | Should -BeFalse
        }
    }

    Context 'changing one' {
        It 'enables it, owns it, and asks for no restart when none is needed' {
            $state = Read-WinPkgsState -Kind system
            Converge (HyperV) -Context @{ State = $state }
            State 'Microsoft-Hyper-V-All' | Should -Be 'enabled'
            Get-Log | Should -Be @('enable Microsoft-Hyper-V-All')
            @($state['owned']['features']) | Should -Contain 'Microsoft-Hyper-V-All'
            Test-WinPkgsRestartRequired | Should -BeFalse
            Invoke-Feature Test (HyperV) -Current (Invoke-Feature Get (HyperV)) | Should -BeTrue
        }

        It 'reports the restart a feature needs, and is in state until it happens' {
            $env:WINPKGS_FEATURE_RESTART = 'Microsoft-Hyper-V-All'
            Converge (HyperV)
            State 'Microsoft-Hyper-V-All' | Should -Be 'enablePending'
            Test-WinPkgsRestartRequired | Should -BeTrue
            $reasons = Get-WinPkgsRestartReasons
            $reasons -contains 'Feature Microsoft-Hyper-V-All' | Should -BeTrue
            Invoke-Feature Test (HyperV) -Current (Invoke-Feature Get (HyperV)) | Should -BeTrue
        }

        It 'disables one that is declared false, whoever enabled it, and forgets owning it' {
            $state = Read-WinPkgsState -Kind system
            $state['owned']['features'] = @('VirtualMachinePlatform')
            Converge @{ name = 'VirtualMachinePlatform'; enabled = $false } -Context @{ State = $state }
            State 'VirtualMachinePlatform' | Should -Be 'disabled'
            Get-Log | Should -Be @('disable VirtualMachinePlatform')
            @($state['owned']['features']) | Should -Not -Contain 'VirtualMachinePlatform'
        }

        It 'refuses to enable a feature this Windows does not have, naming it' {
            { Converge @{ name = 'Nope-Nope'; enabled = $true } } | Should -Throw '*No optional feature named Nope-Nope*'
            Get-Log | Should -Be @()
        }

        It 'does not own a feature that was already enabled' {
            # Set is only ever called when Test fails, so nothing to own here;
            # the point is the plan: an enabled feature declared true is a noop.
            $p = @{ name = 'VirtualMachinePlatform'; enabled = $true }
            Invoke-Feature Test $p -Current (Invoke-Feature Get $p) | Should -BeTrue
        }
    }

    Context 'prune' {
        It 'disables a feature it enabled and forgets it' {
            $state = Read-WinPkgsState -Kind system
            Converge (HyperV) -Context @{ State = $state }
            Remove-Item -LiteralPath $env:WINPKGS_FEATURE_LOG
            Invoke-Feature Remove @{ name = 'Microsoft-Hyper-V-All' } -Context @{ State = $state }
            State 'Microsoft-Hyper-V-All' | Should -Be 'disabled'
            Get-Log | Should -Be @('disable Microsoft-Hyper-V-All')
            @($state['owned']['features']) | Should -Not -Contain 'Microsoft-Hyper-V-All'
        }

        It 'forgets one that is already disabled, without touching it' {
            $state = Read-WinPkgsState -Kind system
            $state['owned']['features'] = @('Microsoft-Hyper-V-All')
            Invoke-Feature Remove @{ name = 'Microsoft-Hyper-V-All' } -Context @{ State = $state }
            Get-Log | Should -Be @()
            @($state['owned']['features']) | Should -Not -Contain 'Microsoft-Hyper-V-All'
        }

        It 'plans a remove for an owned feature the document no longer declares, and only that' {
            $dir = Join-Path $env:WINPKGS_STATE_DIR 'system'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            @{ owned = @{ winget = @(); files = @(); services = @(); features = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform') } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding utf8
            $doc = @{
                kind = 'system'; root = $TestDrive
                settings = @{ prune = @{ winget = $false; files = $false; services = $false; features = $true } }
                resources = @(@{ type = 'winpkgs/optionalFeature'; id = 'Feature VirtualMachinePlatform'; scope = 'machine'
                                 properties = @{ name = 'VirtualMachinePlatform'; enabled = $true } })
            }
            $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
            $removes.Count | Should -Be 1
            $removes[0].Id | Should -Be 'Feature Microsoft-Hyper-V-All'
            $removes[0].Resource['properties']['name'] | Should -Be 'Microsoft-Hyper-V-All'
            $doc['settings']['prune']['features'] = $false
            @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
        }
    }

    Context 'what a plan says' {
        It 'names both ends' {
            Invoke-Feature Describe (HyperV) -Current @{ exists = $true; state = 'disabled' } | Should -Be 'disabled -> enabled'
            Invoke-Feature Describe (HyperV $false) -Current @{ exists = $true; state = 'enablePending' } |
                Should -Be 'enabled after a restart -> disabled'
            Invoke-Feature Describe @{ name = 'Nope'; enabled = $true } -Current @{ exists = $false; state = 'absent' } |
                Should -Be 'not present -> enabled'
        }
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/optionalFeature'
    }
}
