# End-to-end over the registry resource: plan -> apply -> idempotent -> going
# to another generation, as a home configuration, with state redirected into
# the test drive so nothing real is touched. The closure here has no runtime,
# so a generation is gone to in-process, with apply -Generation, which is what
# rollback runs in the generation's own runtime (Rollback.Tests.ps1).
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
        @{ version = 2; kind = 'home'; name = 'apply-test'
           settings = @{ prune = @{ winget = $false; files = $false }; generations = @{ keep = 10; deleteOlderThan = $null } }
           resources = @($resources) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    function Value([string]$Name) {
        $path = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-Item -LiteralPath $path).GetValue($Name, $null)
    }
    function Generations { @(Get-WinPkgsGeneration -Kind home) }
    function Current { (Generations | Where-Object Current).Generation }
    # Apply generation N's kept closure as N.
    function Go([int]$N) {
        $doc = Read-WinPkgsDocument -Path (Join-Path (Generations | Where-Object Generation -eq $N).Path 'closure\config.json')
        Invoke-WinPkgsApply -Document $doc -Generation $N -NoRestartExplorer
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
}

Describe 'plan / apply / generations (home)' {
    It 'plans creates for a fresh key' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        $plan = @(Get-WinPkgsPlan -Document $doc)
        $plan.Count | Should -Be 2
        $plan.Action | Should -Be @('create', 'create')
        $plan.Kind | Should -Be @('home', 'home')
    }

    It 'applies and records generation 1 of the home kind, keeping its closure' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Value 'A' | Should -Be 1
        Value 'B' | Should -Be 'x'

        $gens = @(Generations)
        $gens.Count | Should -Be 1
        $gens[0].Generation | Should -Be 1
        $gens[0].Kind | Should -Be 'home'
        $gens[0].Changes | Should -Be 2
        $gens[0].Current | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $gens[0].Path 'closure\config.json') -Raw |
            Should -Be (Get-Content -LiteralPath $doc['path'] -Raw)
        # The closure is config.json and whatever of runtime/files/fonts there is,
        # nothing else from the directory it was applied from.
        @(Get-ChildItem -LiteralPath (Join-Path $gens[0].Path 'closure')).Name | Should -Be @('config.json')
        (Get-WinPkgsStateDir -Kind home) | Should -Be (Join-Path $env:WINPKGS_STATE_DIR 'home')
    }

    It 'is idempotent: the same closure again records nothing' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        @(Get-WinPkgsPlan -Document $doc | Where-Object Action -ne 'noop').Count | Should -Be 0
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        @(Generations).Count | Should -Be 1
    }

    It 'converges drift as the current generation, recording that run beside it' {
        Set-ItemProperty -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Name A -Value 5
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 1 }, @{ name = 'B'; type = 'String'; value = 'x' }))
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Value 'A' | Should -Be 1
        @(Generations).Count | Should -Be 1
        Current | Should -Be 1
        Test-Path (Join-Path @(Generations)[0].Path 'journal-2.json') | Should -BeTrue
    }

    It 'applies an update and a delete as generation 2' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 2 }, @{ name = 'B'; type = 'Absent'; value = $null }))
        $plan = @(Get-WinPkgsPlan -Document $doc)
        ($plan | Where-Object Id -like '*\A').Action | Should -Be 'update'
        ($plan | Where-Object Id -like '*\B').Action | Should -Be 'delete'
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Value 'A' | Should -Be 2
        Value 'B' | Should -BeNullOrEmpty
        @(Generations).Count | Should -Be 2
        Current | Should -Be 2
    }

    It 'records another configuration as a generation even when nothing on the machine changes' {
        # B is no longer mentioned; it stays absent.
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 2 }))
        @(Get-WinPkgsPlan -Document $doc | Where-Object Action -ne 'noop').Count | Should -Be 0
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        $gens = @(Generations)
        $gens.Count | Should -Be 3
        $gens[2].Changes | Should -Be 0
        Current | Should -Be 3
    }

    It 'goes to an earlier generation: converges to it and makes it current, recording nothing new' {
        Go 1
        Value 'A' | Should -Be 1
        Value 'B' | Should -Be 'x'
        @(Generations).Count | Should -Be 3
        Current | Should -Be 1
        $journal = Get-Content -LiteralPath (Join-Path @(Generations)[0].Path 'journal-3.json') -Raw | ConvertFrom-Json
        $journal.label | Should -Be 'rollback'
        @($journal.entries).Count | Should -Be 2
    }

    It 'goes to a later generation the same way' {
        Go 2
        Value 'A' | Should -Be 2
        Value 'B' | Should -BeNullOrEmpty
        Current | Should -Be 2
    }

    It 'switches back to the newest generation when its closure is applied again' {
        Go 1
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 2 }))
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        @(Generations).Count | Should -Be 3
        Current | Should -Be 3
        Value 'A' | Should -Be 2
    }

    It 'numbers a new configuration after the newest generation, whichever is current' {
        Go 1
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'A'; type = 'DWord'; value = 3 }))
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Current | Should -Be 4
        Value 'A' | Should -Be 3
    }

    It 'refuses a closure that is not the generation it is applied as' {
        $doc = Read-WinPkgsDocument -Path (Join-Path @(Generations)[1].Path 'closure\config.json')
        { Invoke-WinPkgsApply -Document $doc -Generation 1 -NoRestartExplorer } | Should -Throw '*not the closure home generation 1 keeps*'
        { Invoke-WinPkgsApply -Document $doc -Generation 99 -NoRestartExplorer } | Should -Throw '*No home generation 99*'
        Current | Should -Be 4
    }

    It 'numbers each kind on its own, and lists both' {
        # A system generation, as the elevated apply would leave it.
        $systemDir = Join-Path (Get-WinPkgsStateDir -Kind system) 'generations\007'
        New-Item -ItemType Directory -Force -Path $systemDir | Out-Null
        @{ number = 7; label = 'apply'; started = 'x'; entries = @() } | ConvertTo-Json | Set-Content (Join-Path $systemDir 'journal.json')

        $all = @(Get-WinPkgsGeneration)
        ($all | Where-Object Kind -eq 'system').Generation | Should -Be 7
        @($all | Where-Object Kind -eq 'home').Count | Should -Be 4

        # The next home generation continues home's own sequence, not system's.
        $doc = Read-WinPkgsDocument -Path (Write-Doc @(@{ name = 'C'; type = 'DWord'; value = 1 }))
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        (@(Generations) | Select-Object -Last 1).Generation | Should -Be 5
    }
}

