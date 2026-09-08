# File Explorer and the shell. Half of these values run backwards or count in
# their own way -- `HideFileExt` hides, `Hidden` is 1/2 rather than 1/0 -- which
# is the reason the module exists.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.winpkgs.explorer;

  advanced = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'';
  cabinetState = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'';

  # The Windows 11 context menu asks this CLSID to load; a registered but empty
  # InprocServer32 makes the ask fail, and Explorer falls back to the Windows 10
  # menu. The switch is the value's presence, not its content.
  classicMenu = ''HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'';

  settings = {
    showHiddenFiles = {
      key = advanced;
      name = "Hidden";
      type = types.bool;
      encode = sugar.pair 1 2;
      description = "Show files and folders marked hidden.";
    };
    showFileExtensions = {
      key = advanced;
      name = "HideFileExt";
      type = types.bool;
      encode = sugar.off;
      description = "Show extensions for known file types.";
    };
    showProtectedOsFiles = {
      key = advanced;
      name = "ShowSuperHidden";
      type = types.bool;
      encode = sugar.on;
      description = "Show protected operating system files.";
    };
    launchTo = {
      key = advanced;
      name = "LaunchTo";
      type = types.enum [
        "home"
        "thisPC"
        "downloads"
      ];
      encode = sugar.choice {
        thisPC = 1;
        home = 2;
        downloads = 3;
      };
      description = "The folder a new File Explorer window opens to.";
    };
    compactMode = {
      key = advanced;
      name = "UseCompactMode";
      type = types.bool;
      encode = sugar.on;
      description = "Use the tighter Windows 10 row spacing in file lists.";
    };
    expandToCurrentFolder = {
      key = advanced;
      name = "NavPaneExpandToCurrentFolder";
      type = types.bool;
      encode = sugar.on;
      description = "Keep the navigation pane expanded to the folder being viewed.";
    };
    showAllFoldersInNavPane = {
      key = advanced;
      name = "NavPaneShowAllFolders";
      type = types.bool;
      encode = sugar.on;
      description = "Show every folder, including the desktop and the recycle bin, in the navigation pane.";
    };
    separateProcess = {
      key = advanced;
      name = "SeparateProcess";
      type = types.bool;
      encode = sugar.on;
      description = "Run each File Explorer window in its own process, so one hang does not take the shell with it.";
    };
    hideDrivesWithNoMedia = {
      key = advanced;
      name = "HideDrivesWithNoMedia";
      type = types.bool;
      encode = sugar.on;
      description = "Hide empty card readers and optical drives from This PC.";
    };
    showSyncProviderNotifications = {
      key = advanced;
      name = "ShowSyncProviderNotifications";
      type = types.bool;
      encode = sugar.on;
      description = "Show sync provider notifications -- which is how OneDrive advertises inside File Explorer.";
    };
    fullPathInTitleBar = {
      key = cabinetState;
      name = "FullPath";
      type = types.bool;
      encode = sugar.on;
      description = "Show the full path in the title bar.";
    };
  };
in
{
  options.winpkgs.explorer = sugar.options settings // {
    contextMenu = mkOption {
      type = types.nullOr (
        types.enum [
          "modern"
          "classic"
        ]
      );
      default = null;
      description = ''
        Which right-click menu the shell uses. `classic` is the full Windows 10
        menu, restored by registering an empty handler for the CLSID Windows 11
        asks for; `modern` removes that registration again, which means deleting
        the key rather than a value.

        `null` leaves whatever the machine already has.
      '';
    };
  };

  config = {
    winpkgs.registry = lib.mkMerge [
      (sugar.writes settings cfg)
      (lib.optionalAttrs (cfg.contextMenu == "classic") {
        "${classicMenu}\\InprocServer32"."" = "";
      })
    ];

    winpkgs.registryKeys = lib.optionalAttrs (cfg.contextMenu == "modern") {
      ${classicMenu} = false;
    };

    winpkgs.explorer.restartKeys = sugar.keys settings ++ [ classicMenu ];
  };
}
