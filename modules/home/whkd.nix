# whkd, LGUG2Z's hotkey daemon, in home-manager's shape (services.sxhkd is the
# precedent): `programs.whkd.keybindings` is the whkdrc, owned outright; the
# daemon is installed through winget and started at sign-in.
#
# What the file must look like comes from whkd's parser, which is stricter than
# its README lets on: `.shell` is mandatory and comes first, then `.pause` and
# `.pause_hook` in that order (and a hook without a pause misparses, because
# `.pause` is a prefix of `.pause_hook`), then every per-app block, then at
# least one plain binding; a `#` anywhere starts a comment, even inside a
# command; a key is an identifier or a number, and a process name is words. The
# module orders the sections itself and refuses what the parser would refuse,
# so a bad binding fails an evaluation rather than a sign-in.
#
# whkd reads whkdrc once, at start. A changed file lands at the end of an
# apply, but the running daemon keeps the old bindings until it is restarted:
# sign out and in, or bind a restart (see `keybindings`). winpkgs has no
# resource that runs a command, so it cannot do that itself yet.
#
# Win+L never reaches a hotkey daemon; `windows.keyboard.lockShortcut = false`
# is what frees it.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.whkd;

  # The names win-hotkeys' VKey::from_keyname accepts, upper-cased as it
  # compares them (a `VK_` prefix is stripped first). Any of them can be a
  # modifier; the last one in a combination is the key.
  vkeys = [
    "BACK"
    "TAB"
    "CLEAR"
    "RETURN"
    "SHIFT"
    "CTRL"
    "CONTROL"
    "ALT"
    "MENU"
    "PAUSE"
    "CAPITAL"
    "ESCAPE"
    "SPACE"
    "PRIOR"
    "NEXT"
    "END"
    "HOME"
    "LEFT"
    "UP"
    "RIGHT"
    "DOWN"
    "SELECT"
    "PRINT"
    "EXECUTE"
    "SNAPSHOT"
    "INSERT"
    "DELETE"
    "HELP"
    "WIN"
    "LWIN"
    "RWIN"
    "APPS"
    "SLEEP"
    "MULTIPLY"
    "ADD"
    "SEPARATOR"
    "SUBTRACT"
    "DECIMAL"
    "DIVIDE"
    "NUMLOCK"
    "SCROLL"
    "LSHIFT"
    "RSHIFT"
    "LCTRL"
    "LCONTROL"
    "RCTRL"
    "RCONTROL"
    "LALT"
    "LMENU"
    "RALT"
    "RMENU"
    "BROWSER_BACK"
    "BROWSER_FORWARD"
    "BROWSER_REFRESH"
    "BROWSER_STOP"
    "BROWSER_SEARCH"
    "BROWSER_FAVORITES"
    "BROWSER_HOME"
    "VOLUME_MUTE"
    "VOLUME_DOWN"
    "VOLUME_UP"
    "MEDIA_NEXT_TRACK"
    "MEDIA_PREV_TRACK"
    "MEDIA_STOP"
    "MEDIA_PLAY_PAUSE"
    "LAUNCH_MAIL"
    "LAUNCH_MEDIA_SELECT"
    "LAUNCH_APP1"
    "LAUNCH_APP2"
    "OEM_1"
    "OEM_PLUS"
    "OEM_COMMA"
    "OEM_MINUS"
    "OEM_PERIOD"
    "OEM_2"
    "OEM_3"
    "OEM_4"
    "OEM_5"
    "OEM_6"
    "OEM_7"
    "OEM_8"
    "OEM_102"
    "ATTN"
    "CRSEL"
    "EXSEL"
    "PLAY"
    "ZOOM"
    "PA1"
    "OEM_CLEAR"
  ]
  ++ map (n: "NUMPAD${toString n}") (lib.range 0 9)
  ++ map (n: "F${toString n}") (lib.range 1 24)
  ++ map toString (lib.range 0 9)
  ++ lib.stringToCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

  # "alt + shift + oem_4" -> [ "ALT" "SHIFT" "OEM_4" ]; each must be something
  # whkd's parser reads as a key (an identifier or a number) and win-hotkeys
  # knows.
  tokens = hk: map (t: lib.toUpper (lib.trim t)) (lib.splitString "+" hk);
  tokenOk =
    t: builtins.match "[A-Z_][A-Z0-9_]*|[0-9]+" t != null && lib.elem (lib.removePrefix "VK_" t) vkeys;
  hotkeyOk = hk: lib.all tokenOk (tokens hk);

  bound = lib.filterAttrs (_: v: v != null) cfg.keybindings;
  plain = lib.filterAttrs (_: v: builtins.isString v) bound;
  perApp = lib.filterAttrs (_: v: builtins.isAttrs v) bound;

  hotkeys = lib.attrNames bound ++ lib.optional (cfg.pause != null) cfg.pause;
  badHotkeys = lib.filter (hk: !hotkeyOk hk) hotkeys;

  commands =
    lib.attrValues plain
    ++ lib.concatMap lib.attrValues (lib.attrValues perApp)
    ++ lib.optional (cfg.pauseHook != null) cfg.pauseHook;
  badCommands = lib.filter (c: lib.hasInfix "#" c || lib.hasInfix "\n" c) commands;

  appNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues perApp));
  appNameOk = a: builtins.match "[A-Za-z_][A-Za-z0-9_]*( [A-Za-z_][A-Za-z0-9_]*)*" a != null;
  badAppNames = lib.filter (a: !appNameOk a) appNames;

  # The file, in the order the parser insists on.
  line = hk: cmd: "${hk} : ${cmd}";
  appBlock =
    hk: apps:
    "${hk} [\n"
    + lib.concatMapStringsSep "\n" (app: "    ${line app apps.${app}}") (lib.attrNames apps)
    + "\n]";
  directives = [
    ".shell ${cfg.shell}"
  ]
  ++ lib.optional (cfg.pause != null) ".pause ${cfg.pause}"
  ++ lib.optional (cfg.pauseHook != null) ".pause_hook ${cfg.pauseHook}";
  extra = lib.removeSuffix "\n" cfg.extraConfig;
  sections = [
    (lib.concatStringsSep "\n" directives)
  ]
  ++ lib.mapAttrsToList appBlock perApp
  ++ lib.optional (plain != { }) (lib.concatStringsSep "\n" (lib.mapAttrsToList line plain))
  ++ lib.optional (extra != "") extra;
  whkdrc =
    "# Written by winpkgs (programs.whkd); the next apply overwrites edits made here.\n\n"
    + lib.concatStringsSep "\n\n" sections
    + "\n";
