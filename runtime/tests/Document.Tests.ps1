BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    function New-Doc([hashtable]$Doc, [string]$Name = 'config.json') {
        $path = Join-Path $TestDrive $Name
        $Doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    function Reg([string]$Id, [string]$Key = 'HKCU\Software\x', [string]$Scope = 'user') {
        @{ type = 'winpkgs/registry'; id = $Id; scope = $Scope
           properties = @{ key = $Key; name = 'v'; type = 'DWord'; value = 1; restartExplorer = $false } }
    }
    function Doc([object[]]$Resources, [string]$Kind = 'home') {
        @{ version = 2; kind = $Kind; name = 't'; resources = @($Resources) }
    }
}

Describe 'Read-WinPkgsDocument' {
    It 'loads a valid document and records root and path' {
        $p = New-Doc (Doc @(Reg 'a'))
        $doc = Read-WinPkgsDocument -Path $p
        $doc['name'] | Should -Be 't'
        $doc['kind'] | Should -Be 'home'
        $doc['root'] | Should -Be (Split-Path -Parent $p)
        $doc['path'] | Should -Be $p
        @($doc['resources']).Count | Should -Be 1
    }

    It 'accepts an empty resource list' {
        { Read-WinPkgsDocument -Path (New-Doc (Doc @())) } | Should -Not -Throw
    }

    It 'accepts a system document with machine-scope resources' {
        $d = Doc @((Reg 'a' 'HKLM\SOFTWARE\x' 'machine')) 'system'
        (Read-WinPkgsDocument -Path (New-Doc $d))['kind'] | Should -Be 'system'
    }

    It 'rejects an unsupported version' {
        $d = Doc @(); $d.version = 1
        { Read-WinPkgsDocument -Path (New-Doc $d) } | Should -Throw '*version*'
    }

    It 'rejects a missing or invalid kind' {
        $d = Doc @(); $d.kind = 'galaxy'
        { Read-WinPkgsDocument -Path (New-Doc $d) } | Should -Throw '*kind*'
        $d.Remove('kind')
        { Read-WinPkgsDocument -Path (New-Doc $d) } | Should -Throw '*kind*'
    }

    It 'rejects a resource whose scope does not match the kind' {
        $d = Doc @((Reg 'a' 'HKLM\SOFTWARE\x' 'machine')) 'home'
        { Read-WinPkgsDocument -Path (New-Doc $d) } | Should -Throw '*is machine scope*home configuration*'
    }

    It 'rejects an unknown resource type' {
        $r = Reg 'a'; $r.type = 'winpkgs/nope'
        { Read-WinPkgsDocument -Path (New-Doc (Doc @($r))) } | Should -Throw '*unknown type*'
    }

    It 'rejects duplicate ids' {
        { Read-WinPkgsDocument -Path (New-Doc (Doc @((Reg 'a'), (Reg 'a')))) } | Should -Throw '*Duplicate*'
    }

    It 'rejects a missing file' {
        { Read-WinPkgsDocument -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
    }
}

Describe 'Registered resource types' {
    It 'includes the built-ins' {
        $types = Get-WinPkgsResourceType
        foreach ($t in 'winpkgs/registry', 'winpkgs/registryKey', 'winpkgs/winget', 'winpkgs/file', 'winpkgs/path', 'winpkgs/environment', 'winpkgs/font', 'winpkgs/wallpaper', 'winpkgs/powerPlan', 'winpkgs/powerSetting', 'winpkgs/hibernation', 'winpkgs/computerName') {
            $types | Should -Contain $t
        }
    }
}
