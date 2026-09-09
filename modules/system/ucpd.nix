# The User Choice Protection Driver.
#
# UCPD is a file-system filter driver Windows loads at boot to stop anything but
# Windows itself changing a handful of registry values: the default browser and
# file associations, and the Widgets button on the taskbar. It enforces that
# below the permission system, so the value is refused even when the key grants
# the user Full Control, and refused identically through PowerShell, the .NET
# registry API and reg.exe. Its own service key names what it is for:
#
#   NalAndWigetsPartnerCode : UCPDWIDGETS
#
# That makes it the one thing that can stop a home configuration converging for
# reasons the configuration cannot see. `windows.taskbar.widgets` is the case in
# hand: the value it writes is on the protected list, so a machine with UCPD
# running refuses it and the runtime says so by name.
#
# Turning it off is a machine-wide decision and takes a restart, which is why it
# lives here rather than beside the option it unblocks.
#
# Windows also ships a scheduled task,
# \Microsoft\Windows\AppxDeploymentClient\UCPD velocity, which runs
# %windir%\system32\UCPDMgr.exe as LocalSystem on every logon. Whether that
# rewrites Start is not established here; if it does, the driver still does not
# load until the boot after, so the restart this option asks for is what makes
# the setting bite either way. Disabling the task as well would need a resource
# winpkgs does not have.
{ lib, config, ... }:
let
  inherit (lib) types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.windows.userChoiceProtection;

  service = ''HKLM\SYSTEM\CurrentControlSet\Services\UCPD'';

  settings = {
    enable = {
      key = service;
      name = "Start";
      type = types.bool;
      # A driver's Start value: 1 is boot-time, which is how Windows ships it,
      # and 4 is disabled. Nothing here deletes the driver or its files -- the
      # value is the whole switch, and setting it back restores the shipped
      # behaviour.
      encode = sugar.pair 1 4;
      description = ''
        Let the User Choice Protection Driver run. It is on in a fresh Windows,
        where it refuses writes to the default-browser and file-association
        values and to the taskbar's Widgets button, whatever the permissions on
        those keys say.

        Turn it off to let `windows.taskbar.widgets` and the association
        settings converge. The driver loads at boot, so a restart is needed
        either way, and until then those values keep being refused.
      '';
    };
  };
in
{
  options.windows.userChoiceProtection = sugar.options settings;

  config = {
    windows.registry = sugar.writes settings cfg;

    # A driver's Start value is read at boot and nowhere else, so changing it
    # has done nothing until the machine restarts. The apply reports that and
    # leaves the restarting to whoever asked for it.
    windows.restartKeys = [ ''\Services\UCPD'' ];

    # And the task that would put it back. UCPDMgr.exe runs at every logon; the
    # Start value alone is a setting Windows is free to reconsider, so the
    # option turns both off together and neither on its own.
    # Doubled backslashes: an attribute name cannot be an indented string.
    windows.scheduledTasks = lib.mkIf (cfg.enable != null) {
      "\\Microsoft\\Windows\\AppxDeploymentClient\\UCPD velocity" = cfg.enable;
    };
  };
}
