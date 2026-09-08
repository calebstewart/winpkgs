<#
    JSON -> hashtables on both hosts. pwsh has ConvertFrom-Json -AsHashtable;
    Windows PowerShell 5.1 (which runs the elevated phase when pwsh is the
    MSIX build) does not, so convert its PSCustomObjects ourselves.
#>
function ConvertTo-WinPkgsHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[$k] = ConvertTo-WinPkgsHashtable $Value[$k] }
        return $h
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-WinPkgsHashtable $p.Value }
        return $h
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { , (ConvertTo-WinPkgsHashtable $item) })
        # Leading comma: hand back the array itself, not its elements one by one.
        return , $items
    }
    return $Value
}

function ConvertFrom-WinPkgsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Json)
    process {
        # pwsh's -AsHashtable gives case-sensitive keys; 5.1 has no -AsHashtable
        # at all. Normalise both through the same converter so a document reads
        # identically on either host.
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            return (ConvertTo-WinPkgsHashtable ($Json | ConvertFrom-Json -AsHashtable))
        }
        return (ConvertTo-WinPkgsHashtable ($Json | ConvertFrom-Json))
    }
}
