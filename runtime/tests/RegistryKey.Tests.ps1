BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    # HKCU is user scope, so the keys here belong to a home configuration's
    # ledger; it goes in the test drive rather than this user's real state.
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'

    $TestRoot = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')

    function Props([string]$Suffix, [bool]$Present, [bool]$Force = $false) {
        @{ key = "$TestRoot\$Suffix"; present = $Present; force = $Force; restartExplorer = $false }
    }
    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [string]$Dir, [hashtable]$Context) {
        if (-not $Context) { $Context = $Ctx }
        $splat = @{ Type = 'winpkgs/registryKey'; Operation = $Operation; Properties = $P; Context = $Context }
        if ($Current) { $splat['Current'] = $Current }
        if ($Dir) { $splat['BackupDir'] = $Dir }
        Invoke-WinPkgsResource @splat
    }
    function Path([hashtable]$P) { 'Registry::HKEY_CURRENT_USER\' + $P.key.Substring(5) }

    # A context with its own ledger, as an apply builds one: `owned.registryKeys`
    # is what decides whether a delete goes ahead.
    function Ledger([string[]]$Owned = @()) {
        $state = Read-WinPkgsState -Kind home
        $state['owned']['registryKeys'] = @($Owned)
        return @{ Root = $TestDrive; State = $state; Kind = 'home' }
    }
    # The canonical spelling of a key under the test root: what the ledger keeps.
    function Id([string]$Suffix) {
        $id = 'HKEY_CURRENT_USER\' + $TestRoot.Substring(5)
        if ($Suffix) { return "$id\$Suffix" }
        return $id
    }
    function Owned([hashtable]$Context) { @($Context['State']['owned']['registryKeys']) }
    # The ledger as an apply leaves it, for a plan to read back.
    function Save-Ledger([hashtable]$Context) {
        Save-WinPkgsState -Kind home -State $Context['State']
    }

    $Ctx = Ledger
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestRoot.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINPKGS_STATE_DIR -ErrorAction SilentlyContinue
}

Describe 'winpkgs/registryKey' {
    It 'reports a missing key as absent and out of state' {
        $p = Props 'missing' $true
        $c = Op Get $p
        $c.exists | Should -BeFalse
        Op Test $p $c | Should -BeFalse
    }

    It 'creates a key and is then idempotent' {
        $p = Props 'make' $true
        Op Set $p (Op Get $p)
        $c = Op Get $p
        $c.exists | Should -BeTrue
        Op Test $p $c | Should -BeTrue
    }

    It 'is in state when an absent key should be absent' {
        $p = Props 'never' $false
        Op Test $p (Op Get $p) | Should -BeTrue
    }

    It 'deletes a key with its subkeys and values' {
        $p = Props 'doomed' $false
        New-Item -Path (Path $p) -Force | Out-Null
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 1 -Type DWord
        $ctx = Ledger @((Id 'doomed'))
        $c = Op Get $p -Context $ctx
        Op Test $p $c | Should -BeFalse
        Op Set $p $c -Context $ctx
        (Op Get $p -Context $ctx).exists | Should -BeFalse
    }

    It 'exports a key before it is deleted, values and subkeys included' {
        $p = Props 'exported' $false
        New-Item -Path (Path $p) -Force | Out-Null
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 42 -Type DWord

        $ctx = Ledger @((Id 'exported'))
        $current = Op Get $p -Context $ctx
        $extra = Op Backup $p $current (Join-Path $TestDrive 'backup') -Context $ctx
        $extra.backup | Should -Exist

        Op Set $p $current -Context $ctx
        (Op Get $p -Context $ctx).exists | Should -BeFalse

        # The export is the record of what was deleted: importing it puts the key back.
        $r = InModuleScope WinPkgs -Parameters @{ File = $extra.backup } { param($File) Invoke-WinPkgsReg -Arguments @('import', $File) }
        $r['failed'] | Should -BeFalse
        (Get-ItemProperty -LiteralPath (Path $p)).V | Should -Be 42
        (Test-Path -LiteralPath ((Path $p) + '\child')) | Should -BeTrue
    }

    It 'describes changes' {
        Op Describe (Props 'zz' $true) @{ exists = $false } | Should -Be 'absent -> present'
        Op Describe (Props 'zz' $false) @{ exists = $false } | Should -Be 'absent'
        Op Describe (Props 'zz' $false) @{ exists = $true; owned = $true } | Should -Be 'present -> absent'
    }
}

