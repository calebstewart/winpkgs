# PowerShell as a shell, in home-manager's shape (programs.zsh is the model):
# `programs.powershell` owns the user's profile.ps1 -- aliases, PSReadLine,
# the hooks of the prompt and directory tools -- and the per-user
# powershell.config.json where pwsh keeps its execution policy. Installing
# pwsh is `winpkgs.powershell`'s job (on by default); this module configures
# whatever pwsh is there.
#
# The profile is CurrentUserAllHosts: Documents\PowerShell\profile.ps1, read
# by every host (the console, Windows Terminal, VS Code). The Documents path
# is the default one; a profile whose Documents folder is redirected (OneDrive)
# sets `profilePath`. Windows PowerShell 5.1 reads a different directory and
# keeps its execution policy in the registry, so it is a separate switch that
# writes the same profile there, with the caveat that PSReadLine options newer
# than the 2.0 that 5.1 ships are errors at start-up in that host.
#
# home-manager has no programs.powershell, and its starship, zoxide, direnv and
# eza modules know bash, zsh, fish and nushell but not PowerShell; this module
# adds `enablePowerShellIntegration` beside their other integration switches, on
# by default as those are, and puts what the program needs in the profile when
# it is enabled -- a hook for the first three, aliases for eza.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.powershell;
  json = pkgs.buildPackages.formats.json { };

  # PowerShell literals. A single-quoted string is the safe one: no
  # expansion, and a quote inside it doubles.
  quote = s: "'${lib.replaceStrings [ "'" ] [ "''" ] s}'";
  psValue =
    v:
    if builtins.isBool v then
      (if v then "$true" else "$false")
    else if builtins.isInt v then
      toString v
    else
      quote v;

  # A command-line argument: written as it is when nothing in it needs
  # quoting, and as a literal string when something does.
  psArg = s: if builtins.match "[-A-Za-z0-9_.,=:/\\\\]+" s == null then quote s else s;

  # An alias to a bare command is an alias; one carrying arguments has to be a
  # function, because Set-Alias cannot hold them.
  aliasLine =
    name: value:
    if builtins.match "[^[:space:]]+" value != null then
      "Set-Alias -Name ${quote name} -Value ${quote value}"
    else
      "function ${name} { ${value} @args }";

  # A boolean is a switch parameter, which takes its value after a colon or
  # not at all; a value after a space is a positional argument it rejects.
  psReadLineOptions = lib.mapAttrsToList (
    n: v: if builtins.isBool v then "-${n}:${psValue v}" else "-${n} ${psValue v}"
  ) cfg.psReadLine.options;
  psReadLineBlock =
    lib.optionalString (cfg.psReadLine.options != { } || cfg.psReadLine.keyHandlers != { })
      ''
        if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
        ${
          lib.optionalString (
            cfg.psReadLine.options != { }
          ) "    Set-PSReadLineOption ${lib.concatStringsSep " " psReadLineOptions}\n"
        }${
          lib.concatMapStrings (
            chord:
            "    Set-PSReadLineKeyHandler -Chord ${quote chord} -Function ${
                  cfg.psReadLine.keyHandlers.${chord}
                }\n"
          ) (lib.attrNames cfg.psReadLine.keyHandlers)
        }}
      '';

  aliasBlock = lib.concatStringsSep "\n" (lib.mapAttrsToList aliasLine cfg.shellAliases);

  # A home-manager path under the (fictional) home directory, as PowerShell
  # says it: $Env:APPDATA and $Env:LOCALAPPDATA for the AppData subtrees, where
  # the XDG directories live on Windows, $Env:USERPROFILE for the rest.
  homeDir = config.home.homeDirectory;
  backslashes = lib.replaceStrings [ "/" ] [ "\\" ];
  psPath =
    p:
    let
      s = toString p;
      roots = [
        {
          prefix = "${homeDir}/AppData/Roaming";
          var = "$Env:APPDATA";
        }
        {
          prefix = "${homeDir}/AppData/Local";
          var = "$Env:LOCALAPPDATA";
        }
        {
          prefix = homeDir;
          var = "$Env:USERPROFILE";
        }
      ];
      hit = lib.findFirst (r: s == r.prefix || lib.hasPrefix (r.prefix + "/") s) null roots;
    in
    if hit == null then s else hit.var + backslashes (lib.removePrefix hit.prefix s);

  starship = config.programs.starship;
  zoxide = config.programs.zoxide;
  direnv = config.programs.direnv;

  # home-manager's oh-my-posh module writes `settings` to
  # $XDG_CONFIG_HOME/oh-my-posh/config.json and points the shells at it; a
  # `useTheme` is a file inside the Nix package there, which on Windows is a
  # name oh-my-posh resolves itself (it fetches and caches official themes);
  # a `configFile` that is a Nix path is shipped beside the settings file,
  # and one that is a string is a Windows path used as it is.
  omp = config.programs.oh-my-posh;
  ompShipped = omp.configFile != null && !builtins.isString omp.configFile;
  ompShippedName = baseNameOf (toString omp.configFile);
  ompConfig =
    if omp.settings != { } then
      ''--config "${psPath "${config.xdg.configHome}/oh-my-posh/config.json"}"''
    else if omp.useTheme != null then
      "--config ${quote omp.useTheme}"
    else if ompShipped then
      ''--config "${psPath "${config.xdg.configHome}/oh-my-posh/${ompShippedName}"}"''
    else if omp.configFile != null then
      ''--config "${omp.configFile}"''
    else
      "";
  ompHook = lib.concatStringsSep " " (
    [ "oh-my-posh init pwsh" ] ++ lib.optional (ompConfig != "") ompConfig ++ [ "| Invoke-Expression" ]
  );
  zoxideHook = lib.concatStringsSep " " ([ "zoxide init powershell" ] ++ zoxide.options);

  # home-manager's eza module hands its aliases to every shell it knows
  # (programs.bash.shellAliases and the rest); on Windows they belong in the
  # PowerShell profile. The options it would pass are rebuilt here, since the
  # module keeps them to itself, and the `eza` alias that carries them names
  # the executable: a PowerShell function that calls its own name recurses,
  # where a bash alias expands once. The other five go through that function,
  # so `ls` carries the options too, and they are defaults -- a
  # `shellAliases` entry of the same name wins, as in home-manager.
  eza = config.programs.eza;
  ezaIcons = if builtins.isBool eza.icons then (if eza.icons then "auto" else null) else eza.icons;
  ezaOptions = lib.concatMapStringsSep " " psArg (
    lib.optionals (ezaIcons != null) [
      "--icons"
      ezaIcons
    ]
    ++ lib.optionals (eza.colors != null) [
      "--color"
      eza.colors
    ]
    ++ lib.optional eza.git "--git"
    ++ eza.extraOptions
  );
  ezaAliases =
    lib.optionalAttrs (ezaOptions != "") { eza = "eza.exe ${ezaOptions}"; }
    // builtins.mapAttrs (_: lib.mkDefault) {
      ls = "eza";
      ll = "eza -l";
      la = "eza -a";
      lt = "eza --tree";
      lla = "eza -la";
    };

  hooks =
    lib.optional (
      starship.enable && starship.enablePowerShellIntegration
    ) "Invoke-Expression (&starship init powershell)"
    ++ lib.optional (
      zoxide.enable && zoxide.enablePowerShellIntegration
    ) "Invoke-Expression (& { (${zoxideHook} | Out-String) })"
    ++ lib.optional (
      direnv.enable && direnv.enablePowerShellIntegration
    ) ''Invoke-Expression "$(direnv hook pwsh)"''
    ++ lib.optional (omp.enable && omp.enablePowerShellIntegration) ompHook;

  sections = lib.filter (s: s != "") [
    (lib.removeSuffix "\n" psReadLineBlock)
    aliasBlock
    (lib.concatStringsSep "\n" hooks)
    (lib.removeSuffix "\n" cfg.profileExtra)
  ];
  profile =
    "# Written by winpkgs (programs.powershell); the next apply overwrites edits made here.\n\n"
    + lib.concatStringsSep "\n\n" sections
    + "\n";

  settings =
    cfg.settings
    //
      lib.optionalAttrs
        (cfg.executionPolicy != null && !(cfg.settings ? "Microsoft.PowerShell:ExecutionPolicy"))
        {
          "Microsoft.PowerShell:ExecutionPolicy" = cfg.executionPolicy;
        };

  # Windows or POSIX separators, the directory part.
  dirOf = p: lib.head (builtins.match "(.*)[/\\\\][^/\\\\]+" p);

  policies = [
    "Restricted"
    "AllSigned"
    "RemoteSigned"
    "Unrestricted"
    "Bypass"
    "Undefined"
  ];
  integration =
    program: what:
    mkEnableOption "${program}'s PowerShell integration: ${what} in `programs.powershell`'s profile"
    // {
      default = true;
    };
