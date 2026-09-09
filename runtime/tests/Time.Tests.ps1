# The two time resources against stand-in tools: a tzutil that keeps one zone
# in a file, a w32tm that records every call and can be told to fail /resync
# the way the real one does with no network. The w32time settings go to a
# redirected key and the service to a state file, so nothing here touches the
# machine's clock, its zone, or its services.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $Root = 'Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $TestKey = "HKCU\$Root\W32Time"
    $env:WINPKGS_W32TIME_KEY = $TestKey

    $ZoneState = Join-Path $TestDrive 'tz-state.txt'
    $ZoneLog = Join-Path $TestDrive 'tz-log.txt'
    $W32Log = Join-Path $TestDrive 'w32tm-log.txt'
    $SvcState = Join-Path $TestDrive 'w32time-service.txt'
    Set-Content -LiteralPath $ZoneState -Value 'Central Standard Time'
    Set-Content -LiteralPath $ZoneLog -Value ''
    Set-Content -LiteralPath $W32Log -Value ''
    Set-Content -LiteralPath $SvcState -Value @('startType=Manual', 'running=False')

    $env:WINPKGS_TZUTIL_STATE = $ZoneState
    $env:WINPKGS_TZUTIL_LOG = $ZoneLog
    $env:WINPKGS_W32TM_LOG = $W32Log
    $env:WINPKGS_W32TIME_SERVICE_STATE = $SvcState

    $FakeTz = Join-Path $TestDrive 'tzutil.ps1'
    Set-Content -LiteralPath $FakeTz -Value @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Add-Content -LiteralPath $env:WINPKGS_TZUTIL_LOG -Value ($Arguments -join ' ')
switch ($Arguments[0]) {
    '/g' { Get-Content -LiteralPath $env:WINPKGS_TZUTIL_STATE; exit 0 }
    '/s' {
        if ($Arguments[1] -eq 'Nowhere Standard Time') { Write-Error 'The specified time zone was not found.'; exit 1 }
        Set-Content -LiteralPath $env:WINPKGS_TZUTIL_STATE -Value $Arguments[1]; exit 0
    }
}
Write-Error "fake tzutil: unknown $($Arguments -join ' ')"
exit 1
'@
    $env:WINPKGS_TZUTIL = $FakeTz

    $FakeW32tm = Join-Path $TestDrive 'w32tm.ps1'
    Set-Content -LiteralPath $FakeW32tm -Value @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Add-Content -LiteralPath $env:WINPKGS_W32TM_LOG -Value ($Arguments -join ' ')
