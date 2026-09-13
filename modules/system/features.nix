# Windows optional features: Hyper-V, Windows Sandbox, the WSL and Virtual
# Machine Platform features -- what `Enable-WindowsOptionalFeature -Online`
# turns on. Machine scope: a feature is the machine's, and both reading it in
# full and changing it take elevation.
#
# Only whether a feature is enabled. `true` enables it, with the parents it
# depends on; `false` disables it, because writing that is an explicit ask.
# A feature winpkgs enabled is disabled again when it leaves the configuration
# (`winpkgs.prune.features`); one that was already enabled is only managed.
# Many features take a restart to finish enabling: the apply says so and
# leaves with exit code 3010, and nothing restarts the machine.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.features;
in
{
  options.windows.features = mkOption {
    type = types.attrsOf types.bool;
    default = { };
    example = lib.literalExpression ''
      {
        Microsoft-Hyper-V-All = true;
        Containers-DisposableClientVM = true;   # Windows Sandbox
      }
    '';
    description = ''
      Windows optional features by name -- the `FeatureName` that
      `Get-WindowsOptionalFeature -Online` lists -- and whether each is
      enabled. `true` enables the feature together with the ones it depends
      on; `false` disables it. A feature winpkgs enabled is disabled again
      when it leaves the configuration; one that was already enabled when it
      was first declared is left as it is. Features that need a restart to
      take effect are reported at the end of the apply; the machine is never
      restarted. A name this Windows does not have counts as disabled, and
      enabling it is an error.
    '';
  };

  config.winpkgs.resources = lib.mapAttrsToList (name: enabled: {
    type = "winpkgs/optionalFeature";
    id = "Feature ${name}";
    scope = "machine";
    properties = {
      inherit name enabled;
    };
  }) cfg;
}
