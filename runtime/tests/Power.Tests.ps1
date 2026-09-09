# The three power resources against a stand-in powercfg: a script that keeps
# a scheme table in a file, answers /getactivescheme and /query the way the
# real one does (localised words, hex indexes on the last two lines, decoy
# hex lines above them), and records every call. The hibernation flag goes to
# a redirected key. Nothing touches the machine's power settings.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $HighPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $SubSleep = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    $StandbyIdle = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
    $GuidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

    $StateFile = Join-Path $TestDrive 'powercfg-state.txt'
    $LogFile = Join-Path $TestDrive 'powercfg-log.txt'
    Set-Content -LiteralPath $StateFile -Value "active=$Balanced"
    Set-Content -LiteralPath $LogFile -Value ''

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $env:WINPKGS_POWER_KEY = $TestKey
    $env:WINPKGS_POWERCFG_STATE = $StateFile
    $env:WINPKGS_POWERCFG_LOG = $LogFile

    $Fake = Join-Path $TestDrive 'powercfg.ps1'
    Set-Content -LiteralPath $Fake -Value @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$stateFile = $env:WINPKGS_POWERCFG_STATE
$state = @{}
foreach ($line in Get-Content -LiteralPath $stateFile) { if ($line -match '^(.*?)=(.*)$') { $state[$Matches[1]] = $Matches[2] } }
Add-Content -LiteralPath $env:WINPKGS_POWERCFG_LOG -Value ($Arguments -join ' ')
function Save { $state.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -LiteralPath $stateFile }
switch ($Arguments[0].ToLowerInvariant()) {
    '/getactivescheme' {
        # Stand-ins for the two ways a healthy tool trips $ErrorActionPreference.
        if ($env:WINPKGS_POWERCFG_NOISY) { Write-Error 'powercfg: diagnostics on stderr' }
        if ($env:WINPKGS_POWERCFG_FAIL) { Write-Error 'powercfg: the parameter is incorrect'; exit 1 }
        "Schéma d'alimentation GUID: $($state['active'])  (Faux)"; exit 0
    }
    '/attributes' {
        if ($Arguments[3] -eq '-ATTRIB_HIDE') { $state.Remove("hidden/$($Arguments[2])") } else { $state["hidden/$($Arguments[2])"] = 1 }
        Save; exit 0
    }
    '/query' {
        $scheme = $Arguments[1].ToLowerInvariant(); $sub = $Arguments[2]; $setting = $Arguments[3]
        if ($state.ContainsKey("hidden/$setting")) { "Schéma d'alimentation GUID: $scheme  (Faux)"; "  Alias du GUID: SCHEME_BALANCED"; exit 0 }
        $ac = $state["$scheme/$sub/$setting/ac"]; if (-not $ac) { $ac = 300 }
        $dc = $state["$scheme/$sub/$setting/dc"]; if (-not $dc) { $dc = 180 }
        "Schéma d'alimentation GUID: $scheme  (Faux)"
        "  GUID du sous-groupe: $sub  (Veille)"
        "    GUID du paramètre: $setting  (Mettre en veille après)"
        "      Paramètre minimal possible: 0x00000000"
        "      Paramètre maximal possible: 0xffffffff"
        "      Incrément des paramètres possibles: 0x00000001"
        "      Unités des paramètres possibles: Secondes"
        ("    Index du paramètre d'alimentation secteur actuel: 0x{0:x8}" -f [int]$ac)
        ("    Index du paramètre d'alimentation batterie actuel: 0x{0:x8}" -f [int]$dc)
        exit 0
    }
    '/setacvalueindex' { $state["$($Arguments[1].ToLowerInvariant())/$($Arguments[2])/$($Arguments[3])/ac"] = $Arguments[4]; Save; exit 0 }
    '/setdcvalueindex' { $state["$($Arguments[1].ToLowerInvariant())/$($Arguments[2])/$($Arguments[3])/dc"] = $Arguments[4]; Save; exit 0 }
    '/setactive' { $state['active'] = $Arguments[1].ToLowerInvariant(); Save; exit 0 }
    '/hibernate' {
        $path = 'Registry::HKEY_CURRENT_USER\' + $env:WINPKGS_POWER_KEY.Substring(5)
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $path -Name HibernateEnabled -Value $(if ($Arguments[1] -eq 'on') { 1 } else { 0 }) -Type DWord
        exit 0
    }
}
Write-Error "fake powercfg: unknown $($Arguments -join ' ')"
exit 1
'@
    $env:WINPKGS_POWERCFG = $Fake

    function Op([string]$Type, [string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = $Type; Operation = $Operation; Properties = $P; Context = @{} }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function Calls { @(Get-Content -LiteralPath $LogFile | Where-Object { $_ }) }
    function ClearCalls { Set-Content -LiteralPath $LogFile -Value '' }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'WINPKGS_POWER_KEY', 'WINPKGS_POWERCFG', 'WINPKGS_POWERCFG_STATE', 'WINPKGS_POWERCFG_LOG',
        'WINPKGS_POWERCFG_NOISY', 'WINPKGS_POWERCFG_FAIL') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