in
{
  options = {
    programs.starship.enablePowerShellIntegration = integration "starship" "its hook";
    programs.zoxide.enablePowerShellIntegration = integration "zoxide" "its hook";
    programs.direnv.enablePowerShellIntegration = integration "direnv" "its hook";
    programs.oh-my-posh.enablePowerShellIntegration = integration "oh-my-posh" "its hook";
    programs.eza.enablePowerShellIntegration = integration "eza" "its aliases";

    programs.powershell = {
      enable = mkEnableOption "PowerShell configuration: the profile and per-user settings";

      profilePath = mkOption {
        type = types.str;
        default = "%USERPROFILE%/Documents/PowerShell/profile.ps1";
        description = ''
          Where the profile is written: pwsh's CurrentUserAllHosts profile, read
          by every host. Point it elsewhere if the Documents folder is
          redirected. `powershell.config.json` goes beside it.
        '';
      };

      executionPolicy = mkOption {
        type = types.nullOr (types.enum policies);
        default = null;
        example = "RemoteSigned";
        description = ''
          pwsh's CurrentUser execution policy, kept in powershell.config.json.
          `null` leaves it (Windows' machine default, RemoteSigned, lets a local
          profile run). `windowsPowerShell.executionPolicy` is the 5.1 host's,
          which lives elsewhere.
        '';
      };

      settings = mkOption {
        type = json.type;
        default = { };
        example = lib.literalExpression ''{ ExperimentalFeatures = [ "PSFeedbackProvider" ]; }'';
        description = ''
          The per-user powershell.config.json, as pwsh documents it, written
          whole beside the profile when it says anything. `executionPolicy`
          fills in `Microsoft.PowerShell:ExecutionPolicy` unless set here.
        '';
      };

      shellAliases = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = lib.literalExpression ''
          {
            g = "git";
            ll = "Get-ChildItem -Force";
          }
        '';
        description = ''
          Aliases. A bare command becomes a `Set-Alias`; a command with
          arguments becomes a function of the same name that passes its own
          arguments on, since a PowerShell alias cannot carry any.
        '';
      };

      psReadLine = {
        options = mkOption {
          type = types.attrsOf (
            types.oneOf [
              types.str
              types.bool
              types.int
            ]
          );
          default = { };
          example = lib.literalExpression ''
            {
              EditMode = "Emacs";
              PredictionSource = "History";
              PredictionViewStyle = "ListView";
              HistoryNoDuplicates = true;
            }
          '';
          description = ''
            Parameters for one `Set-PSReadLineOption` call, by parameter name:
            strings quoted, booleans as switches (`-Name:$true`), integers as
            they are.
            Guarded on the cmdlet being available, which also imports
            PSReadLine if the host has not yet; a host without it skips the
            block.
          '';
        };

        keyHandlers = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = lib.literalExpression ''
            {
              "Ctrl+d" = "DeleteCharOrExit";
              "Ctrl+r" = "ReverseSearchHistory";
            }
          '';
          description = "`Set-PSReadLineKeyHandler` bindings, chord to PSReadLine function name.";
        };
      };

      profileExtra = mkOption {
        type = types.lines;
        default = "";
        description = "Lines at the end of the profile, after the aliases and the tool hooks.";
      };

      windowsPowerShell = {
        enable = mkEnableOption "the same profile for Windows PowerShell 5.1, in its own Documents directory";

        profilePath = mkOption {
          type = types.str;
          default = "%USERPROFILE%/Documents/WindowsPowerShell/profile.ps1";
          description = "Where the 5.1 host reads its CurrentUserAllHosts profile.";
        };

        executionPolicy = mkOption {
          type = types.nullOr (types.enum policies);
          default = null;
          example = "RemoteSigned";
          description = ''
            The 5.1 host's CurrentUser execution policy, a registry value. Its
            machine default on a client is Restricted, under which the profile
            does not run; RemoteSigned is what lets it.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.powershell.shellAliases = lib.mkIf (
      eza.enable && eza.enablePowerShellIntegration
    ) ezaAliases;

    # A configFile from the Nix store cannot be named in the profile (no store
    # on Windows); it travels as a file next to where settings would go.
    xdg.configFile."oh-my-posh/${ompShippedName}" = lib.mkIf (omp.enable && ompShipped) {
      source = omp.configFile;
    };

    windows.files = {
      ${cfg.profilePath}.text = profile;
      "${dirOf cfg.profilePath}/powershell.config.json" = lib.mkIf (settings != { }) {
        source = json.generate "powershell.config.json" settings;
      };
      ${cfg.windowsPowerShell.profilePath} = lib.mkIf cfg.windowsPowerShell.enable { text = profile; };
    };

    windows.registry."HKCU\\Software\\Microsoft\\PowerShell\\1\\ShellIds\\Microsoft.PowerShell" =
      lib.mkIf (cfg.windowsPowerShell.enable && cfg.windowsPowerShell.executionPolicy != null)
        {
          ExecutionPolicy = cfg.windowsPowerShell.executionPolicy;
        };
  };
}
