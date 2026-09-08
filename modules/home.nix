# home-manager's names for the things that mean the same on Windows: files in
# the home directory and user environment variables. A module that touches only
# this surface can be imported by home-manager and by winpkgs alike, guarded the
# way NixOS and nix-darwin modules are (`pkgs.stdenv.hostPlatform.isWindows`).
#
# Not aligned, because the concept differs: `home.packages` (winget ids are not
# nixpkgs attributes), `home.activation`, `programs.*`.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.home;
  homeFile = import ./home-file.nix { inherit lib; };
in
{
  options.home = {
    homeDirectory = mkOption {
      type = types.str;
      default = "%USERPROFILE%";
      description = ''
        The user's home directory, as an environment reference expanded on the
        machine at apply time, so one configuration fits any user. Everything
        in `home.file` is rooted here.
      '';
    };

    username = mkOption {
      type = types.str;
      default = "%USERNAME%";
      description = "The user name, as an environment reference expanded at apply time.";
    };

    file = mkOption {
      type = types.attrsOf homeFile;
      default = { };
      example = lib.literalExpression ''
        {
          ".gitconfig".text = lib.generators.toGitINI { user = { name = "Caleb"; email = "..."; }; };
          ".wezterm.lua".source = ./wezterm.lua;
          ".config/nvim" = { source = ./nvim; recursive = true; };
        }
      '';
      description = ''
        Files in the home directory, keyed by path relative to
        `home.homeDirectory`, with home-manager's option names. Sugar over
        `winpkgs.files`.
      '';
    };

    sessionVariables = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.str
          types.int
          types.path
        ]
      );
      default = { };
      example = {
        EDITOR = "nvim";
      };
      description = ''
        User environment variables (`HKCU\Environment`), with home-manager's
        name. Sugar over `winpkgs.environment.variables`; `%VAR%` references are
        stored expandable.
      '';
    };
  };

  config = {
    winpkgs.files = lib.mapAttrs' (
      _: f:
      lib.nameValuePair "${cfg.homeDirectory}/${f.target}" {
        inherit (f)
          enable
          text
          source
          recursive
          ;
        scope = "user";
      }
    ) cfg.file;

    winpkgs.environment.variables = lib.mapAttrs (_: toString) cfg.sessionVariables;

    assertions = lib.mapAttrsToList (n: f: {
      assertion = f.onChange == null;
      message = "home.file.\"${n}\".onChange is not supported by winpkgs (no command-running resource yet)";
    }) cfg.file;
  };
}
