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

  windows.developer.longPaths = true;
  windows.keyboard.remap.CapsLock = "LeftCtrl";
  windows.privacy.telemetry = "required";

  # Anything the modules above do not model stays reachable.
  windows.registry."HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer".NoNewAppAlert = 1;
}
