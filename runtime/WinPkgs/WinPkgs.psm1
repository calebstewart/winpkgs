$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:RuntimeRoot = Split-Path -Parent $PSScriptRoot
$script:Resources = @{}

# Order matters: Private defines Register-WinPkgsResource, Resources call it.
foreach ($dir in 'Private', 'Resources', 'Public') {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' |
        Sort-Object Name |
        ForEach-Object { . $_.FullName }
}

Export-ModuleMember -Function (
    (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WinPkgs.psd1')).FunctionsToExport
)
