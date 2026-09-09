# winpkgs/scheduledTask. The cmdlets are mocked: the tasks worth naming are
# Windows' own, under \Microsoft\Windows, and a test suite has no business
# disabling them on the machine it runs on.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Path = '\Microsoft\Windows\AppxDeploymentClient\'
    $Name = 'UCPD velocity'

    function Props([bool]$Enabled) {
        @{ path = $Path; name = $Name; enabled = $Enabled }
    }
}

Describe 'winpkgs/scheduledTask' {
    Context 'reading the machine' {
        It 'reports an enabled task' {
            InModuleScope WinPkgs {
                Mock Get-ScheduledTask { [pscustomobject]@{ Settings = [pscustomobject]@{ Enabled = $true } } }
                $s = Get-WinPkgsScheduledTaskState -Properties @{ path = '\x\'; name = 'y' } -Context @{}
                $s['exists'] | Should -BeTrue
                $s['enabled'] | Should -BeTrue
            }
        }

        It 'reports a disabled task' {
            InModuleScope WinPkgs {
                Mock Get-ScheduledTask { [pscustomobject]@{ Settings = [pscustomobject]@{ Enabled = $false } } }
                (Get-WinPkgsScheduledTaskState -Properties @{ path = '\x\'; name = 'y' } -Context @{})['enabled'] |
                    Should -BeFalse
            }
        }

        It 'reports one that is not there' {
            InModuleScope WinPkgs {
                Mock Get-ScheduledTask { $null }
                (Get-WinPkgsScheduledTaskState -Properties @{ path = '\x\'; name = 'y' } -Context @{})['exists'] |
                    Should -BeFalse
            }
        }
    }

    Context 'what counts as being in state' {
        It 'is satisfied when the task is already as declared' {
            InModuleScope WinPkgs {
                Test-WinPkgsScheduledTask -Properties @{ enabled = $false } -Current @{ exists = $true; enabled = $false } -Context @{} |
                    Should -BeTrue
            }
        }

        It 'is not satisfied when it differs' {
            InModuleScope WinPkgs {
                Test-WinPkgsScheduledTask -Properties @{ enabled = $false } -Current @{ exists = $true; enabled = $true } -Context @{} |
                    Should -BeFalse
            }
        }

        It 'counts a missing task as disabled: what is not there cannot run' {
            InModuleScope WinPkgs {
                Test-WinPkgsScheduledTask -Properties @{ enabled = $false } -Current @{ exists = $false } -Context @{} |
                    Should -BeTrue
                Test-WinPkgsScheduledTask -Properties @{ enabled = $true } -Current @{ exists = $false } -Context @{} |
                    Should -BeFalse
            }
        }
    }

    Context 'changing it' {
        It 'disables the named task, and only that one' {
            InModuleScope WinPkgs {
                Mock Disable-ScheduledTask { }
                Mock Enable-ScheduledTask { }
                Set-WinPkgsScheduledTaskState -Properties @{ path = '\A\B\'; name = 'T'; enabled = $false } `
                    -Current @{ exists = $true; enabled = $true } -Context @{}
                Should -Invoke Disable-ScheduledTask -Times 1 -ParameterFilter { $TaskPath -eq '\A\B\' -and $TaskName -eq 'T' }
                Should -Not -Invoke Enable-ScheduledTask
            }
        }

        It 'enables it again' {
            InModuleScope WinPkgs {
                Mock Enable-ScheduledTask { }
                Set-WinPkgsScheduledTaskState -Properties @{ path = '\A\'; name = 'T'; enabled = $true } `
                    -Current @{ exists = $true; enabled = $false } -Context @{}
                Should -Invoke Enable-ScheduledTask -Times 1
            }
        }

        It 'refuses to enable a task that is not there, rather than pretending' {
            InModuleScope WinPkgs {
                Mock Enable-ScheduledTask { }
                { Set-WinPkgsScheduledTaskState -Properties @{ path = '\A\'; name = 'T'; enabled = $true } `
                        -Current @{ exists = $false } -Context @{} } | Should -Throw '*No scheduled task*'
            }
        }

        It 'does nothing to disable one that is already gone' {
            InModuleScope WinPkgs {
                Mock Disable-ScheduledTask { }
                Set-WinPkgsScheduledTaskState -Properties @{ path = '\A\'; name = 'T'; enabled = $false } `
                    -Current @{ exists = $false } -Context @{}
                Should -Not -Invoke Disable-ScheduledTask
            }
        }
    }

    Context 'rollback' {
        It 'puts back what was there' {
            InModuleScope WinPkgs {
                Mock Enable-ScheduledTask { }
                Mock Disable-ScheduledTask { }
                Restore-WinPkgsScheduledTask -Properties @{ path = '\A\'; name = 'T' } `
                    -Before @{ exists = $true; enabled = $true } -Context @{}
                Should -Invoke Enable-ScheduledTask -Times 1
            }
        }

        It 'leaves a task alone that did not exist before' {
            InModuleScope WinPkgs {
                Mock Enable-ScheduledTask { }
                Mock Disable-ScheduledTask { }
                Restore-WinPkgsScheduledTask -Properties @{ path = '\A\'; name = 'T' } `
                    -Before @{ exists = $false } -Context @{}
                Should -Not -Invoke Enable-ScheduledTask
                Should -Not -Invoke Disable-ScheduledTask
            }
        }
    }

    Context 'what a plan says' {
        It 'names both ends' {
            InModuleScope WinPkgs {
                Format-WinPkgsScheduledTaskChange -Properties @{ enabled = $false } -Current @{ exists = $true; enabled = $true } |
                    Should -Be 'enabled -> disabled'
                Format-WinPkgsScheduledTaskChange -Properties @{ enabled = $false } -Current @{ exists = $false } |
                    Should -Be 'not present -> disabled'
            }
        }
    }

    It 'is registered under its type' {
        InModuleScope WinPkgs {
            (Get-WinPkgsResourceType -Type 'winpkgs/scheduledTask') | Should -Not -BeNullOrEmpty
        }
    }
}
