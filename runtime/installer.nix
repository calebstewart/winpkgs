# How `winpkgs installer` finds the installer app: in the *target* flake's own
# winpkgs input, so the media is built by the code that evaluated the
# configurations rather than by whichever winpkgs happens to be around. `nix
# run flake#...` can only name a flake's outputs, never its inputs, so the CLI
# reaches the input by evaluation instead:
#
#   nix run --impure --file installer.nix --argstr flake /mnt/c/src/config installer -- <options>
#
# Named, because `nix run --file` still wants one installable before the `--`,
# and without one it would read the app's first option as an attribute path.
{
  flake,
  input ? "winpkgs",
}:
let
  target = builtins.getFlake flake;
  winpkgs =
    target.inputs.${input} or (throw "winpkgs: the flake at ${flake} has no input named '${input}'");
in
{
  installer =
    winpkgs.packages.${builtins.currentSystem}.installer
      or (throw "winpkgs: the '${input}' input of ${flake} predates `winpkgs installer`. Update it: winpkgs flake update ${input}");
}
