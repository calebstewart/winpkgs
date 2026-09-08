# End-to-end over the registry resource: plan -> apply -> idempotent -> rollback,
# with state redirected into the test drive so nothing real is touched.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')

    function Write-Doc([hashtable[]]$Values) {
        $resources = foreach ($v in $Values) {
            @{ type = 'winpkgs/registry'; id = "$TestKey\$($v.name)"; scope = 'user'
               properties = @{ key = $TestKey; name = $v.name; type = $v.type; value = $v.value; restartExplorer = $false } }
        }
        $path = Join-Path $TestDrive 'config.json'
        @{ version = 1; name = 'apply-test'; settings = @{ prune = @{ winget = $false } }; resources = @($resources) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    function Value([string]$Name) {
        $path = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-Item -LiteralPath $path).GetValue($Name, $null)
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
}

Describe 'plan / apply / rollback' {
    It 'plans creates for a fresh key' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        $plan = @(Get-WinPkgsPlan -Document $doc -Scope user)
        $plan.Count | Should -Be 2
        $plan.Action | Should -Be @('create', 'create')
    }

    It 'applies user scope and records generation 1' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        Value 'A' | Should -Be 1
        Value 'B' | Should -Be 'x'

        $gens = @(Get-WinPkgsGeneration -Scope user)
        $gens.Count | Should -Be 1
        $gens[0].Generation | Should -Be 1
        $gens[0].Changes | Should -Be 2
        Test-Path (Join-Path $gens[0].Path 'config.json') | Should -BeTrue
    }

    It 'is idempotent: a second apply creates no generation' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        @(Get-WinPkgsPlan -Document $doc -Scope user | Where-Object Action -ne 'noop').Count | Should -Be 0
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        @(Get-WinPkgsGeneration -Scope user).Count | Should -Be 1
    }

    It 'applies an update and a delete as generation 2' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 2 }, @{ name = 'B'; type = 'Absent'; value = $null }))
        $plan = @(Get-WinPkgsPlan -Document $doc -Scope user)
        ($plan | Where-Object Id -like '*\A').Action | Should -Be 'update'
        ($plan | Where-Object Id -like '*\B').Action | Should -Be 'delete'
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        Value 'A' | Should -Be 2
        Value 'B' | Should -BeNullOrEmpty
        @(Get-WinPkgsGeneration -Scope user).Count | Should -Be 2
    }

    It 'rolls back generation 2 (scope found from the number), restoring both values, as generation 3' {
        Invoke-WinPkgsRollback -Generation 2 -NoRestartExplorer
        Value 'A' | Should -Be 1
        Value 'B' | Should -Be 'x'
        $gens = @(Get-WinPkgsGeneration -Scope user)
        $gens.Count | Should -Be 3
        $gens[2].Kind | Should -BeLike 'rollback*'
    }

    It 'rolls back generation 1, removing everything it created' {
        Invoke-WinPkgsRollback -Scope user -Generation 1 -NoRestartExplorer
        Value 'A' | Should -BeNullOrEmpty
        Value 'B' | Should -BeNullOrEmpty
    }

    It 'refuses a generation that does not exist' {
        { Invoke-WinPkgsRollback -Generation 99 } | Should -Throw '*No generation 99*'
        { Invoke-WinPkgsRollback -Scope user -Generation 99 } | Should -Throw '*No journal*'
    }

    It 'numbers generations in one sequence across scopes' {
        # Fake a machine-scope generation as the elevated child would leave it:
        # allocated through the shared counter, journal in the machine state dir.
        $n = & (Get-Module WinPkgs) { Get-WinPkgsNextGeneration }
        $n | Should -Be 5
        $machineDir = Join-Path (Get-WinPkgsStateDir -Scope machine) ('generations\{0:D3}' -f $n)
        New-Item -ItemType Directory -Force -Path $machineDir | Out-Null
        @{ number = $n; kind = 'apply'; started = 'x'; entries = @() } | ConvertTo-Json | Set-Content (Join-Path $machineDir 'journal.json')
        $last = @(Get-WinPkgsGeneration) | Select-Object -Last 1
        $last.Scope | Should -Be 'machine'
        $last.Generation | Should -Be $n
        # The next user generation continues the shared sequence.
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'C'; type = 'DWord'; value = 1 }))
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        $last = @(Get-WinPkgsGeneration) | Select-Object -Last 1
        $last.Generation | Should -Be ($n + 1)
        $last.Scope | Should -Be 'user'
    }
}
