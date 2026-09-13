<#
    The resource contract. Each resource type registers function *names*; the
    runtime calls them positionally:

      Get      (Properties, Context)                -> @{ exists = bool; ... }
      Test     (Properties, Current, Context)       -> bool
      Set      (Properties, Current, Context)
      Remove   (Properties, Context)                                                                 (optional)
      Backup   (Properties, Current, Context, Dir)  -> @{ ... } merged into the journal's `before`   (optional)
      Describe (Properties, Current)                -> string for plan output                        (optional)

    Remove deletes what winpkgs put there, and forgets it in the ledger. Only
    prune calls it, so only the types it prunes register one.
#>
function Register-WinPkgsResource {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Get,
        [Parameter(Mandatory)][string]$Test,
        [Parameter(Mandatory)][string]$Set,
        [string]$Remove,
        [string]$Backup,
        [string]$Describe
    )
    $script:Resources[$Type] = @{
        Get = $Get; Test = $Test; Set = $Set; Remove = $Remove; Backup = $Backup; Describe = $Describe
    }
}
