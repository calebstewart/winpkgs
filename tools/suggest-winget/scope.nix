# For each candidate id: its newest version in the pinned winget-pkgs and
# whether an installer is picked at each scope, by lib/winget.nix itself -- the
# reader and the selection the `packages` flake check holds the table to, so
# a suggested entry passes it. JSON, through `nix-instantiate --eval --strict
# --json`.
{
  nixpkgs,
  src,
  wingetPkgs,
  ids,
}:
let
  lib = import (nixpkgs + "/lib");
  w = import (src + "/lib/winget.nix") { inherit lib; };

  picks =
    manifest: scope:
    let
      r = builtins.tryEval (w.selectInstaller { inherit manifest scope; } != null);
    in
    r.success && r.value;

  check =
    id:
    let
      version = w.latestVersion wingetPkgs id;
      read = w.readInstallerManifest wingetPkgs id version;
    in
    if version == null then
      {
        inherit id version;
        error = "not in the pinned winget-pkgs";
      }
    else if read.error != null then
      {
        inherit id version;
        inherit (read) error;
      }
    else
      {
        inherit id version;
        error = null;
        machine = picks read.value "machine";
        user = picks read.value "user";
      };
in
map check ids
