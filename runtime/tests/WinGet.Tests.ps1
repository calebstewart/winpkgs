# winpkgs/winget: what it asks winget for, and what it makes of what winget
# says is installed. The WinGet client module is mocked -- installing packages
# is not something a test suite does to the machine it runs on -- so this
# checks the request and the reading, and the request is where the bug was.
#
# A version means one of four things (the resource's header): a pin is exact,
# `upgrade` follows winget's latest, a resolved default is a floor, and no
# version at all is "present is enough". Each gets its block.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    # A resolved default, as the configuration emits it: version from the
    # winget-pkgs pin, not pinned, not upgrading. Overrides replace keys.
    function Pkg([hashtable]$Overrides = @{}) {
        $p = @{ id = 'Git.Git'; source = 'winget'; scope = 'user'; version = '2.51.0'; pinned = $false; upgrade = $false }
        foreach ($k in $Overrides.Keys) { $p[$k] = $Overrides[$k] }
        return $p
    }
    function Present([string]$Version, [bool]$UpdateAvailable = $false, [string]$Available = $null) {
        return @{ exists = $true; version = $Version; name = 'Git'; updateAvailable = $UpdateAvailable; available = $Available }
    }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current) {
        Invoke-WinPkgsResource -Type 'winpkgs/winget' -Operation $Operation -Properties $P -Current $Current -Context @{}
    }
    # Not `Compare`: that is an alias of Compare-Object, and an alias wins.
    function Order([string]$A, [string]$B) {
        & (Get-Module WinPkgs) { param($a, $b) Compare-WinPkgsVersion -A $a -B $b } $A $B
    }
    # Set, inside the module where the winget cmdlets are mocked. The
    # fixtures are built out here and handed in: InModuleScope sees the
    # module's functions, not this file's.
    function SetPkg([hashtable]$P, [hashtable]$Current) {
        InModuleScope WinPkgs -Parameters @{ P = $P; C = $Current } {
            Set-WinPkgsWinGetPackage -Properties $P -Current $C -Context @{}
        }
    }
}

Describe 'Compare-WinPkgsVersion' {
    It 'orders <A> against <B> as <Expected>, the way winget does' -TestCases @(
        @{ A = '7.4.10'; B = '7.4.9'; Expected = 1 }       # numeric, not lexical
        @{ A = '2'; B = '10'; Expected = -1 }              # the [version] cast threw here
        @{ A = '1.0'; B = '1.0.0'; Expected = 0 }          # missing parts are 0
        @{ A = '2.51.0.0'; B = '2.51.0'; Expected = 0 }    # Add/Remove Programs' trailing .0
        @{ A = '2.51.0'; B = '2.51.0.2'; Expected = -1 }   # Git for Windows' fourth part
        @{ A = '2.54.0'; B = '2.55.0.3'; Expected = -1 }
        @{ A = '20240203-110809-5046fc22'; B = '20240101-000000-abcdef00'; Expected = 1 }   # dated: the number decides
        @{ A = '20240203-110809-5046fc22'; B = '20240203-110809-5046fc22'; Expected = 0 }
        @{ A = '1.0'; B = '1.0-beta'; Expected = 1 }       # a bare part outranks a suffixed one
        @{ A = '1.0-alpha'; B = '1.0-beta'; Expected = -1 }
        @{ A = 'B6'; B = 'B7'; Expected = -1 }             # no digits at all
        @{ A = ' 1.2.3 '; B = '1.2.3'; Expected = 0 }      # trimmed
        @{ A = '01.2'; B = '1.2'; Expected = 0 }
    ) {
        param($A, $B, $Expected)
        Order $A $B | Should -Be $Expected
    }

    It 'treats Unknown and empty as versions nothing can be said about' {
        & (Get-Module WinPkgs) { Test-WinPkgsVersionKnown 'Unknown' } | Should -BeFalse
        & (Get-Module WinPkgs) { Test-WinPkgsVersionKnown '' } | Should -BeFalse
        & (Get-Module WinPkgs) { Test-WinPkgsVersionKnown ' ' } | Should -BeFalse
        & (Get-Module WinPkgs) { Test-WinPkgsVersionKnown '2.51.0' } | Should -BeTrue
    }

    It 'calls a digit-led and a letter-led version not comparable' {
        & (Get-Module WinPkgs) { Test-WinPkgsVersionComparable -A 'B6' -B '1.2.3' } | Should -BeFalse
        & (Get-Module WinPkgs) { Test-WinPkgsVersionComparable -A 'Unknown' -B '1.2.3' } | Should -BeFalse
        & (Get-Module WinPkgs) { Test-WinPkgsVersionComparable -A '1.2' -B '1.2.3' } | Should -BeTrue
    }
}

