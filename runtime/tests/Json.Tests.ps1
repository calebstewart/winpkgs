BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force
}

Describe 'ConvertFrom-WinPkgsJson (both hosts)' {
    It 'produces nested hashtables with case-insensitive keys' {
        $h = '{"a":{"b":{"c":1}},"Name":"x"}' | ConvertFrom-WinPkgsJson
        $h | Should -BeOfType [hashtable]
        $h['a']['b']['c'] | Should -Be 1
        $h['name'] | Should -Be 'x'
        $h.ContainsKey('A') | Should -BeTrue
    }

    It 'keeps arrays as arrays, including single-element and empty ones' {
        $h = '{"one":[{"id":"x"}],"none":[],"many":[1,2,3]}' | ConvertFrom-WinPkgsJson
        @($h['one']).Count | Should -Be 1
        $h['one'][0]['id'] | Should -Be 'x'
        @($h['none']).Count | Should -Be 0
        @($h['many']).Count | Should -Be 3
    }

    It 'preserves null, booleans and numbers' {
        $h = '{"n":null,"t":true,"f":false,"i":4294967295,"s":"str"}' | ConvertFrom-WinPkgsJson
        $h['n'] | Should -BeNullOrEmpty
        $h.ContainsKey('n') | Should -BeTrue
        $h['t'] | Should -BeTrue
        $h['f'] | Should -BeFalse
        [int64]$h['i'] | Should -Be 4294967295
        $h['s'] | Should -Be 'str'
    }

    It 'round-trips a document shape through ConvertTo-Json' {
        $doc = @{ version = 1; resources = @(@{ type = 't'; properties = @{ value = @('a', 'b') } }) }
        $h = ($doc | ConvertTo-Json -Depth 10) | ConvertFrom-WinPkgsJson
        @($h['resources']).Count | Should -Be 1
        @($h['resources'][0]['properties']['value']) | Should -Be @('a', 'b')
    }
}
