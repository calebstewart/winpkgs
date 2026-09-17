# gsudo for one user: their own settings, and what it takes for `gsudo` and
# `sudo` to behave in their PowerShell.
#
# Whether the machine has gsudo at all is `security.gsudo.enable` in the system
# configuration -- a machine has one `sudo`, and a home configuration never
# elevates, so it could not install it anyway. Nothing here installs anything;
# it configures a gsudo that is either there or not, and every line it writes
# into the profile checks for it at run time rather than assuming.
#
# That is also why the integration switches default to `false` where the
# upstream ones (`programs.starship.enablePowerShellIntegration` and its
# siblings) default to `true`: those hang off the program's own `enable` in the
# same configuration, and this one has nothing in the home tree to hang off.
#
# gsudo ships a PowerShell module beside its executable -- `gsudoModule.psd1`,
# which gives `gsudo !!`, tab completion for both command names, `Invoke-Gsudo`
# for elevating a scriptblock with `$using:` variables, and a `gsudo` function
# so that `Get-Help gsudo` says something. Where it is depends on how gsudo was
# installed (the portable winget package puts it under
# `%ProgramFiles%\WinGet\Packages\...\x64`, the MSI under
# `%ProgramFiles%\gsudo\Current`), so the profile finds it from the command
# rather than from a path this module guesses: `gsudo.exe` on the PATH is a
# symbolic link to the real one, and the module sits beside the target.
{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.programs.gsudo;
  powershell = config.programs.powershell;

  gsudo = ''HKCU\SOFTWARE\gsudo'';

  # `$gsudoVerbose` and `$gsudoAutoComplete` are read by the module as it
  # loads, so they are set before the import or not at all.
  psBool = v: if v then "$true" else "$false";
  variables =
    lib.optional (cfg.verbose != null) "$gsudoVerbose = ${psBool cfg.verbose}"
    ++ lib.optional (cfg.autoComplete != null) "$gsudoAutoComplete = ${psBool cfg.autoComplete}";

  # Resolving the link needs .NET on 5.1 (`ResolveLinkTarget` is PowerShell 7's,
  # and `.Target` is a string collection there but a path here), so the block
  # asks for the target through Get-Item and falls back to the command itself
  # when it is not a link -- an MSI install is a real file.
  moduleBlock = ''
    $gsudo = (Get-Command gsudo -Type Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($gsudo) {
    ${lib.concatMapStrings (v: "    ${v}\n") variables}    $item = Get-Item -LiteralPath $gsudo -Force
        $target = if ($item.Target) { @($item.Target)[0] } else { $gsudo }
        $gsudoModule = Join-Path (Split-Path -Parent $target) 'gsudoModule.psd1'
        if (Test-Path -LiteralPath $gsudoModule) { Import-Module $gsudoModule }
    }'';

  # The module defines a `gsudo` function (that is what makes `gsudo !!` work),
  # so the alias points at the function when the module is loaded and at
  # gsudo.exe when it is not.
  aliasBlock = "if (Get-Command gsudo -ErrorAction SilentlyContinue) { Set-Alias -Name 'sudo' -Value 'gsudo' }";
in
{
  options.programs.gsudo = {
    enablePowerShellIntegration = mkEnableOption ''
      gsudo's PowerShell module in `programs.powershell`'s profile: `gsudo !!`
      to repeat the last command elevated, tab completion for `gsudo` and
      `sudo`, and `Invoke-Gsudo` for a scriptblock that reads `$using:`
      variables. The profile looks for gsudo when it runs and does nothing
      when the machine has none, so this is safe to leave on for a machine
      that may not have it yet'';

    sudoAlias = mkEnableOption ''
      `sudo` as a name for gsudo in PowerShell (`Set-Alias sudo gsudo`). An
      alias outranks any program on the PATH, so this settles what `sudo` means
      in this user's shell whichever sudo the PATH would find -- without it,
      `sudo` is whatever comes first, which on a machine with Sudo for Windows
      still installed is System32's. For every other shell, the machine's
      `security.gsudo.pathPrecedence` is the answer'';

    verbose = mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = ''
        gsudo's `$gsudoVerbose`: whether `gsudo !!` prints the command it is
        about to elevate. `null` leaves the module's own default (`$true`).
      '';
    };

    autoComplete = mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = ''
        gsudo's `$gsudoAutoComplete`: whether the module registers its argument
        completers for `gsudo` and `sudo`. `null` leaves the module's own
        default (`$true`).
      '';
    };

    settings = mkOption {
      type = types.attrsOf sugar.stringly;
      default = { };
      example = {
        LogLevel = "Error";
        PowerShellLoadProfile = true;
      };
      description = ''
        This user's gsudo settings, as `gsudo config` names them, written to
        `HKCU\SOFTWARE\gsudo`. Write each value as what it is -- `true`,
        `false`, a number, or a string for the ones that have no better Nix
        type (`"OsDefault"`). They reach the registry as strings, because gsudo
        reads every setting as a string and parses it itself.

        `CacheMode`, `CacheDuration`, `SecurityEnforceUacIsolation` and
        `ExceptionList` are not among them -- gsudo reads those from `HKLM`
        only, so that a user cannot grant themselves cached elevation. They are
        `security.gsudo.*` in the system configuration, and a value the machine
        sets there overrides anything set here.
      '';
    };
  };

  config = {
    windows.registry = lib.optionalAttrs (cfg.settings != { }) {
      ${gsudo} = lib.mapAttrs (_: lib.mkDefault) cfg.settings;
    };

    # Beside the aliases (600): the module first, then the alias that names the
    # `gsudo` function it defines. Both resolve at call time, so the order is
    # for the reader rather than for PowerShell.
    programs.powershell.initContent = lib.mkMerge [
      (lib.mkIf (powershell.enable && cfg.enablePowerShellIntegration) (lib.mkOrder 640 moduleBlock))
      (lib.mkIf (powershell.enable && cfg.sudoAlias) (lib.mkOrder 650 aliasBlock))
    ];

    assertions = [
      {
        assertion = !(cfg.sudoAlias && powershell.sudoForWindows.enableWrapper);
        message = ''
          programs.gsudo.sudoAlias and programs.powershell.sudoForWindows.enableWrapper both define `sudo`, and one would silently replace the other.
            The wrapper is for Sudo for Windows (`security.sudo`); the alias is for gsudo (`security.gsudo`). Keep the one the machine has.'';
      }
      {
        assertion =
          !(lib.any (
            n:
            lib.elem n [
              "CacheMode"
              "CacheDuration"
              "SecurityEnforceUacIsolation"
              "ExceptionList"
            ]
          ) (lib.attrNames cfg.settings));
        message = ''
          programs.gsudo.settings names a setting gsudo reads from HKLM only, where a home configuration cannot write it.
            Set it in the system configuration instead: security.gsudo.{cacheMode,cacheDuration,enforceUacIsolation,exceptionList}.'';
      }
    ];
  };
}
