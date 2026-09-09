# Sudo for Windows, under NixOS' name for the same question: may a user elevate
# a command from an unelevated console, and how. Machine scope -- Windows keeps
# one answer for everyone on the box -- and available from 24H2, where sudo.exe
# ships in System32 and starts out off.
#
# `enable` is the whole of the overlap with NixOS' sudo, because Windows' sudo
# has no sudoers file. It elevates through UAC, always to the invoking user's
# own administrator token, and cannot run a command as another user at all. So
# `wheelNeedsPassword`, `extraRules`, `execWheelOnly` and `package` are less
# non-goals than questions this sudo does not have: the prompt is UAC's setting,
# the group is the machine's Administrators, and the binary is Windows'.
#
# What is left over is Windows-only and sits beside `enable` the way
# `power.fastStartup` sits beside nix-darwin's names -- `security.sudo.mode`:
# which console the elevated process gets, and whether the unelevated one may
# type at it. That distinction has no Linux counterpart because on Linux there
# is no unelevated half of the pair left running to abuse the console.
#
# One DWORD, and exactly the one `sudo config --enable <mode>` writes, so no
# resource of its own: sudo.exe reads it per run, and the Settings page reflects
# it live rather than at the next sign-in.
#
# Non-goal: the fleet policy at
# `HKLM\SOFTWARE\Policies\Microsoft\Windows\Sudo\EnableSudo`, which caps the
# mode a user may choose rather than choosing one. That is a managed-device
# control on the other side of this setting, and raw `windows.registry` reaches
# it.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.security.sudo;

  sudo = ''HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'';

  # 0 is the fourth member of the same enum, but it is spelled `enable = false`
  # here: "disabled" is not a mode you run sudo in.
  modes = {
    forceNewWindow = 1;
    disableInput = 2;
    normal = 3;
  };

  # Naming a mode is choosing one, so it implies enabling. `enable = true` on
  # its own takes Windows' own default rather than inventing one.
  value =
    if cfg.enable == false then
      0
    else if cfg.mode != null then
      modes.${cfg.mode}
    else if cfg.enable == true then
      modes.forceNewWindow
    else
      null;
in
{
  options.security.sudo = {
    enable = mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = true;
      description = ''
        Whether `sudo` runs at all -- the "Enable sudo" switch on System >
        Advanced. `true` on its own turns it on in `forceNewWindow` mode, which
        is the mode Windows defaults to and the only one with nothing to hijack;
        set `security.sudo.mode` as well to ask for another.

        NixOS defaults this to `true` and owns the sudoers file outright. Here
        it defaults to `null`: sudo is off on a fresh Windows, and a winpkgs
        module does not turn on what you did not name.
      '';
    };

    mode = mkOption {
      type = types.nullOr (types.enum (lib.attrNames modes));
      default = null;
      example = "disableInput";
      description = ''
        Which console the elevated process runs in, and whether the unelevated
        one may type at it -- the three configurations of `sudo config --enable`:

        - `forceNewWindow`: a new console window, the way `runas` behaves. The
          default, and the only mode where the two halves share nothing.
        - `disableInput`: the current window, with the input handle closed. The
          output is where you are looking; nothing unelevated can drive it.
        - `normal`: the current window, input and all -- the behaviour Linux'
          sudo has, and the reason the other two exist. An unelevated process
          on the same console can send input to the elevated one and read its
          output, which is a privilege-escalation path you are choosing to
          accept.

        Setting this implies `security.sudo.enable = true`, since a mode is only
        meaningful for a sudo that runs. `null` leaves whatever the machine has.
      '';
    };
  };

  config = {
    windows.registry = lib.mkIf (value != null) {
      ${sudo}.Enabled = lib.mkDefault value;
    };

    assertions = [
      {
        assertion = !(cfg.enable == false && cfg.mode != null);
        message = "security.sudo.mode is set but security.sudo.enable is false; a sudo that does not run has no mode";
      }
    ];
  };
}