Describe 'winpkgs/powerPlan' {
    It 'reads the active scheme from whatever words surround its guid, and switches it' {
        $p = @{ guid = $HighPerf }
        $c = Op winpkgs/powerPlan Get $p
        $c.guid | Should -Be $Balanced
        Op winpkgs/powerPlan Test $p $c | Should -BeFalse
        Op winpkgs/powerPlan Describe $p $c | Should -Be "$Balanced -> $HighPerf"
        Op winpkgs/powerPlan Set $p $c
        Calls | Should -Contain "/setactive $HighPerf"
        Op winpkgs/powerPlan Test $p (Op winpkgs/powerPlan Get $p) | Should -BeTrue
        Op winpkgs/powerPlan Restore $p $null $c
        (Op winpkgs/powerPlan Get $p).guid | Should -Be $Balanced
    }

    It 'reads a scheme from a powercfg that also wrote to stderr' {
        # powercfg, reg.exe and winget all chat on stderr while succeeding, and
        # under $ErrorActionPreference = 'Stop' the 2>&1 redirect used to make
        # that a terminating error before the exit code was ever consulted.
        $env:WINPKGS_POWERCFG_NOISY = '1'
        try {
            (Op winpkgs/powerPlan Get @{ guid = $HighPerf }).guid | Should -Match $GuidPattern
        } finally { Remove-Item Env:\WINPKGS_POWERCFG_NOISY -ErrorAction SilentlyContinue }
    }

    It 'a non-zero exit still throws, quoting what powercfg said' {
        $env:WINPKGS_POWERCFG_FAIL = '1'
        try {
            { Op winpkgs/powerPlan Get @{ guid = $HighPerf } } |
                Should -Throw -ExpectedMessage '*the parameter is incorrect*'
        } finally { Remove-Item Env:\WINPKGS_POWERCFG_FAIL -ErrorAction SilentlyContinue }
    }
}

