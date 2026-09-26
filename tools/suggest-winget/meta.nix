# What nixpkgs says about each attribute the tool was asked about, as JSON:
# the names and URLs a winget manifest can be matched against, and what the
# winpkgs table already maps it to. Read with `nix-instantiate --eval
# --strict --json`; every field that could throw is caught, so one broken or
# aliased attribute does not take the others with it.
{
  nixpkgs,
  src,
  attrs,
  system ? builtins.currentSystem,
}:
let
  lib = import (nixpkgs + "/lib");
  # Evaluated for the build platform, not Windows: meta is the same either
  # way, and nothing here is built.
  pkgs = import nixpkgs {
    inherit system;
    config = {
      allowUnfree = true;
      allowBroken = true;
      allowUnsupportedSystem = true;
      allowInsecurePredicate = _: true;
    };
    overlays = [ ];
  };
  mappings = import (src + "/overlays/winget.nix");

  # Deep for the strings and lists read out of a package; shallow for the
  # package itself, which deepSeq would walk into all of nixpkgs.
  tryShallow =
    default: v:
    let
      r = builtins.tryEval v;
    in
    if r.success then r.value else default;
  try = default: v: tryShallow default (builtins.deepSeq v v);
  str = v: try null (if builtins.isString v then v else null);
  strs =
    v:
    try [ ] (
      if builtins.isList v then
        lib.filter builtins.isString v
      else if builtins.isString v then
        [ v ]
      else
        [ ]
    );

  # What the table says, three ways: nothing, "no Windows build", an id.
  mappingOf =
    name:
    if !(mappings ? ${name}) then
      null
    else
      let
        e = mappings.${name};
      in
      if e == null then
        { id = null; }
      else if builtins.isString e then
        { id = e; }
      else
        { inherit (e) id; };

  info =
    name:
    let
      p = tryShallow null (lib.attrByPath (lib.splitString "." name) null pkgs);
      isPackage = try false (p != null && lib.isDerivation p);
    in
    {
      inherit name;
      mapping = mappingOf name;
      found = isPackage;
    }
    // lib.optionalAttrs isPackage {
      pname = str (p.pname or null);
      version = str (p.version or null);
      mainProgram = str (p.meta.mainProgram or null);
      description = str (p.meta.description or null);
      homepages = strs (p.meta.homepage or [ ]);
      # Where the source comes from names the project too: a fetchFromGitHub
      # archive URL carries the owner and repository.
      urls =
        strs (p.meta.downloadPage or [ ])
        ++ strs (p.meta.changelog or [ ])
        ++ strs (p.src.urls or [ ])
        ++ strs (p.src.url or [ ]);
    };
in
map info attrs
