# `onChangePowerShell` beside home-manager's `onChange`, on `home.file` and
# the four `xdg.*File` options that feed it. `onChange` is a POSIX shell
# script and has no meaning on Windows; this is the same hook in PowerShell,
# which home-manager.nix runs through `winpkgs.activation` when the file
# changes.
#
# Options only, and nothing Windows-specific: the flake exports this file as
# `homeModules.default` too, so a module shared with a Linux or macOS home
# that sets `onChangePowerShell` evaluates there, where it does nothing.
#
# Each declaration is merged into home-manager's own: an `attrsOf submodule`
# declared twice is one option whose submodule has both sets of options. The
# xdg ones matter because home-manager hands each of their entries to
# `home.file` whole, so a value set on `xdg.configFile` arrives there.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  withHook = mkOption {
    type = types.attrsOf (
      types.submodule {
        options.onChangePowerShell = mkOption {
          type = types.lines;
          default = "";
          example = "komorebic reload-configuration";
          description = ''
            PowerShell run on Windows when the file has changed: `onChange`,
            for a platform without a POSIX shell. It runs at the end of the
            apply that wrote the file, as the user, and at the first apply that
            writes it. Ignored everywhere but Windows, so a module shared with
            a Linux or macOS home can set both.
          '';
        };
      }
    );
  };
in
{
  options.home.file = withHook;
  options.xdg = {
    configFile = withHook;
    dataFile = withHook;
    stateFile = withHook;
    cacheFile = withHook;
  };
}
