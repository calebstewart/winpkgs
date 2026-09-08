# File ownership and prune, and the generation policy. State redirected into the
# test drive; file targets under a test-only environment variable.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
    $env:WINPKGS_PRUNE_HOME = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Force -Path $env:WINPKGS_PRUNE_HOME | Out-Null

    $Root = Join-Path $TestDrive 'closure'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'files') | Out-Null
    foreach ($n in 'a', 'b', 'c') { Set-Content -LiteralPath (Join-Path $Root "files\$n.txt") -Value $n -NoNewline }

    # A document declaring the given files, with prune on and a generation policy.
    function Write-Doc([string[]]$Files, [int]$Keep = 10) {
        $resources = foreach ($n in $Files) {
            @{ type = 'winpkgs/file'; id = "%WINPKGS_PRUNE_HOME%/$n.txt"; scope = 'user'
               properties = @{ target = "%WINPKGS_PRUNE_HOME%/$n.txt"; source = "files/$n.txt" } }
        }
        $path = Join-Path $Root 'config.json'
        @{ version = 1; name = 'prune-test'
           settings = @{ prune = @{ winget = $false; files = $true }; generations = @{ keep = $Keep; deleteOlderThan = $null } }
           resources = @($resources) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    function Target([string]$n) { Join-Path $env:WINPKGS_PRUNE_HOME "$n.txt" }
    function Owned { @((Read-WinPkgsState -Scope user)['owned']['files']) }
}

AfterAll {
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_PRUNE_HOME -ErrorAction SilentlyContinue
}

Describe 'file ownership and prune' {
    It 'owns the files it creates, not one that already existed' {
        Set-Content -LiteralPath (Target 'c') -Value 'mine before winpkgs' -NoNewline
        $doc = Read-WinPkgsDocument -Path (Write-Doc @('a', 'b', 'c'))
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        Get-Content -LiteralPath (Target 'c') -Raw | Should -Be 'c'   # managed: overwritten
        $owned = Owned
        $owned | Should -Contain '%WINPKGS_PRUNE_HOME%/a.txt'
        $owned | Should -Contain '%WINPKGS_PRUNE_HOME%/b.txt'
        $owned | Should -Not -Contain '%WINPKGS_PRUNE_HOME%/c.txt' # not owned: pre-existing
    }

    It 'plans a remove for an owned file that leaves the document, and only that' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @('a'))
        $plan = @(Get-WinPkgsPlan -Document $doc -Scope user)
        $removes = @($plan | Where-Object Action -eq 'remove')
        $removes.Count | Should -Be 1
        $removes[0].Id | Should -Be '%WINPKGS_PRUNE_HOME%/b.txt'
        $removes[0].Detail | Should -Match 'no longer declared'
    }

    It 'deletes the pruned file, keeps the pre-existing one, and forgets the ownership' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @('a'))
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        Test-Path (Target 'b') | Should -BeFalse
        Test-Path (Target 'c') | Should -BeTrue
        Owned | Should -Not -Contain '%WINPKGS_PRUNE_HOME%/b.txt'
        # and a second apply has nothing left to prune
        @(Get-WinPkgsPlan -Document $doc -Scope user | Where-Object Action -ne 'noop').Count | Should -Be 0
    }

    It 'rolls a prune back: the file returns and is owned again' {
        $pruneGen = (@(Get-WinPkgsGeneration -Scope user) | Select-Object -Last 1).Generation
        Invoke-WinPkgsRollback -Generation $pruneGen -NoRestartExplorer
        Get-Content -LiteralPath (Target 'b') -Raw | Should -Be 'b'
        Owned | Should -Contain '%WINPKGS_PRUNE_HOME%/b.txt'
    }

    It 'honours prune.files = false' {
        $path = Write-Doc @('a')
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json.settings.prune.files = $false
        $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        $doc = Read-WinPkgsDocument -Path $path
        @(Get-WinPkgsPlan -Document $doc -Scope user | Where-Object Action -eq 'remove').Count | Should -Be 0
    }
}

Describe 'generation policy' {
    BeforeAll {
        # A fresh state dir with twelve fake generations, the odd ones old.
        $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'gc-state'
        # Not `$root`: variables are case-insensitive and the outer $Root is the closure.
        $gensDir = Join-Path (Get-WinPkgsStateDir -Scope user) 'generations'
        foreach ($i in 1..12) {
            $dir = Join-Path $gensDir ('{0:D3}' -f $i)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'files') | Out-Null
            $started = if ($i % 2 -eq 1) { (Get-Date).AddDays(-40) } else { Get-Date }
            @{ number = $i; kind = 'apply'; started = $started.ToString('o'); entries = @() } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'journal.json') -Encoding utf8
        }
        function Numbers { @(Get-WinPkgsGeneration -Scope user | ForEach-Object Generation) }
    }

    It 'a dry run removes nothing' {
        @(Invoke-WinPkgsGarbageCollect -Scope user -Keep 10 -DryRun).Count | Should -Be 2
        (Numbers).Count | Should -Be 12
    }

    It 'keeps the newest N regardless of age' {
        $removed = @(Invoke-WinPkgsGarbageCollect -Scope user -Keep 10)
        $removed.Generation | Should -Be @(1, 2)
        Numbers | Should -Be @(3..12)
    }

    It 'with -OlderThan, removes only the old ones beyond the kept set' {
        $removed = @(Invoke-WinPkgsGarbageCollect -Scope user -Keep 4 -OlderThan '30d')
        $removed.Generation | Should -Be @(3, 5, 7)      # 3..8 are candidates; odd ones are 40 days old
        Numbers | Should -Be @(4, 6, 8, 9, 10, 11, 12)
    }

    It 'parses durations' {
        & (Get-Module WinPkgs) { ConvertTo-WinPkgsTimeSpan '30d' } | Should -Be ([timespan]::FromDays(30))
        & (Get-Module WinPkgs) { ConvertTo-WinPkgsTimeSpan '12h' } | Should -Be ([timespan]::FromHours(12))
        & (Get-Module WinPkgs) { ConvertTo-WinPkgsTimeSpan '7' } | Should -Be ([timespan]::FromDays(7))
        { & (Get-Module WinPkgs) { ConvertTo-WinPkgsTimeSpan 'soon' } } | Should -Throw
    }

    It 'the apply applies the document policy' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc @('a') 5)
        Invoke-WinPkgsApply -Document $doc -Scope user -NoRestartExplorer
        (Numbers | Select-Object -Last 1) | Should -Be 13   # the new generation (shared counter continues)
        (Numbers).Count | Should -BeLessOrEqual 5
    }
}
