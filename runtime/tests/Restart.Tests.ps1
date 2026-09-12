# A change nothing short of a restart completes -- a driver's Start value, the
# computer's name -- has to reach whoever asked for the apply. The runtime never
# restarts the machine itself: it may be one step of several, or running while
# somebody is working.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
    # Inherited by the runtime these tests start: its generations, ledger and
    # generation policy act on the test drive, never on this user's own.
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    $Runtime = Join-Path $PSScriptRoot '..\winpkgs.ps1'
    $Pwsh = (Get-Process -Id $PID).Path

    function New-Doc {
        param([bool]$RestartMachine, [string]$Name)
        $key = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
        @{
            version   = 2
            kind      = 'home'
            name      = 'restart@test'
            settings  = @{ prune = @{ winget = $false; files = $false }; generations = @{ keep = 10; deleteOlderThan = '' } }
            resources = @(
                @{
                    type       = 'winpkgs/registry'
                    id         = "$key\$Name"
                    scope      = 'user'
                    properties = @{
                        key = $key; name = $Name; type = 'DWord'; value = 1
                        restartExplorer = $false
                        restartMachine  = $RestartMachine
                    }
                }
            )
        }
    }

    function Invoke-Runtime {
        param([hashtable]$Document)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $Document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        $out = & $Pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $Runtime apply -Config $path 2>&1 |
               ForEach-Object { "$_" }
        return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
    }
}

Describe 'a change that needs the machine restarted' {
    It 'is not signalled when nothing asks for it' {
        InModuleScope WinPkgs { Test-WinPkgsRestartRequired } | Should -BeFalse
    }

    It 'is remembered once, with the resource that wanted it' {
        InModuleScope WinPkgs {
            Set-WinPkgsRestartRequired -Because 'HKLM\SYSTEM\CurrentControlSet\Services\UCPD\Start'
            Set-WinPkgsRestartRequired -Because 'HKLM\SYSTEM\CurrentControlSet\Services\UCPD\Start'
            Test-WinPkgsRestartRequired | Should -BeTrue
            @(Get-WinPkgsRestartReasons).Count | Should -Be 1
            @(Get-WinPkgsRestartReasons)[0] | Should -BeLike '*UCPD\Start'
        }
    }

    It 'leaves the runtime with exit code 3010, and says why' {
        $r = Invoke-Runtime -Document (New-Doc -RestartMachine $true -Name 'RestartMe')
        $r.ExitCode | Should -Be 3010
        $r.Output | Should -BeLike '*restart is needed*'
        $r.Output | Should -BeLike '*RestartMe*'
    }

    It 'leaves with 0 when the same change asks for nothing' {
        $r = Invoke-Runtime -Document (New-Doc -RestartMachine $false -Name 'PlainValue')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -BeLike '*restart is needed*'
    }
}

AfterAll {
    Remove-Item -Recurse -Force 'HKCU:\Software\winpkgs-tests' -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
}
