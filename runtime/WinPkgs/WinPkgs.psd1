@{
    RootModule        = 'WinPkgs.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3f1b6c2e-8d4a-4c0f-9a5e-2b7d1e6f0c41'
    Author            = 'Caleb Stewart'
    Description       = 'winpkgs runtime: converges a Windows machine to a desired-state document produced by Nix.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Read-WinPkgsDocument'
        'Test-WinPkgsDocument'
        'ConvertFrom-WinPkgsJson'
        'Get-WinPkgsPlan'
        'Format-WinPkgsPlan'
        'Invoke-WinPkgsApply'
        'Invoke-WinPkgsRollback'
        'Invoke-WinPkgsGarbageCollect'
        'Get-WinPkgsGeneration'
        'Invoke-WinPkgsResource'
        'Get-WinPkgsResourceType'
        'Get-WinPkgsStateDir'
        'Read-WinPkgsState'
        'Test-WinPkgsElevated'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
