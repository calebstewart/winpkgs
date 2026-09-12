# Commands run at the end of an apply when what they depend on changed:
# home-manager's `home.activation` and NixOS's activation scripts, kept to
# the one thing no resource can say -- tell a running program about a change.
# A home module that writes a service manager's unit files runs its `switch`
# here. How a *service* is replaced when it changes is not this; that is the
# service's own `restartControl`.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  scope = sugar.scopeOfKind winpkgsKind;
in
{
  options.winpkgs.activation = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          command = mkOption {
            type = types.lines;
            example = "stewctl switch --if-running";
            description = ''
              PowerShell, run in a child process of the host applying the
              configuration -- elevated for a system configuration, as the user
              for a home one -- with the PATH a session starting now would
              have. It fails the apply if it throws or its last program exits
              non-zero, and then runs again at the next apply.
            '';
          };
          triggers = mkOption {
            type = types.listOf types.unspecified;
            default = [ ];
            example = lib.literalExpression ''[ config.home.file."app/config.toml".text ]'';
            description = ''
              What the command reacts to, as NixOS's `restartTriggers`: it runs
              when these (or the command) differ from the last apply that ran
              it, and not otherwise. With none, it runs once.
            '';
          };
        };
      }
    );
    default = { };
    description = ''
      Commands run at the end of an apply -- after every other resource and
      after pruning -- when their triggers changed.
    '';
  };

  config.winpkgs.resources = lib.mapAttrsToList (name: a: {
    type = "winpkgs/activation";
    id = "Activation ${name}";
    inherit scope;
    properties = {
      inherit name;
      inherit (a) command;
      revision = builtins.hashString "sha256" (
        builtins.toJSON [
          a.command
          a.triggers
        ]
      );
    };
  }) config.winpkgs.activation;
}
