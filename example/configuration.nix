# A small but realistic *system* configuration: the machine. Built by
# `nix flake check`. The user's half is example/home.nix.
{ pkgs, ... }:
{
  winpkgs.name = "example";

  # NixOS's name; machine-scope winget through the overlay's annotations.
  environment.systemPackages = [ pkgs._7zz ];

  # winget ids directly, for pins and for things the table does not know.
  winget.packages = [
    {
      id = "wez.wezterm";
      version = "20240203-110809-5046fc22";
    }
  ];

  # NixOS's names, and its IANA zone; the hardware clock reads as UTC so a
  # dual-booting machine and this one agree about what the RTC means.
  time.timeZone = "America/Chicago";
  time.hardwareClockInLocalTime = false;
  time.ntp = {
    enable = true;
    servers = [ "time.cloudflare.com" ];
    pollInterval = 3600;
  };

  # NixOS's name too, for the half of its sudo Windows has. `disableInput`
  # keeps the output in this console without letting anything unelevated type
  # into the elevated process.
  security.sudo.mode = "disableInput";

  # Optional features by the name DISM knows them by. Windows Sandbox needs a
  # restart to finish; the apply says so and leaves the restarting to you.
  windows.features.Containers-DisposableClientVM = true;

  # Who is in which local group, for a member who is not one of this machine's
  # own users -- those say it in their home configuration (example/home.nix),
  # and this list is where the two merge. The built-in groups go by their
  # English names whatever language the machine speaks. Nothing here creates
  # groups or accounts.
  windows.localGroups."Remote Desktop Users".members = [ "EXAMPLE\\someone" ];

  # The home hides the taskbar's Widgets button, a value this driver refuses to
  # let anything but Windows write. A restart after this apply unloads it.
  windows.userChoiceProtection.enable = false;

  windows.developer.longPaths = true;
  windows.keyboard.remap.CapsLock = "LeftCtrl";
  windows.privacy.telemetry = "required";

  # Anything the modules above do not model stays reachable.
  windows.registry."HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer".NoNewAppAlert = 1;
}