if ($Arguments[0] -eq '/resync' -and $env:WINPKGS_W32TM_RESYNC_FAILS -eq '1') {
    Write-Error 'The computer did not resync because no time data was available.'
    exit 1
}
exit 0
'@
    $env:WINPKGS_W32TM = $FakeW32tm

    function Op([string]$Type, [string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = $Type; Operation = $Operation; Properties = $P; Context = @{} }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function W32Calls { @(Get-Content -LiteralPath $W32Log | Where-Object { $_ }) }
    function ClearW32Calls { Set-Content -LiteralPath $W32Log -Value '' }
    function Reg([string]$Sub, [string]$Name) {
        $path = "Registry::HKEY_CURRENT_USER\$Root\W32Time\$Sub"
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $k = Get-Item -LiteralPath $path
        if (@($k.GetValueNames()) -notcontains $Name) { return $null }
        return $k.GetValue($Name)
    }
    function Svc { $h = @{}; foreach ($l in Get-Content -LiteralPath $SvcState) { if ($l -match '^(.*?)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }; $h }
    function ResetSvc { Set-Content -LiteralPath $SvcState -Value @('startType=Manual', 'running=False') }
    function ClearSettings {
        $path = "Registry::HKEY_CURRENT_USER\$Root\W32Time"
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

AfterAll {
    Remove-Item -LiteralPath "Registry::HKEY_CURRENT_USER\$Root" -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'WINPKGS_W32TIME_KEY', 'WINPKGS_TZUTIL', 'WINPKGS_TZUTIL_STATE', 'WINPKGS_TZUTIL_LOG',
        'WINPKGS_W32TM', 'WINPKGS_W32TM_LOG', 'WINPKGS_W32TM_RESYNC_FAILS', 'WINPKGS_W32TIME_SERVICE_STATE') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'winpkgs/timeZone' {
    It 'reads the zone, switches it, and puts it back' {
        $p = @{ id = 'Eastern Standard Time' }
        $c = Op winpkgs/timeZone Get $p
        $c.id | Should -Be 'Central Standard Time'
        Op winpkgs/timeZone Test $p $c | Should -BeFalse
        Op winpkgs/timeZone Describe $p $c | Should -Be 'Central Standard Time -> Eastern Standard Time'
        Op winpkgs/timeZone Set $p $c
        (Op winpkgs/timeZone Get $p).id | Should -Be 'Eastern Standard Time'
        Op winpkgs/timeZone Test $p (Op winpkgs/timeZone Get $p) | Should -BeTrue
        Op winpkgs/timeZone Restore $p $null $c
        (Op winpkgs/timeZone Get $p).id | Should -Be 'Central Standard Time'
    }

    It 'compares ids without regard to case' {
        Op winpkgs/timeZone Test @{ id = 'central standard time' } @{ id = 'Central Standard Time' } | Should -BeTrue
    }

    It 'an id the machine does not know fails with the command that lists them' {
        { Op winpkgs/timeZone Set @{ id = 'Nowhere Standard Time' } @{ id = 'Central Standard Time' } } |
            Should -Throw -ExpectedMessage '*tzutil /l*'
    }
}

Describe 'winpkgs/timeSync' {
    BeforeEach {
        ClearSettings
        ResetSvc
        ClearW32Calls
        Remove-Item Env:\WINPKGS_W32TM_RESYNC_FAILS -ErrorAction SilentlyContinue
    }

    It 'settings that were never written read as unset, and are written together and reloaded' {
        $p = @{ enabled = $true; servers = 'time.cloudflare.com,0x9'; pollInterval = 3600; maxCorrection = 54000; resync = $true }
        $c = Op winpkgs/timeSync Get $p
        $c.servers | Should -BeNullOrEmpty
        $c.enabled | Should -BeNullOrEmpty
        $c.pollInterval | Should -BeNullOrEmpty
        Op winpkgs/timeSync Test $p $c | Should -BeFalse

        Op winpkgs/timeSync Set $p $c
        Reg 'Parameters' 'NtpServer' | Should -Be 'time.cloudflare.com,0x9'
        Reg 'Parameters' 'Type' | Should -Be 'NTP'
        Reg 'TimeProviders\NtpClient' 'Enabled' | Should -Be 1
        Reg 'TimeProviders\NtpClient' 'SpecialPollInterval' | Should -Be 3600
        Reg 'Config' 'MaxPosPhaseCorrection' | Should -Be 54000
        Reg 'Config' 'MaxNegPhaseCorrection' | Should -Be 54000
        W32Calls | Should -Contain '/config /update'
        W32Calls | Should -Contain '/resync /force'
        (Svc)['startType'] | Should -Be 'Automatic'
        (Svc)['running'] | Should -Be 'True'

        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
    }

    It 'a null setting is left alone' {
        $p = @{ enabled = $null; servers = $null; pollInterval = 900; maxCorrection = $null; resync = $false }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p)
        Reg 'TimeProviders\NtpClient' 'SpecialPollInterval' | Should -Be 900
        Reg 'TimeProviders\NtpClient' 'Enabled' | Should -BeNullOrEmpty
        Reg 'Parameters' 'NtpServer' | Should -BeNullOrEmpty
        Reg 'Config' 'MaxPosPhaseCorrection' | Should -BeNullOrEmpty
        W32Calls | Should -Contain '/config /update'
        @(W32Calls | Where-Object { $_ -like '/resync*' }).Count | Should -Be 0
        (Svc)['startType'] | Should -Be 'Manual'   # untouched: enable said nothing
        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
    }

    It 'enabled but left on a manual start is not synchronised' {
        $p = @{ enabled = $true; servers = $null; pollInterval = $null; maxCorrection = $null; resync = $false }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p)
        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
        ResetSvc
        $c = Op winpkgs/timeSync Get $p
        $c.startType | Should -Be 'Manual'
        Op winpkgs/timeSync Test $p $c | Should -BeFalse
        Op winpkgs/timeSync Describe $p $c | Should -BeLike '*service Manual -> Automatic*'
    }

    It 'switching sync off writes NoSync and does not resync' {
        $p = @{ enabled = $false; servers = $null; pollInterval = $null; maxCorrection = $null; resync = $true }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p)
        Reg 'TimeProviders\NtpClient' 'Enabled' | Should -Be 0
        Reg 'Parameters' 'Type' | Should -Be 'NoSync'
        @(W32Calls | Where-Object { $_ -like '/resync*' }).Count | Should -Be 0
        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
    }

    It 'an unlimited correction survives the round trip through a DWord' {
        $p = @{ enabled = $null; servers = $null; pollInterval = $null; maxCorrection = 4294967295; resync = $false }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p)
        (Op winpkgs/timeSync Get $p).maxPos | Should -Be 4294967295
        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
    }

    It 'a resync that fails warns but leaves the configuration applied' {
        $env:WINPKGS_W32TM_RESYNC_FAILS = '1'
        $p = @{ enabled = $true; servers = 'time.nist.gov,0x9'; pollInterval = $null; maxCorrection = $null; resync = $true }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p) 3>$null
        Reg 'Parameters' 'NtpServer' | Should -Be 'time.nist.gov,0x9'
        Op winpkgs/timeSync Test $p (Op winpkgs/timeSync Get $p) | Should -BeTrue
    }

    It 'restore removes settings that were absent and puts back the ones that were not' {
        # A machine that had a peer list and nothing else.
        $p = @{ enabled = $true; servers = 'time.cloudflare.com,0x9'; pollInterval = 3600; maxCorrection = 54000; resync = $false }
        $before = @{
            exists = $true; servers = 'time.windows.com,0x9'; type = 'NTP'; enabled = $null
            pollInterval = $null; maxPos = $null; maxNeg = $null; startType = 'Manual'; running = $false
        }
        Op winpkgs/timeSync Set $p (Op winpkgs/timeSync Get $p)
        Op winpkgs/timeSync Restore $p $null $before

        $c = Op winpkgs/timeSync Get $p
        $c.servers | Should -Be 'time.windows.com,0x9'
        $c.type | Should -Be 'NTP'
        $c.enabled | Should -BeNullOrEmpty
        $c.pollInterval | Should -BeNullOrEmpty
        $c.maxPos | Should -BeNullOrEmpty
        (Svc)['startType'] | Should -Be 'Manual'
        W32Calls | Should -Contain '/config /update'
    }

    It 'describes only what it is changing' {
        $p = @{ enabled = $null; servers = $null; pollInterval = 3600; maxCorrection = $null; resync = $false }
        $c = @{ exists = $true; servers = 'time.windows.com,0x9'; type = 'NTP'; enabled = $true
            pollInterval = 32768; maxPos = 54000; maxNeg = 54000; startType = 'Manual'; running = $true
        }
        Op winpkgs/timeSync Describe $p $c | Should -Be 'poll 32768s -> 3600s'
    }

    It 'a setting already at the wanted value is not described as a change' {
        # Everything matches but the peer list and the start type; the poll
        # interval and the correction must not print as "3600s -> 3600s".
        $p = @{ enabled = $true; servers = 'time.cloudflare.com,0x9'; pollInterval = 3600; maxCorrection = 54000; resync = $true }
        $c = @{ exists = $true; servers = 'time.windows.com,0x9'; type = 'NTP'; enabled = $true
            pollInterval = 3600; maxPos = 54000; maxNeg = 54000; startType = 'Manual'; running = $false
        }
        Op winpkgs/timeSync Describe $p $c |
            Should -Be 'peers time.windows.com,0x9 -> time.cloudflare.com,0x9, service Manual -> Automatic'
    }
}
