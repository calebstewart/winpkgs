# The computer name resource against a redirected key, where the rename is
# the pending value rather than Rename-Computer.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $env:WINPKGS_COMPUTERNAME_KEY = $TestKey
    $base = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)
    foreach ($sub in 'ActiveComputerName', 'ComputerName') {
        New-Item -Path "$base\$sub" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$base\$sub" -Name ComputerName -Value 'OLD-NAME' -Type String
    }

    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/computerName'; Operation = $Operation; Properties = $P; Context = @{} }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function Pending { (Get-Item -LiteralPath "$base\ComputerName").GetValue('ComputerName') }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_COMPUTERNAME_KEY -ErrorAction SilentlyContinue
}

Describe 'winpkgs/computerName' {
    It 'is in state when the pending name matches, case aside' {
        $c = Op Get @{ name = 'old-name' }
        $c.active | Should -Be 'OLD-NAME'
        $c.pending | Should -Be 'OLD-NAME'
        Op Test @{ name = 'old-name' } $c | Should -BeTrue
        Op Test @{ name = 'new-name' } $c | Should -BeFalse
        Op Describe @{ name = 'new-name' } $c | Should -Be 'OLD-NAME -> new-name (after a restart)'
    }

    It 'renames by setting the pending name, and restores it' {
        $p = @{ name = 'new-name' }
        $before = Op Get $p
        Op Set $p $before
        Pending | Should -Be 'new-name'
        $c = Op Get $p
        $c.active | Should -Be 'OLD-NAME'      # until the restart
        Op Test $p $c | Should -BeTrue
        Op Restore $p $null $before
        Pending | Should -Be 'OLD-NAME'
    }
}
