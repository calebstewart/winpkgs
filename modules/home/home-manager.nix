# home-manager, for real. lib/default.nix evaluates home-manager's own module
# tree in a home configuration -- every `programs.*` and `services.*`,
# `home.file`, `xdg.*`, `home.sessionVariables` -- against winpkgs' Windows
# `pkgs`, so a module written for home-manager evaluates here unchanged and its
# platform guards (`pkgs.stdenv.hostPlatform.isLinux`, `isDarwin`) come out
# false. home-manager knows nothing about Windows: what it produces is a set of
# files relative to a home directory, a set of environment variables, a PATH
# prefix and a package list. This module carries exactly those four across:
#
#   home.file (fed by xdg.configFile & co.)  -> windows.files under %USERPROFILE%
#   home.sessionVariables                     -> HKCU\Environment
#   home.sessionPath                          -> the user PATH
#   home.packages                             -> winget, through the overlay's annotations
#
# Everything else home-manager does -- the activation script, the Nix profile,
# systemd and launchd services, news, the manual -- is left unevaluated. It has
# no meaning on Windows or a winpkgs counterpart (`winpkgs.cli` is
# `programs.home-manager`).
#
# The home directory is a fiction. home-manager needs an absolute POSIX path to
# normalise targets against (its option type insists on a leading slash), so it
# is `/home/<user>`. On the way out, any target, variable or PATH entry that
# starts with it (or with `$HOME`) becomes `%USERPROFILE%`, and the runtime
# replaces it inside file contents with the real profile directory when the
# file is written -- the one place the real path can be known.
{
  lib,
  config,
  options,
  ...
}:
let
  inherit (lib) mkDefault;
  cfg = config.home;
  sugar = import ../common/sugar.nix { inherit lib; };

  # "<user>@<host>" -> "<user>"; a name without an @ is the user.
  userOf =
    name:
    let
      parts = lib.splitString "@" name;
    in
    if lib.length parts > 1 then lib.concatStringsSep "@" (lib.init parts) else name;

  homeDir = cfg.homeDirectory;
  # "/home/me/.config/x" -> "%USERPROFILE%\.config\x", "$HOME/bin" likewise;
  # anything else unchanged.
  toWindows =
    v:
    let
      s = toString v;
      under =
        prefix:
        if s == prefix then
          ""
        else if lib.hasPrefix (prefix + "/") s then
          lib.removePrefix prefix s
        else
          null;
      rel =
        let
          a = under homeDir;
        in
        if a != null then a else under "$HOME";
    in
    if rel == null then s else "%USERPROFILE%" + lib.replaceStrings [ "/" ] [ "\\" ] rel;

  # home-manager keeps these two directories in existence for the Nix profile's
  # sake; on Windows they would be clutter.
  placeholders = [
    ".cache/.keep"
    ".local/state/.keep"
  ];
  files = lib.filter (f: f.enable && !(lib.elem f.target placeholders)) (lib.attrValues cfg.file);
  # home-manager has normalised every target: relative to the home directory
  # when inside it, absolute when not.
  outsideHome = lib.filter (f: lib.hasPrefix "/" f.target) files;
  inHome = lib.filter (f: !lib.hasPrefix "/" f.target) files;
  withOnChange = lib.filter (f: f.onChange != "") files;
  names = fs: lib.concatMapStringsSep ", " (f: f.target) fs;

  # home-manager adds a package of its own to home.packages -- the file that
  # exports the session variables into a POSIX shell. Recognised by name: a
  # derivation comparison would force its store path, and with it the store
  # paths of every other package in the list, which for a Windows cross set
  # means evaluating builds nixpkgs marks broken.
  internalNames = [ cfg.sessionVariablesPackage.name ];
  isInternal = p: lib.elem (p.name or "") internalNames;
  translated = sugar.packagesToWinget (lib.filter (p: !isInternal p) cfg.packages);

  # A package whose winget installer is machine-wide (the overlay says so:
  # `winget.scope == "machine"`) cannot be installed by a home configuration,
  # which never elevates. It is declared here and installed by the system
  # configuration that lists this home in `winpkgs.homes` -- what
  # home-manager.useUserPackages does on NixOS.
  ownPackages = lib.filter (p: sugar.wingetScope p != "machine") translated.mapped;
  machinePackages = lib.filter (p: sugar.wingetScope p == "machine") translated.mapped;

  # PATH is carried; MANPATH & co. have no Windows meaning.
  otherSearchVariables = lib.attrNames (removeAttrs cfg.sessionSearchVariables [ "PATH" ]);
in
{
  options.winpkgs.machinePackages = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    description = ''
      Packages this home declared in `home.packages` whose winget installer is
      machine-wide, as `winget.packages` entries. A home configuration
      never elevates, so it does not install them; the system configuration
      that lists this home in `winpkgs.homes` does, elevated, before the home
      is applied.
    '';
  };

  config = {
    winpkgs.machinePackages = map (p: { id = p.winget.id; }) machinePackages;

    home.username = mkDefault (userOf config.winpkgs.name);
    home.homeDirectory = mkDefault "/home/${cfg.username}";
    # Nothing that reaches Windows depends on it, so: the newest one.
    home.stateVersion = mkDefault (lib.last options.home.stateVersion.type.functor.payload.values);
    # home-manager turns these on by default; both are Nix packages in
    # home.packages (the manual, man-db) with nowhere to go on Windows.
    manual = {
      manpages.enable = mkDefault false;
      html.enable = mkDefault false;
      json.enable = mkDefault false;
    };
    programs.man.enable = mkDefault false;

    windows.files = lib.listToAttrs (
      map (
        f:
        lib.nameValuePair "%USERPROFILE%/${f.target}" {
          inherit (f) source recursive;
        }
      ) inHome
    );
    # File *contents* are translated on the machine, where the real profile
    # directory is known: a module that writes ${config.home.homeDirectory}/
    # .ssh/id_ed25519 into its config gets C:/Users/<user>/.ssh/id_ed25519.
    winpkgs.substitutions = [
      {
        from = homeDir;
        to = "%USERPROFILE%";
      }
    ];

    winpkgs.environment.variables = lib.mapAttrs (_: toWindows) cfg.sessionVariables;
    winpkgs.environment.path = map toWindows cfg.sessionPath;
    winget.packages = map (p: { id = p.winget.id; }) ownPackages;

    assertions = [
      {
        assertion = outsideHome == [ ];
        message = ''
          home.file targets outside the home directory have no place on Windows: ${names outsideHome}.
          Use windows.files with a Windows path instead.'';
      }
    ]
    ++ sugar.packageAssertions "home.packages" translated;

    warnings =
      lib.optional (withOnChange != [ ])
        "home.file.onChange is not run on Windows (winpkgs has no resource that runs a command): ${names withOnChange}"
      ++
        lib.optional (otherSearchVariables != [ ])
          "home.sessionSearchVariables other than PATH are not carried to Windows: ${lib.concatStringsSep ", " otherSearchVariables}";
  };
}
