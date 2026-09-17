# gsudo, the other answer to `security.sudo`: a sudo for Windows that predates
# Microsoft's, installed rather than shipped, and shell-aware -- it elevates a
# command as the syntax of the shell that called it, so a PowerShell alias or
# cmdlet works where `sudo.exe` sees only a name that is not a program. It also
# caches credentials, so a run of elevated commands costs one UAC prompt rather
# than one each, and can elevate as SYSTEM or TrustedInstaller.
#
# Which sudo a machine has is the machine's question, which is why `enable`
# lives here and not in a home configuration: two users on one machine cannot
# each have a different `sudo`. What a user does with it -- the PowerShell
# module, the `sudo` alias, their own preferences -- is `programs.gsudo` in the
# home tree.
#
# `security.sudo` and `security.gsudo` are exclusive. Both put a `sudo` on the
# machine, and the one that answers is whichever PATH finds first (System32
# wins by default, since winget appends its Links directory). Rather than
# leave that to PATH, enabling gsudo turns Sudo for Windows off -- at
# `mkDefault`, so `security.sudo.enable = false` written by hand is the same
# statement, and `enable = true` beside gsudo is a refusal rather than a race.
#
# Settings are REG_SZ values under `HKLM\SOFTWARE\gsudo`, read by gsudo itself
# on every run; the four declared here are the ones gsudo keeps in HKLM only,
# because a user must not be able to grant themselves cached elevation. The
# rest are per-user and live in `programs.gsudo.settings`; `settings` here is
# the same escape hatch machine-wide, and a value in HKLM overrides the user's.
#
# Non-goal: `gsudo config PathPrecedence true`. It is not really a setting --
# gsudo's own source calls the stored value anecdotical -- it reorders the
# machine PATH so that gsudo's directory comes before System32. That is
# `environment.path`'s job here, and `security.gsudo.pathPrecedence` says it
# declaratively.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.security.gsudo;
  sudo = config.security.sudo;

  gsudo = ''HKLM\SOFTWARE\gsudo'';

  # gsudo reads every value as a string and parses it itself: bool.Parse for
  # the booleans, its own enum parser for the rest. A DWord here is a value it
  # cannot read at all.
  yesNo = v: if v then "True" else "False";

  settings = {
    cacheMode = {
      key = gsudo;
      name = "CacheMode";
      type = types.enum [
        "explicit"
        "auto"
        "disabled"
      ];
      encode = sugar.choice {
        explicit = "Explicit";
        auto = "Auto";
        disabled = "Disabled";
      };
      description = ''
        When one UAC prompt may stand in for the next -- gsudo's credentials
        cache, which is an elevated gsudo left running that lets the process
        that started it elevate again.

        - `explicit`: every elevation prompts, unless a session was started by
          hand with `gsudo cache on`. gsudo's own default.
        - `auto`: the first elevation prompts and starts a cache session, so a
          run of commands costs one prompt. This is what `sudo` feels like on
          Linux, and it is the reason to want gsudo at all.
        - `disabled`: every elevation prompts and a cache session is an error.

        A cache session is only as safe as the process holding it: anything
        running as you, at medium integrity, can inject into that process and
        elevate silently while it lasts. That is why gsudo does not cache by
        default, and why this value is the machine's rather than each user's.
      '';
    };
    cacheDuration = {
      key = gsudo;
      name = "CacheDuration";
      type = types.str;
      description = ''
        How long a credentials cache session may sit idle before it closes,
        as `HH:MM:SS`; `"Infinite"` keeps it until sign-out. gsudo's default is
        five minutes.
      '';
    };
    enforceUacIsolation = {
      key = gsudo;
      name = "SecurityEnforceUacIsolation";
      type = types.bool;
      encode = yesNo;
      description = ''
        Run the elevated command with its input closed, so nothing unelevated
        on the same console can drive it. The same trade `security.sudo.mode =
        "disableInput"` makes: you keep the output where you are looking, and
        give up typing at the elevated process.
      '';
    };
    exceptionList = {
      key = gsudo;
      name = "ExceptionList";
      type = types.listOf types.str;
      encode = v: lib.concatMapStrings (e: "${e};") v;
      description = ''
        Programs gsudo starts through `cmd /c` instead of directly, for the
        ones that misbehave when it attaches them to the calling console.
        gsudo's own list is `notepad.exe`, `powershell.exe`, `whoami.exe`,
        `vim.exe` and `nano.exe`; naming any replaces it rather than adding.
      '';
    };
  };
