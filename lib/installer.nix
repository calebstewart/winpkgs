# An unattended Windows installation that lands on a winpkgs configuration.
#
# `install.ps1` starts from a machine that has already installed itself. This
# starts one step earlier: the answer file Windows Setup reads off the boot
# media, so the machine installs itself *into* the configuration rather than
# being taken there afterwards.
#
# The two halves of the account are already in the configuration. A home
# configuration is named "<Windows user>@<host>", which is the account name and
# the computer name, and the system configuration carries the time zone and the
# WSL distro. `setup` therefore describes only what Windows Setup needs and no
# winpkgs configuration does: which edition, which disk, which locale.
{ lib, winpkgsSrc }:
let
  # A one-time credential, not a secret. Nix cannot keep one -- a derivation is
  # world-readable and a reproducible one is derivable -- so this is deliberately
  # a known value that the run destroys before the machine can be used: the
  # finalize phase sets a password generated inside the guest, discards it, and
  # marks the account "must change at next logon". Between first boot and that
  # point the machine has no network-facing state and nobody has logged into it.
  defaultPassword = "winpkgs-setup";

  xml = lib.escapeXML;

  component =
    {
      name,
      arch ? "amd64",
      body,
    }:
    ''
      <component name="${name}" processorArchitecture="${arch}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      ${body}
      </component>'';

  settings = pass: components: ''
    <settings pass="${pass}">
    ${lib.concatStringsSep "\n" components}
    </settings>'';
