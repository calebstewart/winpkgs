# The font resource on its own, then through plan/apply/prune/rollback as a
# home document. The fonts directory and the Fonts key are redirected into
# the test drive and HKCU\Software\winpkgs-tests; the files are not real fonts,
# so GDI declines to load them, which the resource treats as best effort.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Root = Join-Path $TestDrive 'closure'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'fonts\mono') | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'fonts\mono\Mono-Regular.ttf') -Value 'regular' -NoNewline
    Set-Content -LiteralPath (Join-Path $Root 'fonts\mono\Mono-Bold.otf') -Value 'bold' -NoNewline

    $env:WINPKGS_FONT_DIR = Join-Path $TestDrive 'fontdir'
    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $env:WINPKGS_FONT_KEY = "$TestKey\Fonts"

    $State = @{ owned = @{ winget = @(); files = @(); fonts = @{} } }
    $Ctx = @{ Root = $Root; State = $State }

    function Props { @{ name = 'mono'; source = 'fonts/mono'; scope = 'user' } }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [string]$BackupDir) {
        $splat = @{ Type = 'winpkgs/font'; Operation = $Operation; Properties = $P; Context = $Ctx }
        if ($Current) { $splat['Current'] = $Current }
        if ($BackupDir) { $splat['BackupDir'] = $BackupDir }
        Invoke-WinPkgsResource @splat
    }
    function Installed([string]$Name) { Join-Path $env:WINPKGS_FONT_DIR $Name }
    function Value([string]$Name) {
        $path = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5) + '\Fonts'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-Item -LiteralPath $path).GetValue($Name, $null)
    }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_FONT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_FONT_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
}

Describe 'winpkgs/font' {
    It 'installs every file, registers each, and records them in the ledger' {
        $p = Props
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
        Op Describe $p $c | Should -Be '2 font file(s)'
        Op Set $p $c
        Get-Content -LiteralPath (Installed 'Mono-Regular.ttf') -Raw | Should -Be 'regular'
        (Get-Item (Installed 'Mono-Regular.ttf')).IsReadOnly | Should -BeFalse
        Value 'Mono-Regular (TrueType)' | Should -Be (Installed 'Mono-Regular.ttf')
        Value 'Mono-Bold (OpenType)' | Should -Be (Installed 'Mono-Bold.otf')
        $c = Op Get $p
        Op Test $p $c | Should -BeTrue
        Op Describe $p $c | Should -Be '2 font file(s) present'
        $State.owned.fonts['mono'] | Should -Be @('Mono-Bold.otf', 'Mono-Regular.ttf')
    }

    It 'a changed file is drift' {
        $p = Props
        Set-Content -LiteralPath (Installed 'Mono-Bold.otf') -Value 'tampered' -NoNewline
        $c = Op Get $p
        Op Test $p $c | Should -BeFalse
        Op Set $p $c
        Get-Content -LiteralPath (Installed 'Mono-Bold.otf') -Raw | Should -Be 'bold'
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'a missing registration is drift' {
        $p = Props
        Remove-ItemProperty -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5) + '\Fonts') -Name 'Mono-Regular (TrueType)'
        $c = Op Get $p
        $c.files['Mono-Regular.ttf'].registered | Should -BeNullOrEmpty
        Op Test $p $c | Should -BeFalse
        Op Describe $p $c | Should -Be '2 font file(s) present'
        Op Set $p $c
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'a source missing from the closure is an error' {
        $gone = @{ name = 'mono'; source = 'fonts/gone'; scope = 'user' }
        { Op Test $gone (Op Get $gone) } | Should -Throw '*Source missing*'
    }

    It 'a prune entry removes the files its properties list, their values and the ledger entry' {
        $pruned = @{ name = 'mono'; source = $null; scope = 'user'; files = @('Mono-Bold.otf', 'Mono-Regular.ttf') }
        $State.owned.fonts.ContainsKey('mono') | Should -BeTrue
        Op Remove $pruned
        Test-Path (Installed 'Mono-Regular.ttf') | Should -BeFalse
        Test-Path (Installed 'Mono-Bold.otf') | Should -BeFalse
        Value 'Mono-Regular (TrueType)' | Should -BeNullOrEmpty
        Value 'Mono-Bold (OpenType)' | Should -BeNullOrEmpty
        $State.owned.fonts.ContainsKey('mono') | Should -BeFalse
    }

    It 'backs up a hand-installed file it overwrites' {
        $p = Props
        Set-Content -LiteralPath (Installed 'Mono-Regular.ttf') -Value 'someone elses' -NoNewline
        Set-ItemProperty -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5) + '\Fonts') -Name 'Mono-Regular (TrueType)' -Value 'C:\elsewhere\Mono-Regular.ttf' -Type String
        $c = Op Get $p
        $c.exists | Should -BeTrue
        Op Describe $p $c | Should -Be '1 of 2 font file(s) present'
        $extra = Op Backup $p $c (Join-Path $TestDrive 'backup0')
        Get-Content -LiteralPath (Join-Path $extra.backup 'Mono-Regular.ttf') -Raw | Should -Be 'someone elses'
        Test-Path (Join-Path $extra.backup 'Mono-Bold.otf') | Should -BeFalse
        Op Set $p $c
        Get-Content -LiteralPath (Installed 'Mono-Regular.ttf') -Raw | Should -Be 'regular'
        Value 'Mono-Regular (TrueType)' | Should -Be (Installed 'Mono-Regular.ttf')
        Op Test $p (Op Get $p) | Should -BeTrue

        # The next Describe starts from an empty fonts directory.
        Remove-Item -LiteralPath (Installed 'Mono-Regular.ttf'), (Installed 'Mono-Bold.otf') -Force
        Remove-ItemProperty -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5) + '\Fonts') -Name 'Mono-Regular (TrueType)', 'Mono-Bold (OpenType)'
    }
}

