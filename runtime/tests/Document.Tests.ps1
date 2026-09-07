BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    function New-Doc([hashtable]$Doc, [string]$Name = 'config.json') {
        $path = Join-Path $TestDrive $Name
        $Doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    function Reg([string]$Id) {
        @{ type = 'winpkgs/registry'; id = $Id; scope = 'user'
           properties = @{ key = 'HKCU\Software\x'; name = 'v'; type = 'DWord'; value = 1; restartExplorer = $false } }
    }
}

Describe 'Read-WinPkgsDocument' {
    It 'loads a valid document and records root and path' {
        $p = New-Doc @{ version = 1; name = 't'; resources = @(Reg 'a') }
        $doc = Read-WinPkgsDocument -Path $p
        $doc['name'] | Should -Be 't'
        $doc['root'] | Should -Be (Split-Path -Parent $p)
        $doc['path'] | Should -Be $p
        @($doc['resources']).Count | Should -Be 1
    }

    It 'accepts an empty resource list' {
        $p = New-Doc @{ version = 1; name = 't'; resources = @() }
        { Read-WinPkgsDocument -Path $p } | Should -Not -Throw
    }

    It 'rejects an unsupported version' {
        $p = New-Doc @{ version = 2; name = 't'; resources = @() }
        { Read-WinPkgsDocument -Path $p } | Should -Throw '*version*'
    }

    It 'rejects an unknown resource type' {
        $r = Reg 'a'; $r.type = 'winpkgs/nope'
        $p = New-Doc @{ version = 1; name = 't'; resources = @($r) }
        { Read-WinPkgsDocument -Path $p } | Should -Throw '*unknown type*'
    }

    It 'rejects an invalid scope' {
        $r = Reg 'a'; $r.scope = 'galaxy'
        $p = New-Doc @{ version = 1; name = 't'; resources = @($r) }
        { Read-WinPkgsDocument -Path $p } | Should -Throw '*invalid scope*'
    }

    It 'rejects duplicate ids' {
        $p = New-Doc @{ version = 1; name = 't'; resources = @((Reg 'a'), (Reg 'a')) }
        { Read-WinPkgsDocument -Path $p } | Should -Throw '*Duplicate*'
    }

    It 'rejects a missing file' {
        { Read-WinPkgsDocument -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
    }
}

Describe 'Registered resource types' {
    It 'includes the built-ins' {
        $types = Get-WinPkgsResourceType
        $types | Should -Contain 'winpkgs/registry'
        $types | Should -Contain 'winpkgs/winget'
        $types | Should -Contain 'winpkgs/file'
    }
}