Describe 'keeping closures' {
    BeforeAll {
        $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'keep-state'
        $Closure = Join-Path $TestDrive 'keep-closure'
        New-Item -ItemType Directory -Force -Path (Join-Path $Closure 'files\sub'), (Join-Path $Closure 'files\empty'), (Join-Path $Closure 'fonts\mono') | Out-Null
        Set-Content -LiteralPath (Join-Path $Closure 'files\sub\a.txt') -Value 'a' -NoNewline
        Set-Content -LiteralPath (Join-Path $Closure 'fonts\mono\Mono.ttf') -Value 'font' -NoNewline
        Set-Content -LiteralPath (Join-Path $Closure 'unrelated.txt') -Value 'not part of it' -NoNewline
        function Write-KeepDoc([int]$Value) {
            $path = Join-Path $Closure 'config.json'
            @{ version = 2; kind = 'home'; name = 'keep-test'
               settings = @{ prune = @{ winget = $false; files = $false }; generations = @{ keep = 10; deleteOlderThan = $null } }
               resources = @(@{ type = 'winpkgs/registry'; id = "$TestKey\K"; scope = 'user'
                                properties = @{ key = $TestKey; name = 'K'; type = 'DWord'; value = $Value; restartExplorer = $false } }) } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
            return Read-WinPkgsDocument -Path $path
        }
        function Kept([int]$N, [string]$Name) { Join-Path (Get-WinPkgsStateDir -Kind home) ('generations\{0:D3}\closure\{1}' -f $N, $Name) }
        function LinkCount([string]$Path) { @(& fsutil.exe hardlink list $Path).Count }
    }

    It 'keeps config.json, files and fonts, and nothing else' {
        Invoke-WinPkgsApply -Document (Write-KeepDoc 1) -NoRestartExplorer
        Get-Content -LiteralPath (Kept 1 'files\sub\a.txt') -Raw | Should -Be 'a'
        Get-Content -LiteralPath (Kept 1 'fonts\mono\Mono.ttf') -Raw | Should -Be 'font'
        Test-Path (Kept 1 'files\empty') -PathType Container | Should -BeTrue
        Test-Path (Kept 1 'unrelated.txt') | Should -BeFalse
        $manifest = Get-Content -LiteralPath (Join-Path (Get-WinPkgsStateDir -Kind home) 'generations\001\manifest.json') -Raw | ConvertFrom-Json
        @($manifest.files.PSObject.Properties.Name | Sort-Object) | Should -Be @('config.json', 'files\sub\a.txt', 'fonts\mono\Mono.ttf')
    }

    It 'keeps a document by any name as config.json' {
        $doc = Write-KeepDoc 1
        $renamed = Join-Path $Closure 'desktop.json'
        Move-Item -LiteralPath $doc['path'] -Destination $renamed
        try {
            # The same bytes under another name: the same closure, generation 1.
            Invoke-WinPkgsApply -Document (Read-WinPkgsDocument -Path $renamed) -NoRestartExplorer
            @(Get-WinPkgsGeneration -Kind home).Count | Should -Be 1
        } finally { Move-Item -LiteralPath $renamed -Destination $doc['path'] }
    }

    It 'hard-links a file an earlier generation keeps unchanged, and copies a changed one' {
        Invoke-WinPkgsApply -Document (Write-KeepDoc 2) -NoRestartExplorer
        LinkCount (Kept 2 'fonts\mono\Mono.ttf') | Should -Be 2
        LinkCount (Kept 2 'config.json') | Should -Be 1
    }

    It 'never deletes the current generation, whatever the policy' {
        Invoke-WinPkgsApply -Document (Write-KeepDoc 3) -NoRestartExplorer
        $two = Read-WinPkgsDocument -Path (Kept 2 'config.json')
        Invoke-WinPkgsApply -Document $two -Generation 2 -NoRestartExplorer
        Value 'K' | Should -Be 2
        # Keep one: 3 is the newest, and 2 is what the machine is on.
        @(Invoke-WinPkgsGarbageCollect -Kind home -Keep 1).Generation | Should -Be @(1)
        @(Get-WinPkgsGeneration -Kind home | ForEach-Object Generation) | Should -Be @(2, 3)
        (Get-WinPkgsGeneration -Kind home | Where-Object Current).Generation | Should -Be 2
        # What generation 1 kept is gone; the font generation 2 linked to it is not.
        Get-Content -LiteralPath (Kept 2 'fonts\mono\Mono.ttf') -Raw | Should -Be 'font'
    }

    It 'removes what an apply that died while keeping a closure left behind' {
        $partial = Join-Path (Get-WinPkgsStateDir -Kind home) 'generations\009.partial'
        New-Item -ItemType Directory -Force -Path $partial | Out-Null
        Invoke-WinPkgsApply -Document (Write-KeepDoc 4) -NoRestartExplorer
        Test-Path $partial | Should -BeFalse
        (Get-WinPkgsGeneration -Kind home | Where-Object Current).Generation | Should -Be 4
    }
}
