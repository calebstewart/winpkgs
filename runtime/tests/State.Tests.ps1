# The state directory on its own, without an apply.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
}

Describe 'the system state directory is writable by administrators only' {
    BeforeAll {
        $Dir = Join-Path $TestDrive 'system'
        & (Get-Module WinPkgs) { param($d) Protect-WinPkgsStateDir -Path $d } $Dir
        function Grants {
            $grants = @{}
            foreach ($r in (Get-Acl -LiteralPath $Dir).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                $grants[$r.IdentityReference.Value] = $r
            }
            return $grants
        }
    }

    AfterAll {
        # The test user may be neither SYSTEM nor an administrator; as the
        # directory's owner it can still put the inherited ACL back, so the
        # test drive can be cleaned up.
        icacls.exe $Dir /reset /q | Out-Null
    }

    It 'no longer inherits what %ProgramData% grants every user' {
        (Get-Acl -LiteralPath $Dir).AreAccessRulesProtected | Should -BeTrue
        @((Grants).Keys | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
    }

    It 'gives SYSTEM and Administrators full control, Users read and execute, all the way down' {
        $grants = Grants
        $full = [Security.AccessControl.FileSystemRights]::FullControl
        $grants['S-1-5-18'].FileSystemRights -band $full | Should -Be $full
        $grants['S-1-5-32-544'].FileSystemRights -band $full | Should -Be $full
        $users = $grants['S-1-5-32-545'].FileSystemRights
        $users -band [Security.AccessControl.FileSystemRights]::ReadAndExecute | Should -Be ([Security.AccessControl.FileSystemRights]::ReadAndExecute)
        $users -band [Security.AccessControl.FileSystemRights]::Write | Should -Be 0
        foreach ($r in $grants.Values) {
            $r.InheritanceFlags | Should -Be ([Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
        }
    }

    It 'leaves an ACL that is already protected alone' {
        $before = (Get-Acl -LiteralPath $Dir).Sddl
        & (Get-Module WinPkgs) { param($d) Protect-WinPkgsStateDir -Path $d } $Dir
        (Get-Acl -LiteralPath $Dir).Sddl | Should -Be $before
    }
}
