# winpkgs/activation: a command run at the end of an apply when its triggers
# changed. Real home applies, state and files in the test drive; the commands
# write what they saw into files the tests read.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
    $env:WINPKGS_ACT_HOME = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Force -Path $env:WINPKGS_ACT_HOME | Out-Null

    $Root = Join-Path $TestDrive 'closure'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'files') | Out-Null
    foreach ($n in 'a', 'b') { Set-Content -LiteralPath (Join-Path $Root "files\$n.txt") -Value $n -NoNewline }

    # A home document with the given files and activations (name -> @{ command; revision }).
    function Write-Doc([string[]]$Files, [hashtable]$Activations = @{}) {
        $resources = @(foreach ($n in $Files) {
            @{ type = 'winpkgs/file'; id = "%WINPKGS_ACT_HOME%/$n.txt"; scope = 'user'
               properties = @{ target = "%WINPKGS_ACT_HOME%/$n.txt"; source = "files/$n.txt" } }
        })
        # Declared first, as a module could; the runtime still runs them last.
        $resources = @(foreach ($name in $Activations.Keys) {
            @{ type = 'winpkgs/activation'; id = "Activation $name"; scope = 'user'
               properties = @{ name = $name; command = $Activations[$name]['command']; revision = $Activations[$name]['revision'] } }
        }) + $resources
        $path = Join-Path $Root 'config.json'
        @{ version = 2; kind = 'home'; name = 'activation-test'
           settings = @{ prune = @{ winget = $false; files = $true }; generations = @{ keep = 50; deleteOlderThan = $null } }
           resources = $resources } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return Read-WinPkgsDocument -Path $path
    }
    function Apply($Doc) { Invoke-WinPkgsApply -Document $Doc -NoRestartExplorer 6>$null }
    function Out([string]$n) { Join-Path $env:WINPKGS_ACT_HOME "$n.out" }
    function Runs([string]$n) { if (Test-Path (Out $n)) { @(Get-Content -LiteralPath (Out $n)).Count } else { 0 } }
    # A command that counts its runs in <name>.out.
    function Counting([string]$n) { "Add-Content -LiteralPath (Join-Path `$env:WINPKGS_ACT_HOME '$n.out') -Value ran" }
}

AfterAll {
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_ACT_HOME -ErrorAction SilentlyContinue
}

Describe 'winpkgs/activation' {
    It 'runs once for a revision, and again for a new one' {
        $doc = Write-Doc @('a') @{ count = @{ command = (Counting 'count'); revision = 'r1' } }
        Apply $doc
        Runs 'count' | Should -Be 1
        (Get-WinPkgsPlan -Document $doc | Where-Object Id -eq 'Activation count').Action | Should -Be 'noop'
        Apply $doc
        Runs 'count' | Should -Be 1
        Apply (Write-Doc @('a') @{ count = @{ command = (Counting 'count'); revision = 'r2' } })
        Runs 'count' | Should -Be 2
        (Read-WinPkgsState -Kind home)['activations']['count'] | Should -Be 'r2'
    }

    It 'runs after every other resource and after pruning' {
        Apply (Write-Doc @('a', 'b'))
        Test-Path (Join-Path $env:WINPKGS_ACT_HOME 'b.txt') | Should -BeTrue
        # b leaves the configuration: pruned. The activation, declared first,
        # must see a written and b gone.
        $see = "Set-Content -LiteralPath (Join-Path `$env:WINPKGS_ACT_HOME 'saw.out') -Value ((Test-Path (Join-Path `$env:WINPKGS_ACT_HOME 'a.txt')), (Test-Path (Join-Path `$env:WINPKGS_ACT_HOME 'b.txt')))"
        $doc = Write-Doc @('a') @{ see = @{ command = $see; revision = 'r1' } }
        $plan = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -ne 'noop')
        $plan[-1].Id | Should -Be 'Activation see'
        Apply $doc
        Get-Content -LiteralPath (Out 'saw') | Should -Be @('True', 'False')
    }

    It 'fails the apply when the command fails, and runs it again at the next' {
        $flag = Join-Path $env:WINPKGS_ACT_HOME 'fail.flag'
        Set-Content -LiteralPath $flag -Value 'x'
        # Exits 3 while the flag is there: a native program's exit code.
        $command = "$(Counting 'flaky'); if (Test-Path -LiteralPath (Join-Path `$env:WINPKGS_ACT_HOME 'fail.flag')) { cmd.exe /c exit 3 }"
        $doc = Write-Doc @('a') @{ flaky = @{ command = $command; revision = 'r1' } }
        { Apply $doc } | Should -Throw '*Activation flaky failed (exit code 3)*'
        (Read-WinPkgsState -Kind home)['activations'].ContainsKey('flaky') | Should -BeFalse
        Remove-Item -LiteralPath $flag
        Apply $doc
        Runs 'flaky' | Should -Be 2
        (Read-WinPkgsState -Kind home)['activations']['flaky'] | Should -Be 'r1'
    }

    It 'fails on a PowerShell error too' {
        $doc = Write-Doc @('a') @{ broken = @{ command = "throw 'no'"; revision = 'r1' } }
        { Apply $doc } | Should -Throw '*Activation broken failed*'
    }

    It 'runs with the PATH a new session would have' {
        $command = "Set-Content -LiteralPath (Join-Path `$env:WINPKGS_ACT_HOME 'path.out') -Value `$env:Path"
        $saved = $env:Path
        try {
            $env:Path = 'C:\only-in-this-process'
            Apply (Write-Doc @('a') @{ path = @{ command = $command; revision = 'r1' } })
        } finally { $env:Path = $saved }
        $seen = Get-Content -LiteralPath (Out 'path') -Raw
        $seen | Should -Not -Match 'only-in-this-process'
        $machine = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ })[0]
        $seen | Should -Match ([regex]::Escape([Environment]::ExpandEnvironmentVariables($machine)))
    }

    It 'forgets an activation that leaves the configuration, so it runs again when it comes back' {
        $doc = Write-Doc @('a') @{ back = @{ command = (Counting 'back'); revision = 'r1' } }
        Apply $doc
        Runs 'back' | Should -Be 1
        $gone = Write-Doc @('a')
        $entry = @(Get-WinPkgsPlan -Document $gone | Where-Object Id -eq 'Activation back')
        $entry.Action | Should -Be 'remove'
        $entry.Detail | Should -Match 'forgotten'
        Apply $gone
        (Read-WinPkgsState -Kind home)['activations'].ContainsKey('back') | Should -BeFalse
        # The same revision as the first time: it runs all the same.
        Apply $doc
        Runs 'back' | Should -Be 2
    }

    It 'describes what it runs, and a rollback runs it again' {
        $doc = Write-Doc @('a') @{ undo = @{ command = "$(Counting 'undo')`n# more"; revision = 'r1' } }
        $entry = Get-WinPkgsPlan -Document $doc | Where-Object Id -eq 'Activation undo'
        $entry.Detail | Should -Be "runs: $(Counting 'undo')"
        Apply $doc
        $gen = @(Get-ChildItem (Join-Path $env:WINPKGS_STATE_DIR 'home\generations') -Directory | Sort-Object Name)[-1].Name
        Invoke-WinPkgsRollback -Kind home -Generation ([int]$gen) -NoRestartExplorer 6>$null
        (Read-WinPkgsState -Kind home)['activations'].ContainsKey('undo') | Should -BeFalse
        Apply $doc
        Runs 'undo' | Should -Be 2
    }

    It 'is registered under its type' {
        Get-WinPkgsResourceType | Should -Contain 'winpkgs/activation'
    }
}