in
rec {
  inherit defaultPassword;

  /*
    The account name and the computer name, out of a home configuration's own
    name. "Caleb Stewart@gaming-windows" is both, and `modules/home/cli.nix`
    already splits it the same way for `winpkgs.cli.systemName`, so this is not
    a second source of truth -- it is the same one, read again.

    An account name may contain spaces (a Windows display name does); a computer
    name may not, and Windows refuses one over 15 characters, so that is checked
    here rather than three minutes into an install that cannot be undone.
  */
  splitHomeName =
    name:
    let
      parts = lib.splitString "@" name;
      user = lib.concatStringsSep "@" (lib.init parts);
      host = lib.last parts;
    in
    assert lib.assertMsg (lib.length parts >= 2)
      "winpkgs: a home configuration is named <Windows user>@<host>; '${name}' has no '@'";
    assert lib.assertMsg (host != "")
      "winpkgs: '${name}' names no host after its '@'";
    assert lib.assertMsg (user != "")
      "winpkgs: '${name}' names no user before its '@'";
    assert lib.assertMsg (lib.stringLength host <= 15)
      "winpkgs: '${host}' is ${toString (lib.stringLength host)} characters; Windows refuses a computer name over 15";
    { inherit user host; };

  /*
    The two Windows features WSL needs, enabled while the image is still offline.

    Windows Setup runs the offlineServicing pass after it has copied the image to
    disk and before the machine first boots, so the features are already on at
    first logon and cost no reboot of their own. That matters for more than
    speed: it makes the *only* reboot in the run the one between the system and
    home applies, and that reboot is what drops privilege -- first logon runs
    elevated and does the elevated work, the resume comes back through HKCU
    RunOnce at medium integrity and applies the home configuration. One boot
    boundary, one privilege boundary, and no UAC prompt with nobody there to
    answer it.

    `version` has to match the image's own Microsoft-Windows-Foundation-Package,
    so it is read out of the ISO rather than written down.
  */
  servicingFeatures =
    {
      osVersion,
      arch ? "amd64",
      features ? [
        "Microsoft-Windows-Subsystem-Linux"
        "VirtualMachinePlatform"
      ],
    }:
    ''
      <servicing>
      <package action="configure">
      <assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="${osVersion}" processorArchitecture="${arch}" publicKeyToken="31bf3856ad364e35" language="" versionScope="nonSxS" />
      ${lib.concatMapStringsSep "\n" (f: ''<selection name="${xml f}" state="true" />'') features}
      </package>
      </servicing>'';

  /*
    The answer file. `autounattend.xml` at the root of the boot media is what
    Windows Setup reads without being told to.

    Nothing here is a winpkgs concept: it is the disk to wipe, the edition to
    install, the locale, and an account to log on once. Everything the machine
    is *for* arrives later, from the closure the payload carries.
  */
  mkUnattend =
    {
      osVersion,
      computerName,
      userName,
      password ? defaultPassword,
      edition,
      diskId ? 0,
      locale ? "en-US",
      timeZone ? null,
      arch ? "amd64",
      # Generous, and not load-bearing: the finalize phase clears the autologon
      # values outright rather than trusting a count to run out on the right boot.
      autoLogonCount ? 5,
      # What first logon runs. Relative to the payload directory on the media.
      firstLogonCommand,
    }:
    let
      international = body: component { inherit arch body; name = "Microsoft-Windows-International-Core"; };
    in
    ''
      <?xml version="1.0" encoding="utf-8"?>
      <unattend xmlns="urn:schemas-microsoft-com:unattend">
      ${settings "windowsPE" [
        (component {
          inherit arch;
          name = "Microsoft-Windows-International-Core-WinPE";
          body = ''
            <SetupUILanguage><UILanguage>${xml locale}</UILanguage></SetupUILanguage>
            <InputLocale>${xml locale}</InputLocale>
            <SystemLocale>${xml locale}</SystemLocale>
            <UILanguage>${xml locale}</UILanguage>
            <UserLocale>${xml locale}</UserLocale>'';
        })
        (component {
          inherit arch;
          name = "Microsoft-Windows-Setup";
          body = ''
            <DiskConfiguration>
            <WillShowUI>OnError</WillShowUI>
            <Disk wcm:action="add">
            <DiskID>${toString diskId}</DiskID>
            <WillWipeDisk>true</WillWipeDisk>
            <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
            </CreatePartitions>
            <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
            </ModifyPartitions>
            </Disk>
            </DiskConfiguration>
            <ImageInstall>
            <OSImage>
            <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>${xml edition}</Value></MetaData>
            </InstallFrom>
            <InstallTo><DiskID>${toString diskId}</DiskID><PartitionID>3</PartitionID></InstallTo>
            </OSImage>
            </ImageInstall>
            <UserData>
            <AcceptEula>true</AcceptEula>
            </UserData>'';
        })
      ]}
      ${servicingFeatures { inherit osVersion arch; }}
      ${settings "specialize" [
        (component {
          inherit arch;
          name = "Microsoft-Windows-Shell-Setup";
          body = ''
            <ComputerName>${xml computerName}</ComputerName>''
            + lib.optionalString (timeZone != null) ''

              <TimeZone>${xml timeZone}</TimeZone>'';
        })
      ]}
      ${settings "oobeSystem" [
        # Without this the machine stops at "Is this the right country or
        # region?" and waits for somebody who is not there. The windowsPE pass
        # answering the same questions does not carry over.
        (international ''
          <InputLocale>${xml locale}</InputLocale>
          <SystemLocale>${xml locale}</SystemLocale>
          <UILanguage>${xml locale}</UILanguage>
          <UserLocale>${xml locale}</UserLocale>'')
        (component {
          inherit arch;
          name = "Microsoft-Windows-Shell-Setup";
          body = ''
            <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInHDS>true</HideWirelessSetupInHDS>
            <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
            <LocalAccounts>
            <LocalAccount wcm:action="add">
            <Name>${xml userName}</Name>
            <DisplayName>${xml userName}</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>${xml password}</Value><PlainText>true</PlainText></Password>
            </LocalAccount>
            </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
            <Enabled>true</Enabled>
            <Username>${xml userName}</Username>
            <LogonCount>${toString autoLogonCount}</LogonCount>
            <Password><Value>${xml password}</Value><PlainText>true</PlainText></Password>
            </AutoLogon>
            <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
            <Order>1</Order>
            <CommandLine>${xml firstLogonCommand}</CommandLine>
            <Description>winpkgs unattended setup</Description>
            <RequiresUserInput>false</RequiresUserInput>
            </SynchronousCommand>
            </FirstLogonCommands>'';
        })
      ]}
      </unattend>
    '';

  /*
    What first logon runs, and how it finds itself.

    The media's drive letter is not knowable when the answer file is written --
    it depends on how many volumes the machine has -- so the payload is found by
    the volume label instead, which the remaster sets and this is handed. That
    also means the same answer file works from a DVD, a USB stick or a mounted
    ISO without being regenerated.
  */
  mkFirstLogonCommand =
    label:
    "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -Command "
    + "\"$v = Get-Volume | Where-Object { $_.FileSystemLabel -eq '${label}' } | Select-Object -First 1; "
    + "if (-not $v) { throw 'winpkgs: no volume labelled ${label}' }; "
    + "& ($v.DriveLetter + ':\\winpkgs\\setup.ps1')\"";

  /*
    The Windows build, read out of the ISO.

    `<package action="configure">` names the image's own
    Microsoft-Windows-Foundation-Package and the version has to match it exactly,
    so this is the one fact the answer file cannot get from the configurations.
    The WIM carries it in its XML metadata as MAJOR.MINOR.BUILD.SPBUILD.
  */
  mkOsVersion =
    { pkgs, windowsIso }:
    pkgs.runCommand "windows-os-version"
      {
        inherit windowsIso;
        # 7z, not bsdtar or xorriso. A Windows 11 ISO keeps its real contents in
        # UDF because install.wim is over 4GB and ISO 9660 cannot describe a file
        # that size; both of those read the ISO 9660 side and see a truncated
        # tree -- two entries out of nine hundred and seventy six -- without
        # saying anything is wrong.
        nativeBuildInputs = [
          pkgs.p7zip
          pkgs.wimlib
        ];
      }
      ''
        # boot.wim, not install.wim: same build, and 614MB against 7.6GB. The
        # version wanted is the installed image's, and a retail ISO's two WIMs
        # come off the same build -- pass `setup.osVersion` for media where that
        # is not true.
        7z e -y -o. "$windowsIso" sources/boot.wim > /dev/null
        if [ ! -s boot.wim ]; then
          echo "winpkgs: no sources/boot.wim in $windowsIso" >&2
          exit 1
        fi

        wiminfo boot.wim --xml > xml 2>/dev/null || wiminfo boot.wim > xml
        # The XML is UTF-16, so the nulls come out before anything is matched.
        field() { tr -d '\0' < xml | grep -o "<$1>[0-9]*</$1>" | head -1 | tr -dc '0-9'; }
        major=$(field MAJOR)
        minor=$(field MINOR)
        build=$(field BUILD)
        spbuild=$(field SPBUILD)
        if [ -z "$major" ] || [ -z "$build" ]; then
          echo "winpkgs: could not read a Windows version out of $windowsIso" >&2
          exit 1
        fi
        printf '%s.%s.%s.%s' "$major" "''${minor:-0}" "$build" "''${spbuild:-1}" > $out
      '';

  /*
    The configuration's WSL system, as something a machine with no Nix can load.

    `tarballBuilder` is NixOS-WSL's answer and it needs root, which a Nix sandbox
    does not have. What a store archive needs instead is only the closure's paths
    and its registration, both of which `closureInfo` produces at evaluation
    time -- so the archive is an ordinary derivation, and `setup.ps1` unpacks it
    into a stock distro and activates it the way `activate.sh` would have.

    gzip rather than zstd: the stock image is minimal and this must not depend on
    a decompressor that may not be in it.
  */
  mkWslArchive =
    { pkgs, wslToplevel }:
    pkgs.runCommand "winpkgs-wsl-system.tar.gz"
      {
        closure = pkgs.closureInfo { rootPaths = [ wslToplevel ]; };
      }
      ''
        cp $closure/registration registration
        # Absolute store paths, unpacked with -C / on the other side. The
        # registration rides along so nix-store --load-db can make the store
        # believe in what has just appeared in it.
        tar -czf $out --owner=0 --group=0 \
            --transform='s|^registration$|nix/.registration|' \
            -T $closure/store-paths registration
      '';

  /*
    Everything the machine needs, in one directory: the two documents with the
    runtime that applies them, the distro, and the script that drives it.

    No flake, no evaluation, no network. `winpkgs.ps1` is 5.1-compatible by
    construction and applying a document is pure Windows, so a machine at first
    logon already has everything needed to run this.
  */
  mkPayload =
    {
      pkgs,
      system,
      home ? null,
      wslRootfs ? null,
      distro ? "NixOS",
      userName,
    }:
    let
      systemTop = system.config.system.build.toplevel;
      homeTop = if home == null then null else home.config.system.build.toplevel;
      wslToplevel =
        if (system.config.wsl.enable or false) then
          system.config.system.build.wsl.config.system.build.toplevel
        else
          null;
      archive =
        if wslToplevel == null then null else mkWslArchive { inherit pkgs wslToplevel; };
      # What survives the reboot: after it, the payload's own copy is the only
      # thing that still knows the distro's name and whose account to retire.
      settings = pkgs.writeText "setup.json" (builtins.toJSON {
        inherit distro;
        user = userName;
      });

      copyClosure = name: top: ''
        mkdir -p $out/${name}
        for part in config.json runtime files fonts; do
          if [ -e ${top}/$part ]; then cp -rL ${top}/$part $out/${name}/$part; fi
        done
      '';
    in
    pkgs.runCommand "winpkgs-installer-payload" { } (
      ''
        mkdir -p $out
        cp ${winpkgsSrc}/runtime/setup.ps1 $out/setup.ps1
        cp ${settings} $out/setup.json
      ''
      + copyClosure "system" systemTop
      + lib.optionalString (homeTop != null) (copyClosure "home" homeTop)
      + lib.optionalString (wslRootfs != null) ''
        mkdir -p $out/wsl
        cp ${wslRootfs} $out/wsl/nixos.wsl
      ''
      + lib.optionalString (archive != null) ''
        mkdir -p $out/wsl
        cp ${archive} $out/wsl/system.tar.gz
        printf '%s' "${wslToplevel}" > $out/wsl/toplevel
      ''
      + ''
        chmod -R u+w $out
      ''
    );

  /*
    The boot media: the Windows ISO with the answer file at its root and the
    payload beside it.

    Microsoft's own bootloaders are kept exactly as they were -- both the BIOS
    El Torito image and the UEFI one -- so a remastered ISO still boots with
    Secure Boot on. UDF because install.wim is over 4GB and ISO 9660 cannot hold
    a file that size.
  */
  mkIso =
    {
      pkgs,
      windowsIso,
      unattend,
      payload,
      label ? "WINPKGS",
    }:
    pkgs.runCommand "winpkgs-installer.iso"
      {
        inherit windowsIso label;
        # 7z reads the UDF; xorriso writes the new image. Neither does both:
        # xorriso only sees the ISO 9660 side of a Windows ISO, which stops at
        # 4GB and therefore does not contain install.wim at all.
        nativeBuildInputs = [
          pkgs.p7zip
          pkgs.xorriso
        ];
      }
      ''
        mkdir -p tree
        7z x -y -otree "$windowsIso" > /dev/null
        chmod -R u+w tree
        test -e tree/sources/install.wim || test -e tree/sources/install.esd

        cp ${unattend} tree/autounattend.xml
        mkdir -p tree/winpkgs
        cp -rL ${payload}/. tree/winpkgs/
        chmod -R u+w tree

        # Microsoft's own boot images, byte for byte: the BIOS El Torito one and
        # the UEFI one. Keeping them is what lets a remastered ISO still boot
        # with Secure Boot on -- nothing here is signed by us, because nothing
        # here is ours.
        xorriso -as mkisofs \
          -iso-level 3 -udf \
          -volid "$label" \
          -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot/etfsboot.com \
          -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
          -o $out tree
      '';

  /*
    An unattended installation of one system configuration and one home
    configuration, as three things you can build:

      unattend  the answer file on its own, for your own media
      payload   the directory it runs, for a USB stick or an existing ISO
      iso       both of them, inside a copy of your Windows ISO

    The account and computer names come from the home configuration's name; the
    time zone and the distro from the system configuration. `setup` carries only
    what Windows Setup needs and no winpkgs configuration describes.
  */
  mkWindowsInstaller =
    {
      pkgs,
      system,
      home,
      windowsIso ? null,
      wslRootfs ? null,
      setup ? { },
    }:
    let
      names = splitHomeName home.config.winpkgs.name;
      distro = system.config.wsl.distro or "NixOS";
      osVersion =
        if setup ? osVersion then
          setup.osVersion
        else if windowsIso != null then
          builtins.readFile (mkOsVersion { inherit pkgs windowsIso; })
        else
          throw "winpkgs: mkWindowsInstaller needs either `windowsIso` to read the Windows version from, or `setup.osVersion`";

      payload = mkPayload {
        inherit
          pkgs
          system
          home
          wslRootfs
          distro
          ;
        userName = names.user;
      };

      unattend = pkgs.writeText "autounattend.xml" (mkUnattend {
        inherit osVersion;
        computerName = names.host;
        userName = names.user;
        password = setup.password or defaultPassword;
        edition = setup.edition or "Windows 11 Pro";
        diskId = setup.diskId or 0;
        locale = setup.locale or "en-US";
        # Not taken from `time.timeZone`: that option is IANA ("America/New_York")
        # and Setup wants Windows' own name ("Eastern Standard Time"). The system
        # document sets the zone through tzutil a few minutes later anyway, so
        # this stays unset unless somebody asks for it in Windows' vocabulary.
        timeZone = setup.timeZone or null;
        firstLogonCommand = setup.firstLogonCommand or (mkFirstLogonCommand (setup.label or "WINPKGS"));
      });
    in
    {
      inherit unattend payload;
      iso =
        if windowsIso == null then
          throw "winpkgs: the `iso` output needs `windowsIso`"
        else
          mkIso {
            inherit
              pkgs
              windowsIso
              unattend
              payload
              ;
            label = setup.label or "WINPKGS";
          };
    };
}
