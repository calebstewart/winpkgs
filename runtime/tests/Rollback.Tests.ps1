# rollback goes to a generation by running that generation's own runtime, in a
# child process, against the closure it keeps. The closures here carry a copy of
# this runtime, as a built one does; generation 1's copy also leaves a mark when
# it is loaded, which is how the tests tell whose runtime ran.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
    $env:WINPKGS_ROLLBACK_MARK = Join-Path $TestDrive 'mark.txt'
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')

    $Root = Join-Path $TestDrive 'closure'
    $runtime = Join-Path $Root 'runtime'
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\winpkgs.ps1') -Destination $runtime
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\WinPkgs') -Destination $runtime -Recurse
    $Marker = Join-Path $runtime 'WinPkgs\Private\ZMark.ps1'

    function Write-Doc([hashtable]$Values, [bool]$Marked) {
        if ($Marked) { Set-Content -LiteralPath $Marker -Value "Set-Content -LiteralPath `$env:WINPKGS_ROLLBACK_MARK -Value 'generation 1'" }
        else { Remove-Item -LiteralPath $Marker -ErrorAction SilentlyContinue }
        $resources = foreach ($name in $Values.Keys) {
            @{ type = 'winpkgs/registry'; id = "$TestKey\$name"; scope = 'user'
               properties = @{ key = $TestKey; name = $name; type = 'DWord'; value = $Values[$name]; restartExplorer = $false } }
        }
        $path = Join-Path $Root 'config.json'
        @{ version = 2; kind = 'home'; name = 'rollback-test'
           settings = @{ prune = @{ winget = $false; files = $false }; generations = @{ keep = 10; deleteOlderThan = $null } }
           resources = @($resources) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return Read-WinPkgsDocument -Path $path
    }
    function Value([string]$Name) {
        $path = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-Item -LiteralPath $path).GetValue($Name, $null)
    }
    function Current { (Get-WinPkgsGeneration -Kind home | Where-Object Current).Generation }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR, Env:\WINPKGS_ROLLBACK_MARK -ErrorAction SilentlyContinue
}

Describe 'rollback (home)' {
    It 'has nothing to go back from before the first apply' {
        { Invoke-WinPkgsRollback -Kind home } | Should -Throw '*No current home generation*'
    }

    It 'has nowhere to go back to from the first generation' {
        Invoke-WinPkgsApply -Document (Write-Doc @{ A = 1 } $true) -NoRestartExplorer
        { Invoke-WinPkgsRollback -Kind home } | Should -Throw '*No home generation before generation 1*'
    }

    It 'goes to the previous generation with that generation''s own runtime' {
        Invoke-WinPkgsApply -Document (Write-Doc @{ A = 2; B = 1 } $false) -NoRestartExplorer
        Current | Should -Be 2
        Test-Path $env:WINPKGS_ROLLBACK_MARK | Should -BeFalse

        Invoke-WinPkgsRollback -Kind home -NoRestartExplorer | Should -Be 0
        Get-Content -LiteralPath $env:WINPKGS_ROLLBACK_MARK | Should -Be 'generation 1'
        Value 'A' | Should -Be 1
        Current | Should -Be 1
        @(Get-WinPkgsGeneration -Kind home).Count | Should -Be 2
    }

    It 'does what applying that configuration would do, and no more' {
        # B was first set by generation 2, and a registry value is not owned:
        # generation 1 does not mention it, so it stays.
        Value 'B' | Should -Be 1
    }

    It 'goes to a named generation, later ones included' {
        Remove-Item -LiteralPath $env:WINPKGS_ROLLBACK_MARK
        Invoke-WinPkgsRollback -Kind home -Generation 2 -NoRestartExplorer | Should -Be 0
        Test-Path $env:WINPKGS_ROLLBACK_MARK | Should -BeFalse
        Value 'A' | Should -Be 2
        Current | Should -Be 2
    }

    It 'numbers the next apply after the newest generation' {
        Invoke-WinPkgsRollback -Kind home -Generation 1 -NoRestartExplorer | Should -Be 0
        Invoke-WinPkgsApply -Document (Write-Doc @{ A = 3 } $false) -NoRestartExplorer
        Current | Should -Be 3
    }

    It 'refuses a generation that does not exist, or that kept no closure' {
        { Invoke-WinPkgsRollback -Kind home -Generation 99 } | Should -Throw '*No home generation 99*'
        # As a runtime from before closures were kept left one.
        $legacy = Join-Path (Get-WinPkgsStateDir -Kind home) 'generations\004'
        New-Item -ItemType Directory -Force -Path (Join-Path $legacy 'files') | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root 'config.json') -Destination $legacy
        @{ number = 4; label = 'apply'; started = (Get-Date).ToString('o'); entries = @() } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $legacy 'journal.json') -Encoding utf8
        { Invoke-WinPkgsRollback -Kind home -Generation 4 } | Should -Throw '*recorded before winpkgs kept*'
    }

    It 'passes the exit code of the generation''s runtime on' {
        # A closure that no longer matches what was kept: the runtime refuses it.
        Add-Content -LiteralPath (Join-Path (Get-WinPkgsStateDir -Kind home) 'generations\002\closure\config.json') -Value ' '
        Invoke-WinPkgsRollback -Kind home -Generation 2 -NoRestartExplorer | Should -Not -Be 0
        Current | Should -Be 3
    }
}

Describe 'system generations run elevated only from what an administrator made' {
    It 'accepts a directory this user owns' {
        { & (Get-Module WinPkgs) { param($p) Assert-WinPkgsAdministratorOwned -Path $p } $TestDrive } | Should -Not -Throw
    }

    It 'refuses one another user owns' {
        $foreign = New-Object System.Security.AccessControl.DirectorySecurity
        $foreign.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'))
        Mock -ModuleName WinPkgs Get-Acl { $foreign }
        { & (Get-Module WinPkgs) { param($p) Assert-WinPkgsAdministratorOwned -Path $p } $TestDrive } |
            Should -Throw '*Refusing to run*S-1-5-32-545*'
    }
}