Describe 'winpkgs/winget installs' {
    BeforeEach {
        InModuleScope WinPkgs {
            Mock Import-WinPkgsWinGetClient { }
            # Stand-ins, so the module's calls resolve on a machine without it.
            function script:Install-WinGetPackage { [CmdletBinding()] param($Id, $MatchOption, $Mode, $Scope, $Version, $Source) }
            function script:Update-WinGetPackage { [CmdletBinding()] param($Id, $MatchOption, $Mode, $Scope, $Version, $Source) }
            function script:Uninstall-WinGetPackage { [CmdletBinding()] param($Id, $MatchOption, $Mode, $Version) }
            Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'Ok' } }
            Mock Update-WinGetPackage { [pscustomobject]@{ Status = 'Ok' } }
            Mock Uninstall-WinGetPackage { [pscustomobject]@{ Status = 'Ok' } }
        }
    }

    # A manifest that declares no scope -- wez.wezterm's does not -- has no
    # installer that matches System, and the install failed as
    # NoApplicableInstallers. SystemOrUnknown takes it, elevated, for the machine.
    It 'asks for a machine install as System-or-unknown' {
        SetPkg @{ id = 'wez.wezterm'; scope = 'machine'; version = '20240203-110809-5046fc22' } @{ exists = $false }
        InModuleScope WinPkgs {
            Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter {
                $Id -eq 'wez.wezterm' -and $Scope -eq 'SystemOrUnknown' -and $Version -eq '20240203-110809-5046fc22'
            }
        }
    }

    # A home configuration never elevates, so an installer that does not say
    # what scope it is must not be taken for a user install.
    It 'keeps a user install strict' {
        SetPkg @{ id = 'BurntSushi.ripgrep.MSVC'; scope = 'user' } @{ exists = $false }
        InModuleScope WinPkgs {
            Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Scope -eq 'User' }
        }
    }

    Context 'a version as a floor: the default the configuration resolved' {
        It 'installs at the resolved version when absent' {
            SetPkg (Pkg) @{ exists = $false }
            InModuleScope WinPkgs {
                Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' -and $Version -eq '2.51.0' }
                Should -Invoke Update-WinGetPackage -Exactly -Times 0
                Should -Invoke Uninstall-WinGetPackage -Exactly -Times 0
            }
        }

        It 'updates an older install to the version, not to whatever winget has' {
            SetPkg (Pkg) (Present '2.50.0' $true '2.55.0')
            InModuleScope WinPkgs {
                Should -Invoke Update-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' -and $Version -eq '2.51.0' }
                Should -Invoke Install-WinGetPackage -Exactly -Times 0
                Should -Invoke Uninstall-WinGetPackage -Exactly -Times 0
            }
        }

        It 'is drift when older' {
            Op Test (Pkg) (Present '2.50.0') | Should -BeFalse
            Op Describe (Pkg) (Present '2.50.0') | Should -Be '2.50.0 -> 2.51.0'
        }

        It 'is in state at the version' {
            Op Test (Pkg) (Present '2.51.0') | Should -BeTrue
            Op Describe (Pkg) (Present '2.51.0') | Should -Be 'installed 2.51.0'
        }

        It 'is in state when newer, and says so rather than downgrading' {
            Op Test (Pkg) (Present '2.52.0') | Should -BeTrue
            Op Describe (Pkg) (Present '2.52.0') | Should -Be 'installed 2.52.0 (2.51.0 or newer wanted)'
        }

        It 'reads a trailing .0 as the same version' {
            Op Test (Pkg) (Present '2.51.0.0') | Should -BeTrue
        }

        It 'leaves a version winget cannot tell alone' {
            Op Test (Pkg) (Present 'Unknown') | Should -BeTrue
            Op Describe (Pkg) (Present 'Unknown') | Should -Be 'installed, version unknown (2.51.0 or newer wanted)'
        }

        It 'leaves a version of another shape alone' {
            Op Test (Pkg) (Present 'B6') | Should -BeTrue
            Op Describe (Pkg) (Present 'B6') | Should -Match 'not comparable'
        }

        It 'describes an absent package by the version it will get' {
            Op Describe (Pkg) @{ exists = $false } | Should -Be 'absent -> 2.51.0'
        }
    }

    Context 'a pinned version' {
        It 'updates an older install to the pin' {
            SetPkg (Pkg @{ pinned = $true }) (Present '2.50.0')
            InModuleScope WinPkgs {
                Should -Invoke Update-WinGetPackage -Times 1 -ParameterFilter { $Version -eq '2.51.0' }
                Should -Invoke Uninstall-WinGetPackage -Exactly -Times 0
            }
        }

        It 'downgrades a newer install by uninstalling and reinstalling at the pin' {
            SetPkg (Pkg @{ pinned = $true }) (Present '2.52.0')
            InModuleScope WinPkgs {
                Should -Invoke Uninstall-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' }
                Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' -and $Version -eq '2.51.0' }
                Should -Invoke Update-WinGetPackage -Exactly -Times 0
            }
        }

        It 'is drift when newer' {
            Op Test (Pkg @{ pinned = $true }) (Present '2.52.0') | Should -BeFalse
            Op Describe (Pkg @{ pinned = $true }) (Present '2.52.0') | Should -Be '2.52.0 -> 2.51.0 (downgrade)'
        }

        It 'is in state at the pin, a trailing .0 included' {
            Op Test (Pkg @{ pinned = $true }) (Present '2.51.0') | Should -BeTrue
            Op Test (Pkg @{ pinned = $true }) (Present '2.51.0.0') | Should -BeTrue
            Op Describe (Pkg @{ pinned = $true }) (Present '2.51.0') | Should -Be 'installed 2.51.0'
        }

        It 'leaves a version winget cannot tell alone' {
            Op Test (Pkg @{ pinned = $true }) (Present 'Unknown') | Should -BeTrue
            Op Describe (Pkg @{ pinned = $true }) (Present 'Unknown') | Should -Be 'installed, version unknown (2.51.0 pinned)'
        }

        # A document built before `pinned` existed travels with its own
        # runtime; read by this one anyway, its pin is a floor.
        It 'reads a version in a document without pinned as a floor' {
            $old = Pkg
            $old.Remove('pinned')
            Op Test $old (Present '2.52.0') | Should -BeTrue
            Op Test $old (Present '2.50.0') | Should -BeFalse
        }
    }

    Context 'upgrade: follow winget' {
        It 'installs latest, without a version, when absent' {
            SetPkg (Pkg @{ upgrade = $true }) @{ exists = $false }
            InModuleScope WinPkgs {
                Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' -and $null -eq $Version }
            }
        }

        It 'updates to whatever winget has, never pinning' {
            SetPkg (Pkg @{ upgrade = $true }) (Present '2.50.0' $true '2.55.0')
            InModuleScope WinPkgs {
                Should -Invoke Update-WinGetPackage -Times 1 -ParameterFilter { $Id -eq 'Git.Git' -and $null -eq $Version }
                Should -Invoke Install-WinGetPackage -Exactly -Times 0
                Should -Invoke Uninstall-WinGetPackage -Exactly -Times 0
            }
        }

        It 'treats a pending winget update as drift' {
            Op Test (Pkg @{ upgrade = $true }) (Present '2.50.0' $true '2.55.0') | Should -BeFalse
            Op Describe (Pkg @{ upgrade = $true }) (Present '2.50.0' $true '2.55.0') | Should -Be '2.50.0 -> 2.55.0 (upgrade)'
        }

        It 'is in state with no pending update, even below the resolved version' {
            Op Test (Pkg @{ upgrade = $true }) (Present '2.50.0') | Should -BeTrue
            Op Describe (Pkg @{ upgrade = $true }) (Present '2.50.0') | Should -Be 'installed 2.50.0'
            Op Describe (Pkg @{ upgrade = $true }) @{ exists = $false } | Should -Be 'absent -> latest'
        }

        It 'yields to a pin' {
            Op Test (Pkg @{ upgrade = $true; pinned = $true }) (Present '2.52.0') | Should -BeFalse
            Op Describe (Pkg @{ upgrade = $true; pinned = $true }) (Present '2.52.0') | Should -Be '2.52.0 -> 2.51.0 (downgrade)'
        }
    }

    Context 'no version to ask for: another source' {
        It 'installs whatever the source has' {
            SetPkg (Pkg @{ id = '9NBLGGH4NNS1'; source = 'msstore'; version = $null }) @{ exists = $false }
            InModuleScope WinPkgs {
                Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Source -eq 'msstore' -and $null -eq $Version }
            }
        }

        It 'is satisfied by presence' {
            $p = Pkg @{ id = '9NBLGGH4NNS1'; source = 'msstore'; version = $null }
            Op Test $p (Present '1.0') | Should -BeTrue
            Op Describe $p (Present '1.0') | Should -Be 'installed 1.0'
            Op Describe $p @{ exists = $false } | Should -Be 'absent -> latest'
        }
    }

    Context 'a version the source no longer has' {
        It 'says what to do when winget reports it' {
            InModuleScope WinPkgs {
                Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'CatalogError'; ExtendedErrorCode = -1978335209 } }
            }
            $act = { SetPkg (Pkg) @{ exists = $false } }
            $act | Should -Throw -ExpectedMessage '*winget-pkgs*'
            $act | Should -Throw -ExpectedMessage '*upgrade = true*'
        }

        It 'says what to do when the cmdlet throws' {
            InModuleScope WinPkgs {
                Mock Update-WinGetPackage { throw 'No version found matching: 2.51.0' }
            }
            $act = { SetPkg (Pkg) (Present '2.50.0') }
            $act | Should -Throw -ExpectedMessage '*No version found*'
            $act | Should -Throw -ExpectedMessage '*nix flake update winget-pkgs*'
        }

        It 'says nothing about versions when a latest install fails' {
            InModuleScope WinPkgs {
                Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'InstallError'; InstallerErrorCode = 1603 } }
            }
            $message = ''
            try { SetPkg (Pkg @{ upgrade = $true }) @{ exists = $false } } catch { $message = $_.Exception.Message }
            $message | Should -Match 'installer exit 1603'
            $message | Should -Not -Match 'winget-pkgs'
        }
    }
}