in
{
  options.security.gsudo = sugar.options settings // {
    enable = mkEnableOption ''
      gsudo as this machine's sudo: the `gerardog.gsudo` package, installed
      machine-wide. It brings its own `sudo` command as well as `gsudo`, so it
      is exclusive with `security.sudo` -- but enabling it writes nothing to
      Sudo for Windows' own switch, because a disabled `sudo.exe` refuses
      rather than standing aside. Which one the name `sudo` reaches is PATH
      order: `security.gsudo.pathPrecedence` settles it for the machine, and
      `programs.gsudo.sudoAlias` settles it in a user's PowerShell'';

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "gerardog.gsudo";
        programDir = ''%ProgramFiles%\WinGet\Links'';
        mainProgram = "gsudo";
      };
      defaultText = lib.literalExpression ''
        pkgs.winpkgs.fromWinget {
          id = "gerardog.gsudo";
          programDir = '''%ProgramFiles%\WinGet\Links''';
          mainProgram = "gsudo";
        }
      '';
      description = ''
        The package to install. winget has gsudo as a portable zip and as an
        MSI, and picks the portable at machine scope -- the MSIs declare no
        scope, and a machine-scope request refuses an installer that does not
        say what it is. The portable lands under `%ProgramFiles%\WinGet\Packages`
        with `gsudo.exe` and `sudo.exe` linked into `%ProgramFiles%\WinGet\Links`,
        which winget puts on the machine PATH.

        `null` installs nothing, for a gsudo that arrives another way.
      '';
    };

    programDir = mkOption {
      type = types.str;
      default = ''%ProgramFiles%\WinGet\Links'';
      example = ''%ProgramFiles%\gsudo\Current'';
      description = ''
        Where gsudo's programs are, for `pathPrecedence` to put in front. The
        default is winget's links directory, which is where the portable
        package's `gsudo.exe` and `sudo.exe` are linked; a gsudo installed from
        the MSI instead lives in `%ProgramFiles%\gsudo\Current`.
      '';
    };

    pathPrecedence = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Put `programDir` ahead of everything else on the machine `PATH`, so
        that `sudo` means gsudo in every shell rather than System32's. This is
        what `gsudo config PathPrecedence true` does -- gsudo's own source
        calls the value it stores anecdotical; the PATH reorder is the change --
        and winpkgs makes it declaratively, through
        `environment.path`'s `lead` position.

        The cost, with the default `programDir`: that directory holds the
        command links of *every* machine-scope portable winget package, so all
        of them move ahead of `System32` too. A portable shipping its own
        `curl.exe` or `more.exe` would win from then on.

        In PowerShell there is a cheaper answer, `programs.gsudo.sudoAlias`: an
        alias outranks any program on the PATH, and changes nothing for the
        rest of the machine.
      '';
    };

    settings = mkOption {
      type = types.attrsOf sugar.stringly;
      default = { };
      example = {
        LogLevel = "Error";
        "NewWindow.Force" = true;
      };
      description = ''
        gsudo settings as `gsudo config` names them, written machine-wide to
        `HKLM\SOFTWARE\gsudo` and overriding whatever a user set for
        themselves. Write each value as what it is -- `true`, `false`, a
        number, or a string for the ones that have no better Nix type
        (`"Auto"`, `"00:05:00"`). They reach the registry as strings, because
        gsudo reads every setting as a string and parses it itself.

        The settings with an option of their own above are the ones gsudo
        keeps in `HKLM` only; everything else is a user's to choose and
        belongs in `programs.gsudo.settings` unless the machine means to
        settle it for everyone.
      '';
    };
  };

  config = {
    environment.systemPackages = lib.optional (cfg.enable && cfg.package != null) cfg.package;

    environment.path = lib.optional cfg.pathPrecedence {
      dir = cfg.programDir;
      position = "lead";
    };

    # Settings are written whether or not winpkgs installed gsudo: they
    # configure the gsudo on the machine, however it got there.
    windows.registry = lib.mkMerge [
      (sugar.writes settings cfg)
      (lib.optionalAttrs (cfg.settings != { }) {
        ${gsudo} = lib.mapAttrs (_: lib.mkDefault) cfg.settings;
      })
    ];

    assertions = [
      {
        assertion = !(cfg.enable && sudo.enable == true);
        message = ''
          security.gsudo.enable and security.sudo.enable are both true, and a machine has one `sudo`.
            gsudo brings its own sudo.exe, so which one answers would come down to PATH order.
            Enable one: security.gsudo for gsudo, security.sudo for Sudo for Windows.'';
      }
      {
        assertion = !(cfg.enable && sudo.mode != null);
        message = ''
          security.sudo.mode is set but security.gsudo.enable replaces Sudo for Windows, which is what the mode configures.
            gsudo's equivalent is security.gsudo.enforceUacIsolation (the `disableInput` trade) and, for a new
            window, `settings."NewWindow.Force"`.'';
      }
    ];

    # Turning Sudo for Windows off does not make `sudo` mean gsudo: sudo.exe
    # stays in System32, which is ahead of winget's Links directory on the
    # PATH, and a disabled one says "Sudo is disabled on this machine" rather
    # than standing aside.
    warnings = lib.optional (cfg.enable && sudo.enable == false && !cfg.pathPrecedence) ''
      security.sudo.enable = false with security.gsudo.enable = true leaves `sudo` naming a switched-off sudo.exe,
        because System32 comes before gsudo on the PATH. `gsudo` itself works; for the name `sudo`, set
        security.gsudo.pathPrecedence = true (every shell), programs.gsudo.sudoAlias in the home configuration
        (PowerShell only), or leave Sudo for Windows alone.'';
  };
}
