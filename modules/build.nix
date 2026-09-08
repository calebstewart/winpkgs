{
  lib,
  config,
  pkgs,
  winpkgsSrc,
  ...
}:
let
  cfg = config.winpkgs;

  # `pkgs` targets Windows; everything here runs on the machine doing the
  # evaluating, so it comes from the build platform's package set.
  bp = pkgs.buildPackages;

  failedAssertions = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  document = {
    version = 1;
    name = cfg.name;
    settings = {
      prune = {
        inherit (cfg.prune) winget files;
      };
      generations = {
        inherit (cfg.generations) keep deleteOlderThan;
      };
    };
    resources = cfg.resources;
  };

  ids = map (r: r.id) cfg.resources;
  duplicateIds = lib.filter (id: lib.count (x: x == id) ids > 1) (lib.unique ids);

  checked =
    if failedAssertions != [ ] then
      throw "\nFailed assertions:\n${lib.concatMapStrings (m: "- ${m}\n") failedAssertions}"
    else if duplicateIds != [ ] then
      throw "\nDuplicate resource ids:\n${lib.concatMapStrings (m: "- ${m}\n") duplicateIds}"
    else
      document;

  rawJson = bp.writeText "winpkgs-${cfg.name}.raw.json" (builtins.toJSON checked);

  # Linking the distro's toplevel into the closure is what makes one `nix build`
  # build both halves.
  wslToplevel = if cfg.wsl.enable then config.system.build.wsl.config.system.build.toplevel else null;
in
{
  system.build.document = checked;

  system.build.configJson = bp.runCommand "winpkgs-${cfg.name}.json" { } ''
    ${bp.jq}/bin/jq . ${rawJson} > $out
  '';

  # The self-contained closure: document + file contents + the runtime that
  # understands them. `nix run` executes bin/activate via meta.mainProgram.
  system.build.toplevel =
    bp.runCommand "winpkgs-${cfg.name}"
      {
        meta.mainProgram = "activate";
        passthru = {
          inherit (config.system.build) configJson document;
        };
      }
      ''
        mkdir -p $out/bin $out/files
        cp ${config.system.build.configJson} $out/config.json
        cp -r ${winpkgsSrc}/runtime $out/runtime
        chmod -R u+w $out/runtime
        ${lib.concatMapStrings (e: ''
          cp -r ${e.src} $out/files/${e.closureName}
        '') config.system.build.fileEntries}
        ${lib.optionalString (wslToplevel != null) "ln -s ${wslToplevel} $out/wsl"}
        substitute ${winpkgsSrc}/runtime/activate.sh $out/bin/activate --subst-var out
        chmod +x $out/bin/activate
      '';
}
