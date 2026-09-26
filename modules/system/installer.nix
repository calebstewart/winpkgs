# The unattended installation of this machine, as something the configuration
# builds: `system.build.installer` is a program that turns a Windows ISO into
# boot media which installs Windows, then this system configuration, then the
# home of the account it is set up as, with nobody at the keyboard.
#
#   nix run .#windowsConfigurations.desktop.config.system.build.installer -- \
#     --iso Win11.iso --out winpkgs.iso
#
# NixOS's `system.build.isoImage` is the shape: the installer is a property of
# the configuration, and what Windows Setup needs to know that no winpkgs
# option already says -- the edition, the disk, the locale -- is a handful of
# options here rather than arguments to a function somewhere else. Everything
# else it needs the configuration already has: the account is
# `winpkgs.installer.user` -- one of `users.users`, or the user a home is
# named for -- the computer is the system's name, the time zone is
# `time.timeZone`, the distro is `wsl`.
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

  builtin = import ./builtin-groups.nix { inherit lib; };

  homeUser = h: (installer.splitHomeName h.config.winpkgs.name).user;
  declaredUsers = lib.attrValues config.users.users;

  # An account is an administrator when the configuration puts it in
  # Administrators, however that group was spelled: `wheel` and `extraGroups`
  # arrive here through `windows.localGroups`, as does the group by its SID.
  isAdministrator =
    user:
    lib.any (g: lib.any (m: lib.toLower m == lib.toLower user) g.value.members) (
      lib.filter (g: builtin.sidOf g.name == builtin.administrators) (
        lib.mapAttrsToList lib.nameValuePair config.windows.localGroups
      )
    );

  /*
    One installer per account it can create, keyed by that account: every
    account in `users.users`, and every home's in `winpkgs.homes`. The account
    is the one Setup creates and logs on as, and the home -- when the account
    has one -- is the one applied as it. The home's name is the account and
    the computer; the system's name has to be that computer, or the pair was
    never meant for one machine: the `winpkgs` command the home installs looks
    its system up by that host, and this is where a mismatch first costs
    something that cannot be taken back.

    The account first logon runs as does everything the system configuration
    does, so a declared one has to be an administrator in that configuration
    too; one only a home names is created in Administrators, as it always was.

    Refusals that belong to the pair rather than to either half are here too,
    where both are in hand, rather than at the very end of an install when the
    home is applied and nobody is there to read the error.
  */
  forAccount =
    userName:
    let
      home = lib.findFirst (h: homeUser h == userName) null homes;
      declared = lib.findFirst (u: u.name == userName) null declaredUsers;
      names =
        if home != null then
          installer.splitHomeName home.config.winpkgs.name
        else
          installer.splitHomeName "${userName}@${config.winpkgs.name}";

      # The Widgets button is guarded by UCPD, which refuses the write whatever
      # the permissions say. The system turning it off is enough: setup
      # restarts between the system and the home, and the driver does not load
      # again.
      widgetsBlocked =
        home != null
        && (home.config.windows.taskbar.widgets or null) != null
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
            lib.throwIf (declared != null && !isAdministrator userName)
              ''
                winpkgs: the installer creates '${userName}' and runs the whole installation as
                that account, so it has to be a local administrator, and this configuration
                does not make it one. Put it in Administrators:

                    users.users.${lib.strings.escapeNixIdentifier userName}.extraGroups = [ "wheel" ];
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
              )
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
              home =
                if home == null then
                  null
                else
                  {
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
        homeToplevel = if home == null then null else home.config.system.build.toplevel;
        inherit (cfg) wslRootfs wslMsi wingetClient;
        distro = config.wsl.distro;
        userName = names.user;
        # What the setup credential is retired to: the account's own initial
        # password when the configuration declares one, else a blank one.
        initialPassword = if declared == null then null else declared.initialPassword;
        inherit installers;
      };

      unattendTemplate = bp.writeText "autounattend.xml.in" (
        installer.mkUnattend {
          osVersion = installer.osVersionPlaceholder;
          computerName = names.host;
          userName = names.user;
          fullName = if declared == null || declared.description == "" then null else declared.description;
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
        name = "${names.user}@${names.host}";
        inherit unattendTemplate payload;
        inherit (cfg) edition label;
        passthru = {
          inherit payload unattendTemplate;
          inherit (names) user host;
        };
      }
    );

  accounts = lib.unique (map (u: u.name) declaredUsers ++ map homeUser homes);
  byUser = lib.genAttrs accounts forAccount;
in
{
  options.winpkgs.installer = {
    user = mkOption {
      type = types.nullOr types.str;
      default =
        let
          declared = lib.attrValues config.users.users;
        in
        if lib.length declared == 1 then (lib.head declared).name else null;
      defaultText = lib.literalMD "the only account in `users.users`, if there is exactly one";
      example = "me";
      description = ''
        The account the installation is set up as: Setup creates it, logs on as
        it, and runs the rest of the install -- the system configuration, then
        the account's home configuration if `winpkgs.homes` has one -- with its
        token. So it has to be a local administrator: an account in
        `users.users` has to be in Administrators (`extraGroups = [ "wheel" ]`),
        which is checked when the installer is built. Its password on the media
        is `password`, and once setup is done it becomes the account's
        `initialPassword`, to be changed at the next sign-in.

        One of `users.users`, or the user of a home in `winpkgs.homes`. `null`
        -- the default when there is not exactly one account in `users.users`
        -- builds `system.build.installer` for the only account there is, and
        refuses to guess between several.
      '';
    };

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
        one for long: the first sign-in after the system is applied replaces
        it with the account's `initialPassword` (blank for an account only a
        home names), marks it as needing to be changed and turns automatic
        logon off, so the first person at the keyboard chooses the real one.
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
      `installers.<user>` for each account the machine can be installed as, and
      `installer` for the one `winpkgs.installer.user` names -- or the only
      one. Each is a program -- `nix run` it, or wire it into your flake's
      `apps` -- carrying the payload and the answer-file template as
      `passthru`, for media you make yourself.
    */
    system.build.installers = byUser;
    system.build.installer =
      if cfg.user != null then
        byUser.${cfg.user} or (throw ''
          winpkgs: `winpkgs.installer.user` is '${cfg.user}', which is neither in `users.users`
          nor the user of a home in `winpkgs.homes`. It can be one of:
          ${lib.concatMapStrings (u: "\n    \"${u}\"") accounts}
        '')
      else if accounts == [ ] then
        throw ''
          winpkgs: `system.build.installer` creates one of this machine's accounts, and the
          configuration names none. Declare it, or add the home configuration of one:

              users.users.me.extraGroups = [ "wheel" ];
              winpkgs.homes = [ self.windowsHomeConfigurations."me@${config.winpkgs.name}" ];
        ''
      else if lib.length accounts == 1 then
        lib.head (lib.attrValues byUser)
      else
        throw ''
          winpkgs: this machine has ${toString (lib.length accounts)} accounts and an unattended
          install creates one to set it up as. Name it:

              winpkgs.installer.user = "${lib.head accounts}";

          or build one through `system.build.installers`:
          ${lib.concatMapStrings (u: "\n    system.build.installers.\"${u}\"") accounts}
        '';
  };
}