in
{
  options.programs.whkd = {
    enable = mkEnableOption "whkd, a hotkey daemon";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "LGUG2Z.whkd";
        scope = "machine";
      };
      defaultText = lib.literalExpression ''pkgs.winpkgs.fromWinget { id = "LGUG2Z.whkd"; scope = "machine"; }'';
      description = ''
        The package to install. winget's is an MSI, so it is machine scope: the
        home hands it to the system configuration that lists this home in
        `winpkgs.homes`, as with any such package. `null` installs nothing, for
        a whkd from scoop or cargo.
      '';
    };

    executable = mkOption {
      type = types.str;
      default = ''C:\Program Files\whkd\bin\whkd.exe'';
      description = ''
        The path of whkd.exe, for the start-up entry: a full path, because the
        Run key does not wait for a fresh install's PATH entry. The MSI's
        location by default.
      '';
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start whkd at sign-in, through `windows.startup`. whkd is a console
        program; the entry runs it under a headless console host so no window
        appears.
      '';
    };

    shell = mkOption {
      type = types.enum [
        "pwsh"
        "powershell"
        "cmd"
      ];
      default = "pwsh";
      description = ''
        The shell that runs the commands: whkd keeps one session of it open and
        writes each command to it. In a PowerShell shell, `$wshell` is a
        `WScript.Shell` object whkd sets up, so `$wshell.AppActivate('Name')`
        focuses a window.
      '';
    };

    pause = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "alt + shift + p";
      description = "A combination that pauses and resumes every other binding.";
    };

    pauseHook = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = ''echo "whkd paused or resumed"'';
      description = "A command to run whenever `pause` is pressed. Needs `pause`.";
    };

    keybindings = mkOption {
      type = types.attrsOf (types.nullOr (types.either types.str (types.attrsOf types.str)));
      default = { };
      example = lib.literalExpression ''
        {
          "alt + h" = "komorebic focus left";
          "alt + return" = "if ($wshell.AppActivate('Terminal') -eq $False) { start terminal }";
          "alt + shift + oem_4" = "komorebic cycle-focus previous";   # oem_4 is [
          # per application, by process name as Get-Process shows it
          "alt + q" = {
            Default = "komorebic close";
            "Google Chrome" = "Ignore";
          };
          # restart whkd so a new whkdrc takes effect (pwsh)
          "alt + o" = "taskkill /f /im whkd.exe; Start-Process whkd -WindowStyle hidden";
        }
      '';
      description = ''
        The bindings: a combination of keys joined by `+`, the last one the key
        and the rest modifiers, to the command that runs in `shell`. Key names
        are win-hotkeys' virtual-key names in any case: `alt`, `ctrl`, `shift`,
        `win`, letters, digits, `f1`..`f24`, `return`, `space`, `left`..`down`,
        `oem_1` (`;`), `oem_4` (`[`), `oem_6` (`]`), and so on.

        A value that is an attribute set binds the combination per application:
        process name to command, `Default` for every other process, `Ignore` to
        let that process keep the keys. `null` drops a binding another module
        made.

        A command cannot contain `#` (whkd reads it as a comment) or a newline.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Lines appended to whkdrc after the bindings, for anything the options above do not say.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = badHotkeys == [ ];
        message = ''
          programs.whkd: not key combinations whkd accepts: ${lib.concatStringsSep ", " badHotkeys}
          A combination is key names joined by `+`; see https://docs.rs/win-hotkeys/latest/win_hotkeys/enum.VKey.html'';
      }
      {
        assertion = badCommands == [ ];
        message = "programs.whkd: a command cannot contain `#` or a newline: ${lib.concatStringsSep ", " badCommands}";
      }
      {
        assertion = badAppNames == [ ];
        message = "programs.whkd: not process names whkd can parse (words of letters, digits and underscores): ${lib.concatStringsSep ", " badAppNames}";
      }
      {
        assertion = plain != { } || extra != "";
        message = "programs.whkd: whkd refuses a whkdrc with no plain binding; per-application blocks alone are not enough";
      }
      {
        assertion = cfg.pauseHook == null || cfg.pause != null;
        message = "programs.whkd.pauseHook needs programs.whkd.pause";
      }
    ];

    home.packages = lib.optional (cfg.package != null) cfg.package;

    # Where whkd looks without WHKD_CONFIG_HOME: ~/.config, not %APPDATA%.
    windows.files."%USERPROFILE%/.config/whkdrc".source = pkgs.buildPackages.writeText "whkdrc" whkdrc;

    windows.startup.whkd = lib.mkIf cfg.autostart ''conhost.exe --headless "${cfg.executable}"'';
  };
}