Describe 'winpkgs/registryKey ownership' {
    It 'owns the key it creates, and every ancestor it had to create with it' {
        $ctx = Ledger
        $p = Props 'owns\deep\leaf' $true
        Op Set $p (Op Get $p -Context $ctx) -Context $ctx
        # Not just the key asked for: creating it brought the two above it into
        # existence as well, and deleting either would take it with them.
        Owned $ctx | Should -Contain (Id 'owns')
        Owned $ctx | Should -Contain (Id 'owns\deep')
        Owned $ctx | Should -Contain (Id 'owns\deep\leaf')
    }

    It 'does not own a key that was already there' {
        $ctx = Ledger
        $p = Props 'existing' $true
        New-Item -Path (Path $p) -Force | Out-Null
        Op Set $p (Op Get $p -Context $ctx) -Context $ctx
        Owned $ctx | Should -Not -Contain (Id 'existing')
    }

    It 'owns the keys a value write had to create' {
        $ctx = Ledger
        Invoke-WinPkgsResource -Type 'winpkgs/registry' -Operation Set -Context $ctx `
            -Current @{ exists = $false } `
            -Properties @{ key = "$TestRoot\viavalue\inner"; name = 'V'; type = 'DWord'; value = 1 }
        Owned $ctx | Should -Contain (Id 'viavalue')
        Owned $ctx | Should -Contain (Id 'viavalue\inner')
    }

    It 'reports whether it created the key' {
        $p = Props 'reported' $false
        New-Item -Path (Path $p) -Force | Out-Null
        (Op Get $p -Context (Ledger)).owned | Should -BeFalse
        (Op Get $p -Context (Ledger @((Id 'reported')))).owned | Should -BeTrue
        # Case is not part of a key's identity.
        (Op Get $p -Context (Ledger @((Id 'reported').ToUpperInvariant()))).owned | Should -BeTrue
    }

    It 'refuses to delete a key it has no record of creating' {
        $p = Props 'not-ours' $false
        New-Item -Path (Path $p) -Force | Out-Null
        Set-ItemProperty -LiteralPath (Path $p) -Name 'V' -Value 7 -Type DWord
        $ctx = Ledger
        $c = Op Get $p -Context $ctx
        { Op Set $p $c -Context $ctx } | Should -Throw '*no record of creating it*'
        (Op Get $p -Context $ctx).exists | Should -BeTrue
        (Get-ItemProperty -LiteralPath (Path $p)).V | Should -Be 7
    }

    It 'exports nothing for a delete it is going to refuse' {
        $p = Props 'not-ours-either' $false
        New-Item -Path (Path $p) -Force | Out-Null
        $ctx = Ledger
        $dir = Join-Path $TestDrive 'refused-backup'
        $extra = Op Backup $p (Op Get $p -Context $ctx) $dir -Context $ctx
        $extra.Keys | Should -BeNullOrEmpty
        (Test-Path -LiteralPath $dir) | Should -BeFalse
    }

    It 'says in a plan that a delete is refused' {
        Op Describe (Props 'zz' $false) @{ exists = $true; owned = $false } |
            Should -Be 'exists, and winpkgs has no record of creating it: refused'
        Op Describe (Props 'zz' $false $true) @{ exists = $true; owned = $false } | Should -Be 'present -> absent'
    }

    It 'deletes a key it has no record of creating when force says so' {
        $p = Props 'forced' $false $true
        New-Item -Path (Path $p) -Force | Out-Null
        $ctx = Ledger
        Op Set $p (Op Get $p -Context $ctx) -Context $ctx
        (Op Get $p -Context $ctx).exists | Should -BeFalse
    }

    It 'deletes a key it created in the same apply' {
        $ctx = Ledger
        $create = Props 'roundtrip' $true
        Op Set $create (Op Get $create -Context $ctx) -Context $ctx
        $delete = Props 'roundtrip' $false
        Op Set $delete (Op Get $delete -Context $ctx) -Context $ctx
        (Op Get $delete -Context $ctx).exists | Should -BeFalse
    }

    It 'reads ownership from the saved ledger when there is no apply in progress' {
        $p = Props 'from-disk' $false
        New-Item -Path (Path $p) -Force | Out-Null
        $ctx = Ledger @((Id 'from-disk'))
        Save-Ledger $ctx
        # A plan's context carries the kind and no ledger of its own.
        (Op Get $p -Context @{ Kind = 'home' }).owned | Should -BeTrue
        Save-Ledger (Ledger)
        (Op Get $p -Context @{ Kind = 'home' }).owned | Should -BeFalse
    }

    It 'forgets a deleted key and everything recorded under it' {
        $p = Props 'forgotten' $false
        New-Item -Path ((Path $p) + '\child') -Force | Out-Null
        $ctx = Ledger @((Id 'forgotten'), (Id 'forgotten\child'), (Id 'kept'))
        Op Set $p (Op Get $p -Context $ctx) -Context $ctx
        Owned $ctx | Should -Be @((Id 'kept'))
    }

    It 'refuses the same path again once something else has recreated it' {
        $ctx = Ledger
        $create = Props 'recreated' $true
        Op Set $create (Op Get $create -Context $ctx) -Context $ctx
        $delete = Props 'recreated' $false
        Op Set $delete (Op Get $delete -Context $ctx) -Context $ctx

        # Somebody else's key, at the path winpkgs used to own.
        New-Item -Path (Path $delete) -Force | Out-Null
        $c = Op Get $delete -Context $ctx
        $c.owned | Should -BeFalse
        { Op Set $delete $c -Context $ctx } | Should -Throw '*no record of creating it*'
    }
}

