# winpkgs/winget: what it asks winget for. The WinGet client module is mocked --
# installing packages is not something a test suite does to the machine it
# runs on -- so this checks the request, and the request is where the bug was.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
}

Describe 'winpkgs/winget installs' {
    BeforeEach {
        InModuleScope WinPkgs {
            Mock Import-WinPkgsWinGetClient { }
            # Stand-ins, so the module's calls resolve on a machine without it.
            function script:Install-WinGetPackage { [CmdletBinding()] param($Id, $MatchOption, $Mode, $Scope, $Version, $Source) }
            Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'Ok' } }
        }
    }

    # A manifest that declares no scope -- wez.wezterm's does not -- has no
    # installer that matches System, and the install failed as
    # NoApplicableInstallers. SystemOrUnknown takes it, elevated, for the machine.
    It 'asks for a machine install as System-or-unknown' {
        InModuleScope WinPkgs {
            Set-WinPkgsWinGetPackage -Properties @{ id = 'wez.wezterm'; scope = 'machine'; version = '20240203-110809-5046fc22' } `
                -Current @{ exists = $false } -Context @{}
            Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter {
                $Id -eq 'wez.wezterm' -and $Scope -eq 'SystemOrUnknown' -and $Version -eq '20240203-110809-5046fc22'
            }
        }
    }

    # A home configuration never elevates, so an installer that does not say
    # what scope it is must not be taken for a user install.
    It 'keeps a user install strict' {
        InModuleScope WinPkgs {
            Set-WinPkgsWinGetPackage -Properties @{ id = 'BurntSushi.ripgrep.MSVC'; scope = 'user' } `
                -Current @{ exists = $false } -Context @{}
            Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Scope -eq 'User' }
        }
    }
}
