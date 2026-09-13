# The documentation site: the extraction half of the generator, and the build
# that hands what it extracts to the renderer in flakedoc/.
#
# Everything a documentation site needs to know about this flake is already
# inside it. The module system records where each option was declared, the
# overlay's tables say what each package name means on Windows, nixdoc reads
# the library's doc-comments, and the lock file describes every input. This
# file reads all of that out into one JSON document, and the flakedoc binary
# turns the document into a site.
#
# The split is deliberate. Evaluating a flake is slow, needs the flake's inputs
# and can only be done by Nix; rendering HTML is none of those things. Keeping
# a serialized document between the two means the renderer can be worked on
# without re-evaluating anything -- `nix build .#docs.json`, then `flakedoc
# build` by hand.
#
# Both halves read flakedoc.toml: this one for what to extract, the renderer
# for how to present it.
{
  lib,
  # The package set the site is *built* with. Its system is the one the
  # documentation is generated on -- Linux, in CI and in the WSL distro --
  # which is never the system the configurations target.
  pkgs,
  self,
  # windowsSystem and homeConfiguration: each option tree goes through its
  # real evaluator, as a consumer's configuration would.
  winpkgsLib,
}:
let
  cfg = builtins.fromTOML (builtins.readFile ./flakedoc.toml);
  siteCfg = cfg.site or { };
  src = self.outPath;
  repoUrl = lib.removeSuffix "/" (siteCfg.repository or "");
  branch = siteCfg.branch or "main";

  optionsLib = import ./options.nix { inherit lib; };
  outputsLib = import ./outputs.nix { inherit lib; };
  nixdocLib = import ./nixdoc.nix { inherit lib; };
  catalogLib = import ./catalog.nix { inherit lib; };

  # --- options -----------------------------------------------------------

  # Each tree is evaluated against a configuration that does not exist, so
  # that the documented defaults are the modules' own rather than some host's.
  # The stub sets the one option without a default and nothing else: whatever
  # it set would show up in the rendered default of every option that reads
  # it, which is why the options that do read `winpkgs.name` carry a
  # defaultText instead.
  evaluators = {
    system = winpkgsLib.windowsSystem;
    home = winpkgsLib.homeConfiguration;
  };
  stubs = {
    system = {
      winpkgs.name = "example";
    };
    home = {
      winpkgs.name = "example@example";
    };
  };
  evalTree =
    set:
    let
      evaluator =
        evaluators.${set.kind}
          or (throw "docs: unknown option set kind '${set.kind}'; expected one of ${lib.concatStringsSep ", " (lib.attrNames evaluators)}");
    in
    (evaluator {
      inherit (set) system;
      modules = [ stubs.${set.kind} ];
    }).options;

  optionSets = map (
    set:
    optionsLib.mkOptionSet {
      docPkgs = pkgs;
      inherit
        src
        repoUrl
        branch
        set
        ;
      exclude = set.exclude or (siteCfg.excludeOptions or [ ]);
      warningsAreErrors = set.warningsAreErrors or (siteCfg.warningsAreErrors or false);
      options = evalTree set;
    }
  ) (cfg.optionSets or [ ]);

  # --- assembly ----------------------------------------------------------

  base = {
    # The document format. Bump this when the renderer would misread an older
    # document, not when a field is added -- flakedoc ignores fields it does
    # not know.
    schemaVersion = 1;

    meta = {
      name = siteCfg.name or (siteCfg.title or "flake");
      title = siteCfg.title or (siteCfg.name or "flake");
      description = siteCfg.description or null;
      inherit repoUrl branch;
      rev = self.rev or self.dirtyRev or null;
      lastModified = self.lastModifiedDate or null;
    };

    inherit optionSets;
    catalog = catalogLib.mkCatalog { inherit pkgs src; };
    outputs = outputsLib.mkOutputs { inherit self; };
    inputs = outputsLib.mkInputs { lockFile = "${src}/flake.lock"; };
  };

  baseFile = pkgs.writeText "flakedoc-base.json" (builtins.toJSON base);

  libFile = nixdocLib.mkLibDocs {
    inherit
      pkgs
      src
      repoUrl
      branch
      ;
    namespaces = cfg.libNamespaces or [ ];
  };

  json =
    pkgs.runCommand "flakedoc-docs.json"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq --slurpfile libNamespaces ${libFile} \
          '. + { libNamespaces: $libNamespaces[0] }' \
          ${baseFile} > $out
      '';

  # --- the site ----------------------------------------------------------

  flakedoc = pkgs.callPackage ./flakedoc { };

  site =
    pkgs.runCommand "winpkgs-docs"
      {
        nativeBuildInputs = [ flakedoc ];
        # `nix build .#docs.json` for the document on its own.
        passthru = {
          inherit json flakedoc;
        };
        meta.description = "The winpkgs documentation site, generated from the flake";
      }
      ''
        flakedoc build \
          --input ${json} \
          --config ${./flakedoc.toml} \
          --content ${./content} \
          --out $out
      '';

  # `nix run .#docs` builds the site and serves it. A documentation site is not
  # much use as a store path: every link in it is relative, so opening
  # result/index.html from the filesystem works but says nothing about whether
  # it will work once served, and search fetches its index.
  serve = pkgs.writeShellApplication {
    name = "winpkgs-docs";
    runtimeInputs = [ pkgs.miniserve ];
    text = ''
      port="''${1:-8080}"
      echo "winpkgs documentation on http://localhost:$port/"
      exec miniserve --index index.html --port "$port" ${site}
    '';
  };
in
{
  docs = site;
  inherit flakedoc serve;
}
