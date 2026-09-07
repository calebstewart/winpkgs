function Get-WinPkgsResourceType {
    <#
    .SYNOPSIS
        Names of the registered resource types.
    #>
    $script:Resources.Keys | Sort-Object
}

function Invoke-WinPkgsResource {
    <#
    .SYNOPSIS
        Dispatch one operation of the resource contract to a registered type.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][ValidateSet('Get', 'Test', 'Set', 'Restore', 'Backup', 'Describe')][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Properties,
        [hashtable]$Current,
        [hashtable]$Before,
        [string]$BackupDir,
        [hashtable]$Context = @{}
    )

    $impl = $script:Resources[$Type]
    if (-not $impl) { throw "Unknown resource type '$Type'" }

    switch ($Operation) {
        'Get'      { return (& $impl.Get $Properties $Context) }
        'Test'     { return [bool](& $impl.Test $Properties $Current $Context) }
        'Set'      { & $impl.Set $Properties $Current $Context; return }
        'Restore'  { & $impl.Restore $Properties $Before $Context; return }
        'Backup'   {
            if ($impl.Backup) { return (& $impl.Backup $Properties $Current $Context $BackupDir) }
            return @{}
        }
        'Describe' {
            if ($impl.Describe) { return [string](& $impl.Describe $Properties $Current) }
            return ''
        }
    }
}
