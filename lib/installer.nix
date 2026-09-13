# An unattended Windows installation that lands on a winpkgs configuration.
#
# `install.ps1` starts from a machine that has already installed itself. This
# starts one step earlier: the answer file Windows Setup reads off the boot
# media, so the machine installs itself *into* the configuration rather than
# being taken there afterwards.
#
# These are the pieces; `modules/system/installer.nix` puts them together as
# `system.build.installer`. Two of them are derivations -- the payload, which is
# built from the configurations, and the script that remasters the media -- and
# one is not a derivation at all: the remaster itself, which happens when the
# script runs, against a Windows ISO named on its command line. Microsoft's
# image is neither reproducible nor redistributable, so nothing here asks Nix
# to hold it: the store carries what is ours, and the ISO stays a file.
#
# The two halves of the account are already in the configuration. A home
# configuration is named "<Windows user>@<host>", which is the account name and
# the computer name, and the system configuration carries the time zone and the
# WSL distro. `winpkgs.installer` therefore describes only what Windows Setup
# needs and no winpkgs configuration does: which edition, which disk, which
# locale.
{ lib, winpkgsSrc }:
let
  # A one-time credential, not a secret. Nix cannot keep one -- a derivation is
  # world-readable and a reproducible one is derivable -- so this is deliberately
  # a known value that the run destroys before the machine can be used: at the
  # first sign-in after the system is applied, a task running as SYSTEM blanks
  # the password, marks it "must change at next logon" and turns autologon off,
  # so the first person at the keyboard sets the real one. The value is written
  # into the answer file, and so onto the media; it opens nothing once retired.
  defaultPassword = "winpkgs-setup";

  xml = lib.escapeXML;

  /*
    What setup.ps1 installs before it applies anything, carried on the media
    rather than fetched at first logon.

    Not for want of a network -- the first run to reach setup.ps1 had one. The
    WSL features are enabled offline, but on current Windows that installs a
    placeholder wsl.exe, not WSL: the first call to it fetches the real package
    and closes the console it was called from, which took setup.ps1 with it and
    left no error behind. The MSI skips that path entirely and fixes the
    version. The WinGet client module is here for the same reason install.ps1
    learned the hard way: fetching it means the NuGet provider, whose prompt
    waits forever with nobody there, and a PowerShellGet on 5.1 with no
    -AcceptLicense.

    fetchurl: these URLs are stable and the licences allow it (WSL is MIT,
    NixOS-WSL is Apache-2.0). Fetched only when the payload is built, never by
    evaluating the configuration. x64 only, as is the rest of the installer.
  */
  defaultWslMsi =
    pkgs:
    pkgs.fetchurl {
      url = "https://github.com/microsoft/WSL/releases/download/2.7.14/wsl.2.7.14.0.x64.msi";
      hash = "sha256-2whOU2J5pZ6Qom7FmNiqik3/gwn0HQeP0GJClTrB680=";
    };
  defaultWingetClient =
    pkgs:
    pkgs.fetchurl {
      name = "microsoft.winget.client.1.29.280.nupkg";
      url = "https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.29.280";
      hash = "sha256-cmYCAB5hN+//ZqpzwZfGq2OWri+WNNCtqtoX7FBo7kY=";
    };
  /*
    The stock NixOS-WSL image setup.ps1 imports and then replaces: the
    configuration's own system is substituted into it from the cache on the
    media, so which release it is hardly matters, as long as it speaks flakes
    and reads a flat-file binary cache. Any recent one does.
  */
  defaultWslRootfs =
    pkgs:
    pkgs.fetchurl {
      name = "nixos.wsl";
      url = "https://github.com/nix-community/NixOS-WSL/releases/download/2605.7.2/nixos.wsl";
      hash = "sha256-5xgK1VX9y44eBX4u8FbeRnYDpeUC/4UxBTc4Nxvj9rk=";
    };

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
  inherit
    defaultPassword
    defaultWslMsi
    defaultWingetClient
    defaultWslRootfs
    ;

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
    assert lib.assertMsg (
      lib.length parts >= 2
    ) "winpkgs: a home configuration is named <Windows user>@<host>; '${name}' has no '@'";
    assert lib.assertMsg (host != "") "winpkgs: '${name}' names no host after its '@'";
    assert lib.assertMsg (user != "") "winpkgs: '${name}' names no user before its '@'";
    assert lib.assertMsg (lib.stringLength host <= 15)
      "winpkgs: '${host}' is ${toString (lib.stringLength host)} characters; Windows refuses a computer name over 15";
    # Windows will not create a local account named after the machine: a user
    # name registers NetBIOS entry 03 and the workstation's Server service
    # registers 20, and the same string in both places is ambiguous. Setup does
    # not say so -- it fails the oobeSystem pass and reports "Windows could not
    # complete the installation", after the image is on disk and the features
    # are installed, which is an expensive place to learn it.
    assert lib.assertMsg (lib.toLower user != lib.toLower host)
      "winpkgs: '${name}' names the user and the machine the same. Windows refuses a local account named after the computer, and Setup only says the installation could not be completed.";
    {
      inherit user host;
    };

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
      # null installs without one. The edition still comes from the image's own
      # name above, so Setup has everything it needs -- but the element has to be
      # there with WillShowUI Never, because leaving it out entirely is what makes
      # Setup stop and ask, which is the one thing an unattended install cannot
      # survive. Microsoft publishes a GVLK per edition (Windows 11 Pro is
      # W269N-WFGWX-YVC9B-4J6C9-T83GX) if a particular image insists on one;
      # those select an edition and deliberately do not activate.
      productKey ? null,
      timeZone ? null,
      arch ? "amd64",
      # Generous, and not load-bearing: retiring the setup credential clears the
      # autologon values outright rather than trusting a count to run out on the
      # right boot.
      autoLogonCount ? 5,
      # What first logon runs. Relative to the payload directory on the media.
      firstLogonCommand,
    }:
    let
      international =
        body:
        component {
          inherit arch body;
          name = "Microsoft-Windows-International-Core";
        };
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
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
            </CreatePartitions>
            <ModifyPartitions>
            <!-- Label before Format, and Letter before Format. This file is
                 schema-validated as an ordered sequence: out of order, an
                 element is dropped rather than reported, and an unformatted EFI
                 partition is only discovered later, when bfsvc cannot write the
                 bootloader into it (BfspCopyFile failed, Last Error 0x3, sixty
                 attempts) with Windows already on the disk. -->
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>
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
            <ProductKey>
            <Key>${lib.optionalString (productKey != null) (xml productKey)}</Key>
            <WillShowUI>Never</WillShowUI>
            </ProductKey>
            </UserData>'';
        })
      ]}
      ${servicingFeatures { inherit osVersion arch; }}
      ${settings "specialize" [
        (component {
          inherit arch;
          name = "Microsoft-Windows-Shell-Setup";
          body =
            "<ComputerName>${xml computerName}</ComputerName>"
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
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <NetworkLocation>Work</NetworkLocation>
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
            <Description>winpkgs unattended setup</Description>
            <CommandLine>${xml firstLogonCommand}</CommandLine>
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

  # What the remaster script substitutes for the one fact the answer file
  # cannot get from the configurations: the Windows build, read out of the ISO
  # it is given (see `mkRemaster`).
  osVersionPlaceholder = "@osVersion@";

  /*
    The configuration's WSL system, as a binary cache the distro substitutes it
    from.

    `tarballBuilder` is NixOS-WSL's answer and it needs root, which a Nix sandbox
    does not have. A tarball of the store paths, unpacked into the store, was the
    first answer here, and it cannot work: NixOS mounts /nix/store read-only and
    only the daemon writes to it, so tar fails on the first directory it makes.
    Store paths reach a store through the daemon, the way substitution does --
    so this is a flat-file binary cache, which mkBinaryCache builds in the
    sandbox from the closure, and setup.ps1 has the stock distro substitute the
    system from it with no network and nothing else as a substituter.

    zstd: the NARs are unpacked by Nix, which reads zstd itself, not by
    whatever the stock image happens to carry.
  */
  mkWslCache =
    { pkgs, wslToplevel }:
    pkgs.mkBinaryCache {
      name = "winpkgs-wsl-cache";
      rootPaths = [ wslToplevel ];
    };

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
      systemToplevel,
      homeToplevel ? null,
      # The distro's NixOS toplevel; null when the system has no distro.
      wslToplevel ? null,
      # The stock NixOS-WSL image, the WSL MSI and the Microsoft.WinGet.Client
      # .nupkg; null leaves one out.
      wslRootfs ? null,
      wslMsi ? null,
      wingetClient ? null,
      distro ? "NixOS",
      userName,
    }:
    let
      cache = if wslToplevel == null then null else mkWslCache { inherit pkgs wslToplevel; };
      # What survives the reboot: after it, the payload's own copy is the only
      # thing that still knows the distro's name and whose account to retire.
      settings = pkgs.writeText "setup.json" (
        builtins.toJSON {
          inherit distro;
          user = userName;
        }
      );

      copyClosure = name: top: ''
        mkdir -p $out/${name}
        for part in config.json runtime files fonts; do
          if [ -e ${top}/$part ]; then cp -rL ${top}/$part $out/${name}/$part; fi
        done
      '';
    in
    pkgs.runCommand "winpkgs-installer-payload" { nativeBuildInputs = [ pkgs.unzip ]; } (
      ''
        mkdir -p $out
        cp ${winpkgsSrc}/runtime/setup.ps1 $out/setup.ps1
        cp ${settings} $out/setup.json
      ''
      + copyClosure "system" systemToplevel
      + lib.optionalString (homeToplevel != null) (copyClosure "home" homeToplevel)
      + lib.optionalString (wslRootfs != null) ''
        mkdir -p $out/wsl
        cp ${wslRootfs} $out/wsl/nixos.wsl
      ''
      + lib.optionalString (wslMsi != null) ''
        mkdir -p $out/wsl
        cp ${wslMsi} $out/wsl/wsl.msi
      ''
      # Laid out as a PowerShell module directory, Name\Version\, so setup.ps1
      # only has to copy it. The version is the manifest's own, so an override
      # cannot land under a folder that disagrees with what it contains. What
      # makes a .nupkg a package rather than a module is dropped.
      + lib.optionalString (wingetClient != null) ''
        mkdir module
        unzip -q ${wingetClient} -d module
        version=$(tr -d '\r' < module/Microsoft.WinGet.Client.psd1 \
          | sed -n "s/^ *ModuleVersion *= *'\([^']*\)'.*/\1/p" | head -1)
        if [ -z "$version" ]; then
          echo "winpkgs: no ModuleVersion in the Microsoft.WinGet.Client manifest" >&2
          exit 1
        fi
        rm -rf module/_rels module/package "module/[Content_Types].xml" module/*.nuspec
        mkdir -p $out/modules/Microsoft.WinGet.Client
        cp -r module $out/modules/Microsoft.WinGet.Client/$version
      ''
      + lib.optionalString (cache != null) ''
        mkdir -p $out/wsl
        cp -r ${cache} $out/wsl/cache
        printf '%s' "${wslToplevel}" > $out/wsl/toplevel
      ''
      + ''
        chmod -R u+w $out
      ''
    );

  /*
    The program that makes the boot media: your Windows ISO with the answer
    file at its root and the payload beside it, written wherever you say.

      build-iso --iso Win11.iso --out winpkgs.iso

    A program rather than a derivation, on purpose. The ISO is the one input
    that is not ours: eight gigabytes, signed download links that expire in a
    day, a new build every month, and a licence that forbids redistributing
    what comes out. As a derivation input it had to be copied into the store
    by hand and pinned by hash, and every refresh of the media was a hash to
    update and a copy to redo; as a file on the command line it is just read.
    What *is* ours -- the payload, the answer file, the tools -- is still built
    by Nix and arrives here as store paths, so the script itself is
    reproducible and cached; only the last step, which was never going to be,
    runs outside.

    The Windows build is read out of the image the script is given. `<package
    action="configure">` names Microsoft-Windows-Foundation-Package and the
    version has to match the one *in the image*, which is neither the build nor
    the revision of anything else on the media:

      image build (install.wim metadata)  26200
      boot.wim's reported version         10.0.26100.8037
      Foundation-Package in the image     10.0.26100.1

    It sits at the servicing baseline -- .1 -- while the revision belongs to
    individual update packages, and the baseline is not the build. Name a
    version the image does not have and offlineServicing fails, which Setup
    reports as "Windows 11 installation has failed" at 100%, after the image
    has been applied and with nothing else said. So the script reads the .mum
    out of the WIM, where it is written down, rather than guessing from
    anything cheaper -- and checks the edition the answer file asks for is one
    the image has, for the same reason.

    Microsoft's own bootloaders are kept exactly as they were -- both the BIOS
    El Torito image and the UEFI one -- so a remastered ISO still boots with
    Secure Boot on. UDF because install.wim is over 4GB and ISO 9660 cannot
    hold a file that size.
  */
  mkRemaster =
    {
      pkgs,
      name,
      # The answer file with `osVersionPlaceholder` where the build goes.
      unattendTemplate,
      payload,
      edition,
      label,
      passthru ? { },
    }:
    pkgs.writeShellApplication {
      name = "build-iso";
      # 7z reads, cdrtools writes. Neither does both, and neither is xorriso:
      # it only sees the ISO 9660 side of a Windows ISO, which stops at 4GB and
      # so does not contain install.wim at all, and libisofs cannot write UDF
      # either -- `-udf` is a mkisofs option and xorriso rejects it outright.
      # wimlib reads the image's metadata without applying it.
      runtimeInputs = [
        pkgs.p7zip
        pkgs.cdrtools
        pkgs.wimlib
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
      ];
      derivationArgs = {
        inherit passthru;
      };
      meta.description = "Build ${name}'s unattended installation media from a Windows ISO";
      text = ''
        template=${unattendTemplate}
        payload=${payload}
        placeholder=${lib.escapeShellArg osVersionPlaceholder}
        edition=${lib.escapeShellArg edition}
        label=${lib.escapeShellArg label}

        usage() {
          cat <<EOF
        Usage: build-iso --iso <Windows ISO> --out <file> [options]

        Write ${name}'s installation media: the Windows ISO with this
        configuration's answer file at its root and its payload beside it. Boot
        the result and the machine installs Windows, then the configuration,
        with nobody at the keyboard.

        Options:
          --iso <file>          The Windows ISO, as downloaded from Microsoft.
          --out <file>          Where to write the result. Overwritten if it exists.
          --os-version <ver>    Skip reading the Windows build out of the image and
                                use this one (MAJOR.MINOR.BUILD.SPBUILD, the image's
                                Microsoft-Windows-Foundation-Package version).
          --work <dir>          Scratch space: the ISO is unpacked here, so it needs
                                as much room again. Default: \$TMPDIR, else /tmp.
          -h, --help            This.

        Paths may be Windows paths (C:\\...) when run from WSL.

        Nix-built parts of the media, if you want them on their own:
          payload        $payload
          answer file    $template  ($placeholder stands for the Windows build)
        EOF
        }

        die() { echo "build-iso: $*" >&2; exit 1; }
        step() { echo "==> $*" >&2; }

        # C:\... from WSL: wslpath knows where the drive is mounted.
        native() {
          case "$1" in
            [A-Za-z]:\\*|[A-Za-z]:/*)
              command -v wslpath >/dev/null 2>&1 || die "$1 is a Windows path and this is not WSL"
              wslpath -u "$1" ;;
            *) printf '%s' "$1" ;;
          esac
        }

        iso=""
        out=""
        version=""
        workParent=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --iso) [ $# -ge 2 ] || die "--iso needs a file"; iso=$2; shift 2 ;;
            --out) [ $# -ge 2 ] || die "--out needs a file"; out=$2; shift 2 ;;
            --os-version) [ $# -ge 2 ] || die "--os-version needs a version"; version=$2; shift 2 ;;
            --work) [ $# -ge 2 ] || die "--work needs a directory"; workParent=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
          esac
        done
        [ -n "$iso" ] || { usage >&2; die "--iso is required"; }
        [ -n "$out" ] || { usage >&2; die "--out is required"; }
        if [ -n "$version" ]; then
          printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            || die "--os-version must look like 10.0.26100.1, not '$version'"
        fi

        iso=$(native "$iso")
        out=$(native "$out")
        [ -n "$workParent" ] && workParent=$(native "$workParent")
        [ -f "$iso" ] || die "no such file: $iso"
        outDir=$(dirname "$out")
        [ -d "$outDir" ] || die "no such directory: $outDir"
        [ "$(readlink -f "$iso")" != "$(readlink -f "$out")" ] || die "--out is the input ISO"

        # Room for the unpacked tree and for the result, checked before either
        # is half done. A tree the size of the ISO goes into the work directory
        # -- which is where this has to be said, because on a machine whose /tmp
        # is in memory the default fills it -- and the result goes beside --out.
        isoBytes=$(stat -c %s "$iso")
        kbFree() { df -Pk "$1" | awk 'NR == 2 { print $4 }'; }
        workParent=''${workParent:-''${TMPDIR:-/tmp}}
        [ -d "$workParent" ] || die "no such directory: $workParent"
        if [ "$(kbFree "$workParent")" -lt $((isoBytes / 1024 + isoBytes / 10240)) ]; then
          die "$workParent has less free space than the ISO needs to unpack ($((isoBytes / 1048576)) MB); pass --work <dir> or set TMPDIR"
        fi
        if [ "$(kbFree "$outDir")" -lt $((isoBytes / 1024 + isoBytes / 10240)) ]; then
          die "$outDir has less free space than the result needs ($((isoBytes / 1048576)) MB)"
        fi

        work=$(mktemp -d "$workParent/winpkgs-iso.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        tree=$work/tree

        # 7z, not bsdtar or xorriso. A Windows 11 ISO keeps its real contents in
        # UDF because install.wim is over 4GB and ISO 9660 cannot describe a file
        # that size; both of those read the ISO 9660 side and see a truncated
        # tree -- two entries out of nine hundred and seventy six -- without
        # saying anything is wrong.
        step "unpacking $iso"
        mkdir -p "$tree"
        7z x -y -o"$tree" "$iso" > "$work/7z.log" 2>&1 || { cat "$work/7z.log" >&2; die "7z could not unpack $iso"; }
        chmod -R u+w "$tree"

        image=
        for candidate in install.wim install.esd; do
          if [ -s "$tree/sources/$candidate" ]; then image=$tree/sources/$candidate; break; fi
        done
        [ -n "$image" ] || die "no sources/install.wim or sources/install.esd in $iso -- is it a Windows installation ISO?"
        [ -e "$tree/boot/etfsboot.com" ] && [ -e "$tree/efi/microsoft/boot/efisys.bin" ] \
          || die "$iso has no Microsoft boot images (boot/etfsboot.com, efi/microsoft/boot/efisys.bin)"

        # The edition the answer file asks Setup for, by the name Setup will
        # look it up under. Ask for one the image does not have and Setup stops
        # to ask which -- the one question an unattended install cannot answer.
        step "reading the image"
        wiminfo "$image" | sed -n 's/^Name: *//p' > "$work/editions.txt"
        if ! grep -qxF "$edition" "$work/editions.txt"; then
          echo "build-iso: the image has no edition named '$edition'. It has:" >&2
          sed 's/^/  /' "$work/editions.txt" >&2
          die "set winpkgs.installer.edition to one of those"
        fi

        # Image 1: every edition in a WIM shares one servicing baseline. The
        # listing is written to a file first: it runs to a hundred thousand
        # lines, and a grep that stops early would end wimdir with SIGPIPE.
        if [ -z "$version" ]; then
          wimdir "$image" 1 > "$work/wimdir.txt"
          version=$(grep -oiE 'Microsoft-Windows-Foundation-Package~[^~]*~[^~]*~[^~]*~[0-9.]+\.mum' "$work/wimdir.txt" \
            | sed -n '1s/.*~\([0-9][0-9.]*\)\.mum$/\1/p')
          [ -n "$version" ] || die "no Microsoft-Windows-Foundation-Package in $image; pass --os-version"
        fi
        echo "    edition:  $edition" >&2
        echo "    version:  $version" >&2

        step "adding the answer file and the payload"
        sed "s/$placeholder/$version/g" "$template" > "$tree/autounattend.xml"
        grep -qF "$placeholder" "$tree/autounattend.xml" && die "the answer file still contains $placeholder"
        mkdir -p "$tree/winpkgs"
        cp -rL "$payload"/. "$tree/winpkgs/"
        chmod -R u+w "$tree"

        # Microsoft's own boot images, byte for byte: the BIOS El Torito one and
        # the UEFI one, the second declared with its own platform id. Keeping
        # them is what lets a remastered ISO still boot with Secure Boot on --
        # nothing here is signed by us, because nothing here is ours.
        #
        # cdrtools writes files over 4GB as multi-extent at ISO level 3 and
        # above, and UDF carries them whole, so install.wim needs nothing special
        # here. (genisoimage would: it cannot do multi-extent, which is what its
        # -allow-limited-size is for. cdrtools rejects that option outright.)
        #
        # Written under a .part name and renamed at the end, so a run that is
        # cut short never leaves something that looks finished.
        step "writing $out"
        rm -f "$out.part"
        mkisofs \
          -quiet \
          -iso-level 4 -udf \
          -volid "$label" \
          -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot/etfsboot.com \
          -eltorito-alt-boot -eltorito-platform efi \
          -b efi/microsoft/boot/efisys.bin -no-emul-boot \
          -o "$out.part" "$tree" \
          || { rm -f "$out.part"; die "mkisofs failed"; }
        mv -f "$out.part" "$out"

        echo "    $out ($(( $(stat -c %s "$out") / 1048576 )) MB, volume $label)" >&2
      '';
    };
}