# The path arithmetic ownership rests on, on its own: a key is one thing however
# it is spelled, and forgetting one forgets what was under it.
Describe 'registry key identity' {
    It 'spells a key one way whatever the document said' {
        InModuleScope WinPkgs {
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKCU\Software\X' | Should -BeExactly 'HKEY_CURRENT_USER\Software\X'
            ConvertTo-WinPkgsRegistryKeyId -Key 'hkcu\Software\X' | Should -BeExactly 'HKEY_CURRENT_USER\Software\X'
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKEY_CURRENT_USER\Software\X' | Should -BeExactly 'HKEY_CURRENT_USER\Software\X'
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKCU\Software\X\' | Should -BeExactly 'HKEY_CURRENT_USER\Software\X'
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKCU\\Software\\\X' | Should -BeExactly 'HKEY_CURRENT_USER\Software\X'
            # A key name's own case is not winpkgs' to change.
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKCU\SoFtWaRe\x' | Should -BeExactly 'HKEY_CURRENT_USER\SoFtWaRe\x'
            ConvertTo-WinPkgsRegistryKeyId -Key 'HKCU' | Should -BeExactly 'HKEY_CURRENT_USER'
        }
    }

    It 'names a key and every ancestor under its hive, outermost first' {
        InModuleScope WinPkgs {
            @(Get-WinPkgsRegistryKeyChain -Key 'HKCU\A\B\C') | Should -Be @(
                'HKEY_CURRENT_USER\A', 'HKEY_CURRENT_USER\A\B', 'HKEY_CURRENT_USER\A\B\C')
            @(Get-WinPkgsRegistryKeyChain -Key 'HKLM\SOFTWARE') | Should -Be @('HKEY_LOCAL_MACHINE\SOFTWARE')
            # Nothing creates or deletes a hive.
            @(Get-WinPkgsRegistryKeyChain -Key 'HKLM').Count | Should -Be 0
        }
    }

    It 'owns a key, not its parent and not its children' {
        InModuleScope WinPkgs {
            $ctx = @{ State = @{ owned = @{ registryKeys = @('HKEY_CURRENT_USER\Software\Mine') } }; Kind = 'home' }
            Test-WinPkgsRegistryKeyOwned -Key 'hkcu\software\MINE' -Context $ctx | Should -BeTrue
            Test-WinPkgsRegistryKeyOwned -Key 'HKCU\Software' -Context $ctx | Should -BeFalse
            Test-WinPkgsRegistryKeyOwned -Key 'HKCU\Software\Mine\Sub' -Context $ctx | Should -BeFalse
        }
    }

    It 'records each key once, and records nothing when nothing was created' {
        InModuleScope WinPkgs {
            $ctx = @{ State = @{ owned = @{ registryKeys = @() } } }
            Add-WinPkgsOwnedRegistryKey -Context $ctx -Keys @('HKCU\A', 'HKCU\A\B')
            @($ctx.State.owned.registryKeys) | Should -Be @('HKEY_CURRENT_USER\A', 'HKEY_CURRENT_USER\A\B')
            Add-WinPkgsOwnedRegistryKey -Context $ctx -Keys @('hkcu\a')
            @($ctx.State.owned.registryKeys).Count | Should -Be 2
            Add-WinPkgsOwnedRegistryKey -Context $ctx -Keys @()
            @($ctx.State.owned.registryKeys).Count | Should -Be 2
        }
    }

    It 'forgets a key with what was recorded under it, and nothing beside it' {
        InModuleScope WinPkgs {
            $ctx = @{ State = @{ owned = @{ registryKeys = @(
                'HKEY_CURRENT_USER\A', 'HKEY_CURRENT_USER\A\B', 'HKEY_CURRENT_USER\A\B\C',
                'HKEY_CURRENT_USER\AB', 'HKEY_CURRENT_USER\Other') } } }
            Remove-WinPkgsOwnedRegistryKey -Context $ctx -Key 'hkcu\a'
            @($ctx.State.owned.registryKeys) | Should -Be @('HKEY_CURRENT_USER\AB', 'HKEY_CURRENT_USER\Other')
        }
    }
}
