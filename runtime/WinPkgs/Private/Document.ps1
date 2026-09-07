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
    $doc = Get-Content -LiteralPath $full -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Test-WinPkgsDocument -Document $doc
    $doc['root'] = Split-Path -Parent $full
    $doc['path'] = $full
    return $doc
}

function Test-WinPkgsDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Document)

    if ($Document['version'] -ne 1) {
        throw "Unsupported document version '$($Document['version'])' (this runtime understands version 1)"
    }
    if (-not $Document.ContainsKey('resources')) {
        throw "Document has no 'resources' list"
    }

    $seen = @{}
    foreach ($r in @($Document['resources'])) {
        foreach ($k in 'type', 'id', 'scope', 'properties') {
            if (-not $r.ContainsKey($k)) {
                throw "Resource is missing '$k': $(ConvertTo-Json $r -Compress -Depth 5)"
            }
        }
        if ($r['scope'] -notin @('user', 'machine')) {
            throw "Resource '$($r['id'])' has invalid scope '$($r['scope'])'"
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