Describe 'winpkgs/powerSetting' {
    It 'takes the AC and DC indexes from the last two hex lines and writes both sides' {
        ClearCalls
        $p = @{ label = 'sleep.computer'; scheme = $null; subgroup = $SubSleep; setting = $StandbyIdle; ac = 0; dc = 1800 }
        $c = Op winpkgs/powerSetting Get $p
        $c.scheme | Should -Be $Balanced
        $c.ac | Should -Be 300
        $c.dc | Should -Be 180
        Op winpkgs/powerSetting Test $p $c | Should -BeFalse
        Op winpkgs/powerSetting Describe $p $c | Should -Be 'AC 5 min -> 0 (never), battery 3 min -> 30 min'
        Op winpkgs/powerSetting Set $p $c
        Calls | Should -Contain "/setacvalueindex $Balanced $SubSleep $StandbyIdle 0"
        Calls | Should -Contain "/setdcvalueindex $Balanced $SubSleep $StandbyIdle 1800"
        Calls | Should -Contain "/setactive $Balanced"   # the active scheme re-read
        $c = Op winpkgs/powerSetting Get $p
        $c.ac | Should -Be 0
        $c.dc | Should -Be 1800
        Op winpkgs/powerSetting Test $p $c | Should -BeTrue
    }

    It 'a named scheme is read and written without touching the active one; a null side is left alone' {
        ClearCalls
        $p = @{ label = 'sleep.computer'; scheme = $HighPerf; subgroup = $SubSleep; setting = $StandbyIdle; ac = 600; dc = $null }
        $c = Op winpkgs/powerSetting Get $p
        $c.scheme | Should -Be $HighPerf
        $c.ac | Should -Be 300
        Op winpkgs/powerSetting Test $p $c | Should -BeFalse
        Op winpkgs/powerSetting Describe $p $c | Should -Be 'AC 5 min -> 10 min'
        Op winpkgs/powerSetting Set $p $c
        Calls | Should -Contain "/setacvalueindex $HighPerf $SubSleep $StandbyIdle 600"
        Calls | Should -Not -Contain "/setactive $HighPerf"
        @(Calls | Where-Object { $_ -like '/setdcvalueindex*' }).Count | Should -Be 0
        Op winpkgs/powerSetting Test $p (Op winpkgs/powerSetting Get $p) | Should -BeTrue
    }

    It 'a hidden setting is unknown, unhidden on Set, and hidden again on Restore' {
        ClearCalls
        $button = '7648efa3-dd9c-4e3e-b566-50f929386280'
        Add-Content -LiteralPath $StateFile -Value "hidden/$button=1"
        $p = @{ label = 'buttons.power'; scheme = $null; subgroup = '4f971e89-eebd-4455-a8de-9e59040e7347'; setting = $button; ac = 3; dc = 3 }
        $c = Op winpkgs/powerSetting Get $p
        $c.hidden | Should -BeTrue
        $c.ac | Should -BeNullOrEmpty
        Op winpkgs/powerSetting Test $p $c | Should -BeFalse
        Op winpkgs/powerSetting Describe $p $c | Should -Be 'AC hidden -> 3, battery hidden -> 3'
        Op winpkgs/powerSetting Set $p $c
        Calls | Should -Contain "/attributes 4f971e89-eebd-4455-a8de-9e59040e7347 $button -ATTRIB_HIDE"
        $after = Op winpkgs/powerSetting Get $p
        $after.hidden | Should -BeFalse
        $after.ac | Should -Be 3
        Op winpkgs/powerSetting Test $p $after | Should -BeTrue
        Op winpkgs/powerSetting Restore $p $null $c
        Calls | Should -Contain "/attributes 4f971e89-eebd-4455-a8de-9e59040e7347 $button +ATTRIB_HIDE"
        (Op winpkgs/powerSetting Get $p).hidden | Should -BeTrue
    }

    It 'restores the recorded indexes' {
        $p = @{ label = 'sleep.computer'; scheme = $null; subgroup = $SubSleep; setting = $StandbyIdle; ac = 0; dc = 1800 }
        $before = @{ exists = $true; scheme = $Balanced; ac = 300; dc = 180 }
        Op winpkgs/powerSetting Restore $p $null $before
        $c = Op winpkgs/powerSetting Get $p
        $c.ac | Should -Be 300
        $c.dc | Should -Be 180
    }
}

Describe 'winpkgs/hibernation' {
    It 'an absent flag is the default, reported and then written' {
        $p = @{ enabled = $false }
        $c = Op winpkgs/hibernation Get $p
        $c.enabled | Should -BeNullOrEmpty
        Op winpkgs/hibernation Test $p $c | Should -BeFalse
        Op winpkgs/hibernation Describe $p $c | Should -Be 'default -> off'
        Op winpkgs/hibernation Set $p $c
        Calls | Should -Contain '/hibernate off'
        $c = Op winpkgs/hibernation Get $p
        $c.enabled | Should -BeFalse
        Op winpkgs/hibernation Test $p $c | Should -BeTrue
        Op winpkgs/hibernation Test @{ enabled = $true } $c | Should -BeFalse
    }

    It 'restoring an absent flag turns hibernation back on' {
        Op winpkgs/hibernation Restore @{ enabled = $false } $null @{ exists = $true; enabled = $null }
        (Op winpkgs/hibernation Get @{ enabled = $true }).enabled | Should -BeTrue
    }
}
