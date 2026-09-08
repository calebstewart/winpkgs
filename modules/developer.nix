# The two machine-wide switches a development machine wants and a fresh install
# does not have. Both are machine scope, so both need elevation, and both take
# effect for processes started afterwards rather than immediately.
{ lib, config, ... }:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.winpkgs.developer;

  appModelUnlock = ''HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'';
  fileSystem = ''HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'';

  settings = {
    developerMode = {
      keys = [ appModelUnlock ];
      type = types.bool;
      # Two values: the Settings toggle writes both, and the sideloading one on
      # its own is what older documentation means by "developer mode".
      writes =
        v:
        let
          n = sugar.on v;
        in
        {
          ${appModelUnlock} = {
            AllowDevelopmentWithoutDevLicense = n;
            AllowAllTrustedApps = n;
          };
        };
      description = ''
        Developer Mode: sideload unsigned packages, and create symbolic links
        without elevation.
      '';
    };

    longPaths = {
      key = fileSystem;
      name = "LongPathsEnabled";
      type = types.bool;
      encode = sugar.on;
      description = ''
        Let applications that opt in use paths beyond 260 characters. Only
        applications with the matching manifest entry are affected, which
        includes PowerShell 7 but not every tool on the machine.
      '';
    };
  };
in
{
  options.winpkgs.developer = sugar.options settings;

  config.winpkgs.registry = sugar.writes settings cfg;
}
