# The unattended installation of this machine, as something the configuration
# builds: `system.build.installer` is a program that turns a Windows ISO into
# boot media which installs Windows, then this system configuration, then one
# of its homes, with nobody at the keyboard.
#
#   nix run .#windowsConfigurations.desktop.config.system.build.installer -- \
#     --iso Win11.iso --out winpkgs.iso
#
# NixOS's `system.build.isoImage` is the shape: the installer is a property of
# the configuration, and what Windows Setup needs to know that no winpkgs
# option already says -- the edition, the disk, the locale -- is a handful of
# options here rather than arguments to a function somewhere else. Everything
# else it needs the configuration already has: the account and computer names
# are the home's name, the time zone is `time.timeZone`, the distro is `wsl`.
#
# The Windows ISO is the one input that is not Nix's to hold -- see
# lib/installer.nix for why the remaster happens when the program runs rather
# than in a derivation -- so nothing about it is an option, and evaluating this
# module costs nothing more than any other.
{
  lib,
  config,
  pkgs,
  winpkgsSrc,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.installer;
  installer = import ../../lib/installer.nix { inherit lib winpkgsSrc; };

  # `pkgs` targets Windows; the payload is built, and the media is made, on the
  # machine doing the evaluating.
  bp = pkgs.buildPackages;

  isHome = h: (h.config.winpkgs.kind or null) == "home";
  homes = lib.filter isHome config.winpkgs.homes;

  wslToplevel =
    if config.wsl.enable then config.system.build.wsl.config.system.build.toplevel else null;

  /*
    One installer per home, keyed by the account it creates. The home's name is
    the account and the computer; the system's name has to be that computer,
    or the pair was never meant for one machine: the `winpkgs` command the home
    installs looks its system up by that host, and this is where a mismatch
    first costs something that cannot be taken back.

    Refusals that belong to the pair rather than to either half are here too,
    where both are in hand, rather than at the very end of an install when the
    home is applied and nobody is there to read the error.
  */
  forHome =
    home:
    let
      names = installer.splitHomeName home.config.winpkgs.name;

      # The Widgets button is guarded by UCPD, which refuses the write whatever
      # the permissions say. The system turning it off is enough: setup
      # restarts between the system and the home, and the driver does not load
      # again.
      widgetsBlocked =
        (home.config.windows.taskbar.widgets or null) != null
        && (config.windows.userChoiceProtection.enable or null) != false;

      checked =
        value:
        lib.throwIf (names.host != config.winpkgs.name)
          ''
            winpkgs: the home configuration '${home.config.winpkgs.name}' is for a machine named
            '${names.host}', and this system configuration is '${config.winpkgs.name}'. The
            host half of a home's name is the computer's name and how the `winpkgs`
            command finds the system, so an installer for the two together would
            install a machine neither describes.
          ''
          (
            lib.throwIf widgetsBlocked ''
              winpkgs: the home configuration '${home.config.winpkgs.name}' sets
              `windows.taskbar.widgets`, which the User Choice Protection Driver refuses
              to let anything but Windows write, and this system configuration leaves it
              running. Set this in the system configuration (setup restarts between the
              two, which is what unloads it):

                  windows.userChoiceProtection.enable = false;
            '' value
          );

      # Offline: every winget package of the pair, and what each depends on,
      # carried as a fetched installer. The plan reads both documents, so a
      # package the home hands to the system is carried once, by the system.
      installers =
        if cfg.offline then
          installer.mkInstallers {
            pkgs = bp;
            plan = installer.offlinePlan {
              system = {
                inherit (config.system.build) document;
                inherit (config.winget) manifests;
              };
              home = {
                inherit (home.config.system.build) document;
                inherit (home.config.winget) manifests;
              };
            };
          }
        else
          null;

      payload = installer.mkPayload {
        pkgs = bp;
        inherit wslToplevel;
        systemToplevel = config.system.build.toplevel;
        homeToplevel = home.config.system.build.toplevel;
        inherit (cfg) wslRootfs wslMsi wingetClient;
        distro = config.wsl.distro;
        userName = names.user;
        inherit installers;
      };

      unattendTemplate = bp.writeText "autounattend.xml.in" (
        installer.mkUnattend {
          osVersion = installer.osVersionPlaceholder;
          computerName = names.host;
          userName = names.user;
          inherit (cfg)
            password
            edition
            productKey
            diskId
            locale
            timeZone
            ;
          firstLogonCommand = installer.mkFirstLogonCommand cfg.label;
        }
      );
    in
    checked (
      installer.mkRemaster {
        pkgs = bp;
        name = home.config.winpkgs.name;
        inherit unattendTemplate payload;
        inherit (cfg) edition label;
        passthru = {
          inherit payload unattendTemplate;
          inherit (names) user host;
        };
      }
    );

  byUser = lib.listToAttrs (
    map (h: lib.nameValuePair (installer.splitHomeName h.config.winpkgs.name).user (forHome h)) homes
  );
in
{
  options.winpkgs.installer = {
    edition = mkOption {
      type = types.str;
      default = "Windows 11 Pro";
      description = ''
        The edition to install, by the image name Windows Setup knows it under
        (`Windows 11 Pro`, `Windows 11 Home`, `Windows 11 Enterprise`). The
        installer checks the ISO it is given carries one by that name and lists
        what it does carry when not.
      '';
    };

    diskId = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = ''
        The disk Windows is installed to, by the number Setup and `diskpart`
        give it. It is wiped: EFI, MSR and one NTFS partition across the rest.
      '';
    };

    locale = mkOption {
      type = types.str;
      default = "en-US";
      description = "The language, keyboard and formats Setup installs with, as a BCP-47 tag.";
    };

    productKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "W269N-WFGWX-YVC9B-4J6C9-T83GX";
      description = ''
        A product key, or none: the edition comes from `edition`, so Setup
        needs no key to choose one, and it is told not to ask. Microsoft's
        published per-edition keys (the example is Windows 11 Pro's) select an
        edition and deliberately do not activate, for an image that insists.
      '';
    };

    timeZone = mkOption {
      type = types.nullOr types.str;
      default = config.time.windowsTimeZone;
      defaultText = lib.literalExpression "config.time.windowsTimeZone";
      example = "Central Standard Time";
      description = ''
        The time zone Setup gives the machine, as the id Windows uses -- not an
        IANA name. Defaults to `time.timeZone`, translated; the system
        configuration sets the same zone again minutes later, so this only
        decides what the clock says before that.
      '';
    };

    label = mkOption {
      type = types.strMatching "[A-Za-z0-9_]{1,32}";
      default = "WINPKGS";
      description = ''
        The volume label of the media. First logon finds the payload by this
        label rather than by a drive letter, so the same media works as a DVD,
        a USB stick or a mounted ISO.
      '';
    };

    password = mkOption {
      type = types.str;
      default = installer.defaultPassword;
      description = ''
        The password of the account Setup creates and logs on with. Not a
        secret -- it is written into the answer file, on the media -- and not
        one for long: the first sign-in after the system is applied blanks it,
        marks it as needing to be changed and turns automatic logon off, so
        the first person at the keyboard chooses the real one.
      '';
    };

    wslRootfs = mkOption {
      type = types.nullOr types.package;
      default = if config.wsl.enable then installer.defaultWslRootfs bp else null;
      defaultText = lib.literalMD "a pinned NixOS-WSL release when `wsl.enable`, else `null`";
      description = ''
        The stock NixOS-WSL image setup imports before substituting this
        configuration's own system into it. Pinned; pass a `fetchurl` of
        another release to change it, or `null` to leave it off the media.
      '';
    };

    wslMsi = mkOption {
      type = types.nullOr types.package;
      default = installer.defaultWslMsi bp;
      defaultText = lib.literalMD "a pinned WSL release";
      description = ''
        The WSL installer carried on the media. Enabling the WSL features does
        not install WSL on current Windows -- it installs a placeholder that
        fetches the real thing the first time it is run -- so the media brings
        its own. Pass another release's MSI to change the version, or `null`
        to have the machine fetch it at first logon.
      '';
    };

    offline = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Carry the installer of every winget package on the media -- those of
        the system configuration and of the home, and those they depend on --
        with `installers.json` describing them, for first logon to install
        from without a network: setup hands both applies the payload's copy
        (`winpkgs.ps1 apply -Installers`) and never waits for winget. The first
        apply with a network hands the packages back to winget, which finds
        them installed. Each installer is a fixed-output fetch of the URL and
        hash in the package's manifest in `winget.manifests`, made once into
        the store when the media is built; a store that has them can rebuild
        the media after upstream deletes a release.

        A package that cannot be carried is refused when the installer is
        evaluated, by name and reason, before anything is fetched: a Store
        package, a version the tree has no installer manifest for, no x64
        installer at the configuration's scope, an installer type the runtime
        does not run, `ExternalDependencies`, a dependency the tree cannot
        meet. Off by default: every media build would otherwise fetch every
        installer, which for a real configuration is gigabytes.

        Offline means as offline as upstream is. A bootstrapper -- Steam,
        Discord, Spotify ship one -- is carried and installs itself, and
        fetches the application the first time it runs.
      '';
    };

    wingetClient = mkOption {
      type = types.nullOr types.package;
      default = installer.defaultWingetClient bp;
      defaultText = lib.literalMD "a pinned Microsoft.WinGet.Client release";
      description = ''
        The `Microsoft.WinGet.Client` PowerShell module, as the `.nupkg` from
        the PowerShell Gallery, carried on the media so that first logon does
        not have to fetch it. `null` fetches it there instead.
      '';
    };
  };

  config = {
    /*
      `installers.<user>` for each home in `winpkgs.homes`, and `installer` for
      the usual case of one. Each is a program -- `nix run` it, or wire it into
      your flake's `apps` -- carrying the payload and the answer-file template
      as `passthru`, for media you make yourself.
    */
    system.build.installers = byUser;
    system.build.installer =
      if homes == [ ] then
        throw ''
          winpkgs: `system.build.installer` installs one of this machine's homes, and
          `winpkgs.homes` lists none. Add the home configuration there:

              winpkgs.homes = [ self.windowsHomeConfigurations."me@${config.winpkgs.name}" ];
        ''
      else if lib.length homes == 1 then
        lib.head (lib.attrValues byUser)
      else
        throw ''
          winpkgs: this machine has ${toString (lib.length homes)} homes and an unattended
          install creates one account. Pick one through `system.build.installers`:
          ${lib.concatMapStrings (u: "\n    system.build.installers.\"${u}\"") (lib.attrNames byUser)}
        '';
  };
}
