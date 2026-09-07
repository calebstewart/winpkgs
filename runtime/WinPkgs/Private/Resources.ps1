<#
    The resource contract. Each resource type registers function *names*; the
    runtime calls them positionally:

      Get      (Properties, Context)                -> @{ exists = bool; ... }
      Test     (Properties, Current, Context)       -> bool
      Set      (Properties, Current, Context)
      Restore  (Properties, Before, Context)
      Backup   (Properties, Current, Context, Dir)  -> @{ ... } merged into the journal's `before`   (optional)
      Describe (Properties, Current)                -> string for plan output                        (optional)
#>
function Register-WinPkgsResource {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Get,
        [Parameter(Mandatory)][string]$Test,
        [Parameter(Mandatory)][string]$Set,
        [Parameter(Mandatory)][string]$Restore,
        [string]$Backup,
        [string]$Describe
    )
    $script:Resources[$Type] = @{
        Get = $Get; Test = $Test; Set = $Set; Restore = $Restore; Backup = $Backup; Describe = $Describe
    }
}
