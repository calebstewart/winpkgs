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
{ lib }:
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
}
