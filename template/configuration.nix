{ ... }:
{
  winpkgs.name = "desktop";

  winpkgs.packages.winget = [
    "Git.Git"
    "Microsoft.PowerShell"
  ];

  winpkgs.registry = {
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced" = {
      Hidden = 1;
      HideFileExt = 0;
    };
  };
}
