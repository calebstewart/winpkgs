# Invoke-WinPkgsExternal is private, so these reach it through InModuleScope
# and drive it with cmd.exe -- a real native command, which is the only way to
# exercise the exit-code promotion a .ps1 stand-in cannot reproduce.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
}

Describe 'Invoke-WinPkgsExternal' {
    It 'returns the output of a command that succeeds' {
        InModuleScope WinPkgs {
            $r = Invoke-WinPkgsExternal -Command 'cmd.exe' -Arguments @('/c', 'echo hello')
            $r['failed'] | Should -BeFalse
            $r['code'] | Should -Be 0
            $r['lines'] | Should -Contain 'hello'
        }
    }

    It 'reports a non-zero exit as data rather than raising, under Stop' {
        InModuleScope WinPkgs {
            $ErrorActionPreference = 'Stop'
            $r = Invoke-WinPkgsExternal -Command 'cmd.exe' -Arguments @('/c', 'exit 3')
            $r['failed'] | Should -BeTrue
            $r['code'] | Should -Be 3
        }
    }

    It 'still reports it as data on a host that promotes exit codes to exceptions' {
        # The regression: $PSNativeCommandUseErrorActionPreference is off by
        # default but is a host setting, and with it on the throw used to
        # happen before any caller could read the code.
        InModuleScope WinPkgs {
            $ErrorActionPreference = 'Stop'
            $PSNativeCommandUseErrorActionPreference = $true
            $r = Invoke-WinPkgsExternal -Command 'cmd.exe' -Arguments @('/c', 'exit 4')
            $r['failed'] | Should -BeTrue
            $r['code'] | Should -Be 4
        }
    }

    It 'treats stderr on a successful command as output, not failure' {
        # reg.exe and winget both chat on stderr when they succeed; under 5.1
        # the 2>&1 redirect turns that into a terminating error.
        InModuleScope WinPkgs {
            $ErrorActionPreference = 'Stop'
            $r = Invoke-WinPkgsExternal -Command 'cmd.exe' -Arguments @('/c', 'echo chatter 1>&2')
            $r['failed'] | Should -BeFalse
            $r['code'] | Should -Be 0
            $r['text'] | Should -BeLike '*chatter*'
        }
    }

    It 'quotes what the command said when it fails' {
        InModuleScope WinPkgs {
            $ErrorActionPreference = 'Stop'
            $r = Invoke-WinPkgsExternal -Command 'cmd.exe' -Arguments @('/c', 'echo boom 1>&2 & exit 9')
            $r['failed'] | Should -BeTrue
            $r['code'] | Should -Be 9
            $r['text'] | Should -BeLike '*boom*'
        }
    }
}
