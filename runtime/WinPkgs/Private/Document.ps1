function Read-WinPkgsDocument {
    <#
    .SYNOPSIS
        Load and validate a desired-state document. Adds `root` (directory
        holding it, against which file sources resolve) and `path`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration not found: $Path"
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $doc = Get-Content -LiteralPath $full -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    Test-WinPkgsDocument -Document $doc
    $doc['root'] = Split-Path -Parent $full
    $doc['path'] = $full
    return $doc
}

function Get-WinPkgsKindScope {
    param([Parameter(Mandatory)][string]$Kind)
    if ($Kind -eq 'system') { return 'machine' }
    return 'user'
}

function Test-WinPkgsDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Document)

    if ($Document['version'] -ne 2) {
        throw "Unsupported document version '$($Document['version'])' (this runtime understands version 2; rebuild the configuration with a matching winpkgs)"
    }
    if ($Document['kind'] -notin @('system', 'home')) {
        throw "Document has no valid 'kind' (system or home): '$($Document['kind'])'"
    }
    if (-not $Document.ContainsKey('resources')) {
        throw "Document has no 'resources' list"
    }

    $scope = Get-WinPkgsKindScope -Kind $Document['kind']
    $seen = @{}
    foreach ($r in @($Document['resources'])) {
        foreach ($k in 'type', 'id', 'scope', 'properties') {
            if (-not $r.ContainsKey($k)) {
                throw "Resource is missing '$k': $(ConvertTo-Json $r -Compress -Depth 5)"
            }
        }
        if ($r['scope'] -ne $scope) {
            throw "Resource '$($r['id'])' is $($r['scope']) scope, but this is a $($Document['kind']) configuration ($scope scope)"
        }
        if (-not $script:Resources.ContainsKey($r['type'])) {
            throw "Resource '$($r['id'])' has unknown type '$($r['type'])'. Known: $($script:Resources.Keys -join ', ')"
        }
        if ($seen.ContainsKey($r['id'])) {
            throw "Duplicate resource id '$($r['id'])'"
        }
        $seen[$r['id']] = $true
    }
}
