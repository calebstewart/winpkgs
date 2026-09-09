# GitHub CLI. home-manager already has `programs.gh`, and most of what it does
# needs nothing from winpkgs: `settings` and `hosts` are written to
# `$XDG_CONFIG_HOME/gh`, which on Windows is `%APPDATA%\gh`. The package is on
# winget as `GitHub.cli` at both scopes -- an MSI for the machine, a portable
# zip for the user -- so the overlay's entry carries no scope and a home
# configuration installs it itself.
#
# Three things are winpkgs' to add: where gh looks, the git credential helper,
# and extensions.
#
# gh reads `GH_CONFIG_DIR`, then `XDG_CONFIG_HOME`, then its native
# `%APPDATA%\GitHub CLI`. A home configuration exports `XDG_CONFIG_HOME`, so
# gh already finds the files by the second rule -- but only while `xdg.enable`
# is on, and the directory home-manager wrote to is knowable either way. So
# `GH_CONFIG_DIR` names it, as home-manager's own starship module names
# `STARSHIP_CONFIG`. (A machine that had gh signed in under the native
# directory does not find its token there any more: `gh auth login` once and it
# lands beside the rest.)
#
# The helper home-manager writes is `${pkgs.gh}/bin/gh auth git-credential`, a
# Nix store path. It has no meaning on Windows, and evaluating the file it
# lands in builds gh for mingw. It becomes `!gh auth git-credential` here: the
# `!` is what makes git run the value as a shell command rather than look for a
# `git-credential-gh` on the PATH, and it is the form gh's own `gh auth
# setup-git` writes. The command is unqualified because winget puts gh on the
# PATH at either scope, and the two installers put it in different places.
#
# Extensions home-manager links out of the Nix store into
# `$XDG_DATA_HOME/gh/extensions`, which is a directory of symlinks into a store
# that does not exist on Windows. There is no counterpart to translate them to,
# so an assertion names them; `gh extension install` is the way there.
{ lib, config, ... }:
let
  cfg = config.programs.gh;

  helper = [
    "" # empty first entry: forget any helper configured further up
    "!gh auth git-credential"
  ];
in
{
  config = lib.mkIf cfg.enable {
    # Translated to Windows on the way out: %APPDATA%\gh, or wherever
    # xdg.configHome was pointed.
    home.sessionVariables.GH_CONFIG_DIR = lib.mkDefault "${config.xdg.configHome}/gh";

    # The override is on the leaf, so a `credential` section the configuration
    # writes for other hosts is untouched. Somebody who wants a different value
    # for these hosts turns `gitCredentialHelper.enable` off and writes their
    # own.
    programs.git.settings.credential = lib.mkIf cfg.gitCredentialHelper.enable (
      lib.mkMerge (map (host: { ${host}.helper = lib.mkForce helper; }) cfg.gitCredentialHelper.hosts)
    );

    assertions = [
      {
        assertion = cfg.extensions == [ ];
        message = ''
          programs.gh.extensions are Nix store paths with no Windows equivalent: ${
            lib.concatMapStringsSep ", " (p: p.pname or p.name or "<unnamed package>") cfg.extensions
          }.
          Install them with `gh extension install <owner>/<repo>` instead.'';
      }
    ];
  };
}