Describe 'fonts through plan, apply, prune and going back (home)' {
    BeforeAll {
        $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
        function Write-Doc([bool]$WithFont) {
            $resources = @()
            if ($WithFont) {
                $resources += @{ type = 'winpkgs/font'; id = 'mono'; scope = 'user'
                                 properties = @{ name = 'mono'; source = 'fonts/mono'; scope = 'user' } }
            }
            $path = Join-Path $Root 'config.json'
            @{ version = 2; kind = 'home'; name = 'font-test'
               settings = @{ prune = @{ winget = $false; files = $true }; generations = @{ keep = 10; deleteOlderThan = $null } }
               resources = @($resources) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
            return $path
        }
        function OwnedFonts { (Read-WinPkgsState -Kind home)['owned']['fonts'] }
    }

    It 'plans a create, applies it, and is then in the desired state' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc $true)
        $plan = @(Get-WinPkgsPlan -Document $doc)
        $plan.Count | Should -Be 1
        $plan[0].Action | Should -Be 'create'
        $plan[0].Detail | Should -Be '2 font file(s)'
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Test-Path (Installed 'Mono-Regular.ttf') | Should -BeTrue
        (OwnedFonts)['mono'] | Should -Be @('Mono-Bold.otf', 'Mono-Regular.ttf')
        @(Get-WinPkgsPlan -Document $doc | Where-Object Action -ne 'noop').Count | Should -Be 0
    }

    It 'plans a remove once the font leaves the document, and removes it' {
        $doc = Read-WinPkgsDocument -Path (Write-Doc $false)
        $removes = @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove')
        $removes.Count | Should -Be 1
        $removes[0].Type | Should -Be 'winpkgs/font'
        $removes[0].Id | Should -Be 'mono'
        Invoke-WinPkgsApply -Document $doc -NoRestartExplorer
        Test-Path (Installed 'Mono-Regular.ttf') | Should -BeFalse
        Value 'Mono-Regular (TrueType)' | Should -BeNullOrEmpty
        (OwnedFonts).ContainsKey('mono') | Should -BeFalse
    }

    It 'going back to before the prune brings files, registration and ownership back from the kept closure' {
        $before = @(Get-WinPkgsGeneration -Kind home)[-2]
        $kept = Read-WinPkgsDocument -Path (Join-Path $before.Path 'closure\config.json')
        Invoke-WinPkgsApply -Document $kept -Generation $before.Generation -NoRestartExplorer
        Get-Content -LiteralPath (Installed 'Mono-Regular.ttf') -Raw | Should -Be 'regular'
        Value 'Mono-Bold (OpenType)' | Should -Be (Installed 'Mono-Bold.otf')
        (OwnedFonts)['mono'] | Should -Be @('Mono-Bold.otf', 'Mono-Regular.ttf')
    }

    It 'honours prune.files = false' {
        $path = Write-Doc $false
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json.settings.prune.files = $false
        $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        $doc = Read-WinPkgsDocument -Path $path
        @(Get-WinPkgsPlan -Document $doc | Where-Object Action -eq 'remove').Count | Should -Be 0
    }
}
