# What the installer app evaluates: `lib.installer.fromFlake` of the *target*
# flake's own winpkgs input, not of the winpkgs the app came from. The
# configurations were evaluated with that input, so the media is built by the
# same code, and the app is only the front end -- hashing, adding, building,
# copying -- to whatever version the flake pins.
#
# The arguments arrive as a JSON file rather than on the command line: a home
# name has spaces in it, a product key has hyphens, and neither should have to
# survive being quoted into a Nix expression.
#
#   nix eval --impure --json --file installer-driver.nix --argstr argsFile args.json summary
#   nix build "$(jq -r .drvPath summary)^out"
{ argsFile }:
let
  a = builtins.fromJSON (builtins.readFile argsFile);
  flake = builtins.getFlake a.flake;
  winpkgs =
    flake.inputs.${a.winpkgsInput}
      or (throw "winpkgs: the flake ${a.flake} has no input named '${a.winpkgsInput}'. If its winpkgs input is called something else, pass --winpkgs-input <name>.");
  fromFlake =
    winpkgs.lib.installer.fromFlake
      or (throw "winpkgs: the '${a.winpkgsInput}' input of ${a.flake} predates the installer command. Update it: nix flake update ${a.winpkgsInput}");
  r = fromFlake ({ inherit flake; } // a.args);
in
{
  inherit (r) iso unattend payload;
  # What the app needs before it builds: the derivation, and the names it
  # settled on when they were left to it.
  summary = {
    drvPath = r.iso.drvPath;
    system = r.systemName;
    home = r.homeName;
    wsl = r.system.config.wsl.enable or false;
  };
}
