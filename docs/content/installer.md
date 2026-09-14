# Unattended installation

Every system configuration carries its own installer. `system.build.installer`
is a program that turns a Windows ISO into boot media which installs Windows,
then the configuration, then one of its homes, with nobody at the keyboard.
Where `install.ps1` ([Installation](installation.html)) starts from a machine
that has already installed itself, this starts one step earlier: the answer
file Windows Setup reads off the boot media, so the machine installs itself
*into* the configuration rather than being taken there afterwards.

```bash
nix run .#windowsConfigurations.desktop.config.system.build.installer -- \
  --iso ~/Downloads/Win11.iso --out /mnt/c/VMs/desktop.iso
```

Boot the result -- written to a USB stick, burned, or attached to a virtual
machine -- and come back to a machine running your configuration, waiting at a
sign-in screen for a password to be chosen. NixOS's `system.build.isoImage` is
the shape: the installer is a property of the configuration rather than a
function somewhere else, so everything the configuration already says -- the
account and computer names, the time zone, the WSL distro -- it already knows.
What Windows Setup needs beyond that is {option}`winpkgs.installer.edition` and
its neighbours, below.

## The program

The program is `build-iso`, and `nix run` on the attribute above runs it. It
takes the ISO and the destination and nothing else has to be said:

| | |
|---|---|
| `--iso <file>` | the Windows ISO, as downloaded from Microsoft |
| `--out <file>` | where the result goes; overwritten if it exists, and written under a `.part` name until it is whole |
| `--work <dir>` | scratch space; the ISO is unpacked here, so it needs as much room again. `$TMPDIR`, else `/tmp` |
| `--os-version <ver>` | use this Foundation-package version instead of reading it out of the image |
| `--help` | the options, and the store paths of the payload and the answer-file template |

Both paths may be Windows paths (`C:\...`) when run from WSL. The program checks
there is room for the unpacked tree in `--work` and for the result beside
`--out` before it starts on either; on a machine whose `/tmp` is in memory,
`--work` is where to point it.

`nix run` leaves no garbage-collector root behind and the result is not a store
path, so a build costs nothing that a `nix-collect-garbage` does not reclaim
(see [Disk](#disk) for what it does cost). Wire it into your flake's `apps` if
you want a shorter name:

```nix
apps.x86_64-linux.build-iso = {
  type = "app";
  program = lib.getExe self.windowsConfigurations.desktop.config.system.build.installer;
};
```

## The Windows ISO

Download it from
[microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11).
winpkgs never fetches it and never copies it into the Nix store: the image is
not redistributable, the download links expire within a day, and a new build
ships every month. As a derivation input it would be copied into the store by
hand and pinned by hash, and every refresh of the media would be a hash to
update and a copy to redo. As a file on the command line it is just read. A new
Windows build is a new file after `--iso` and nothing else.

What *is* winpkgs' stays in Nix. The payload -- both closures with the runtime
that applies them, the distro's system as a binary cache, a pinned NixOS-WSL
image, WSL installer and WinGet client module -- and the answer-file template
are store paths the program carries, so the program is reproducible and cached.
Only the remaster runs outside, and it was never going to be reproducible.

The remaster unpacks the ISO, reads the Windows build out of the image, drops
`autounattend.xml` at the root and the payload under `winpkgs\`, and writes a
new ISO. Microsoft's own boot images -- the BIOS one and the UEFI one -- are
kept byte for byte, so the result still boots with Secure Boot on: nothing on
it is signed by winpkgs because nothing that boots is winpkgs'. The result is
UDF, as the original is, because `install.wim` is larger than ISO 9660 allows a
file to be.

## What the media does

**Windows Setup** reads the answer file without being told to. It wipes disk
{option}`winpkgs.installer.diskId` into an EFI, an MSR and one NTFS partition,
installs {option}`winpkgs.installer.edition` in
{option}`winpkgs.installer.locale`, accepts the licence, and asks for no product
key. While the image is on the disk but has not yet booted, it enables the WSL
and Virtual Machine Platform features, so they are on at first logon and cost
no reboot of their own. It then names the computer, sets the time zone,
creates the account in Administrators, answers every out-of-box screen, and
logs the account on.

**First logon** runs with that account's full token, so nothing before the
reboot has to prompt. It finds the media by its volume label
({option}`winpkgs.installer.label`) rather than a drive letter, so the same
media works as a DVD, a USB stick or a mounted ISO, and runs `setup.ps1` from
it. The run is six phases, five of them before the reboot:

1. **payload**: copy the payload to disk, so the run outlives the media.
2. **wsl**: install WSL from the MSI on the media, import the stock NixOS-WSL
   image, and substitute the configuration's own system into it from the
   binary cache on the media. No network is used.
3. **winget**: install the WinGet client module from the media and wait until
   winget answers.
4. **system**: apply the system configuration, elevated.
5. **credential**: arrange for the setup credential to be retired, below.

**One reboot** follows, and it is not there because anything asked for it.
Everything before it needs the administrator's token; the home configuration
must never be applied elevated. The run comes back through `RunOnce` as the
user, at medium integrity, for the sixth phase: **home**, the home
configuration applied as the user. That reboot is the privilege boundary, and
it is the only one in the run.

A network is wanted for winget packages and for nothing else: the runtime, the
distro, WSL and the WinGet module all travel on the media, and with
{option}`winpkgs.installer.offline` the packages' installers do too (below).
The phases are
recorded under `%LOCALAPPDATA%\winpkgs\setup` with the whole run transcribed to
`setup.log` beside them, so a run that stops can be continued with `setup.ps1
-Resume` from that directory rather than started over.

## Offline media

{option}`winpkgs.installer.offline` puts the winget packages on the media too:
the installer of every `winpkgs/winget` resource in the system document and in
the home's, and of every package those depend on, each a fixed-output fetch of
the URL and SHA-256 in its manifest in `winget.manifests` -- the same pinned
winget-pkgs that chose the version. Beside them goes `installers.json`, which
says for each phase which installer is which package, how to run it (type,
switches, scope), how to find it afterwards (product code, Add/Remove Programs
entries, package family name), and in what order dependencies come first. The
documents do not change; the media carries a sidecar to them.

**Not used by setup yet.** The runtime installs from the carried files when it
is handed them -- `winpkgs.ps1 apply -Config <config.json> -Installers <the
payload's directory>` -- running each installer with winget's switches for its
type and registering portables the way winget does, so the first apply with a
network finds every package installed. First logon does not hand them over
yet: setup still gives the packages to winget, which fetches them. That is the
next step.

A **dependency** resolves against the same pin: the newest version the tree
has, which has to meet the manifest's minimum, and its own dependencies in
turn. The system is installed first, so a dependency the system already
carries is not carried again for the home. A home package whose dependency
installs machine-wide only -- most things built with MSVC need the Visual C++
runtime, which is one -- is refused until the system configuration lists that
dependency, since the home is applied unelevated and nothing else would own it.

What cannot be carried is refused **when the installer is evaluated**, all at
once and before anything is fetched, each by package and reason:

- a Store package (`source = "msstore"`): winget-pkgs has no manifest for it;
- a version the tree has no installer manifest for, or one outside what
  winpkgs' manifest reader reads (the file and line are named);
- no x64 installer at the scope the package installs at;
- an installer of a type the runtime does not run from a file, as the runtime
  itself declares (`runtime/WinPkgs/Resources/WinGet.Offline.json`);
- `ExternalDependencies`, which winget cannot carry either;
- a dependency the tree does not have, or has only older than the minimum.

`upgrade = true` is not refused: the version carried is the one the document
names, and the applies with a network follow winget from then on.

Offline means **as offline as upstream is**. Steam, Discord and Spotify ship a
small installer that downloads the application when it first runs, and no
manifest says so; the media carries that installer, and the application still
comes from the network.

It is off by default because every build of the media fetches every installer
once, which for a real configuration is gigabytes (see [Disk](#disk)).

## The account and its password

The account is named by the home configuration: `"me@desktop"` is the account
`me` on the computer `desktop`, the same reading the `winpkgs` command makes to
find its system. It is created with the password
{option}`winpkgs.installer.password`, which is written into the answer file, on
the media, in plain text. Nix cannot keep a secret -- a derivation is
world-readable and a reproducible one is derivable -- so nothing here pretends
to be one.

It stops working at the first sign-in after the reboot. A task the credential
phase leaves behind, running as SYSTEM, blanks the password, marks it as needing
to be changed, turns automatic logon off, and deletes itself. The first person
at the console signs in with an empty password and has to choose one.

Blank rather than random because "must change at next logon" still asks for the
current password first: a random one nobody knows would not be a forced change
but a locked machine. Windows only lets a blank password sign in at the console,
never over the network, so the window between the retirement and the first
person at the keyboard is not one anyone can reach through.

## Options

Most of what the installer needs is already in the configuration. The names
come from the home; the time zone is `time.timeZone`, translated, through
{option}`winpkgs.installer.timeZone`; the distro is `wsl.*`, and a system
without one gets media without one. The home comes from
{option}`winpkgs.homes`: a system with one home needs nothing more said, and a
system with several picks through `system.build.installers.<user>`, since an
unattended install creates one account.

What Windows Setup needs to know that no winpkgs option already says is
`winpkgs.installer.*`, in the [system options](options/system/index.html):

| | |
|---|---|
| {option}`winpkgs.installer.edition` | the image name Setup installs, `"Windows 11 Pro"` by default; the ISO is checked to carry it |
| {option}`winpkgs.installer.diskId` | the disk to wipe, `0` |
| {option}`winpkgs.installer.locale` | `"en-US"` |
| {option}`winpkgs.installer.productKey` | none by default; Microsoft's published per-edition keys select an edition without activating |
| {option}`winpkgs.installer.timeZone` | the zone in Windows' words; `time.timeZone` translated, by default |
| {option}`winpkgs.installer.label` | the media's volume label, which is how first logon finds the payload |
| {option}`winpkgs.installer.password` | the one-time password above |
| {option}`winpkgs.installer.wslRootfs`, {option}`winpkgs.installer.wslMsi`, {option}`winpkgs.installer.wingetClient` | pinned downloads the media carries, so first logon fetches nothing; another release to change one, `null` to leave it off |
| {option}`winpkgs.installer.offline` | carry every winget package's installer too ([Offline media](#offline-media)); off |

## What is refused, and where

Nobody is there to fix a home that fails at the end of an install, so what can
be known beforehand is checked beforehand, and the message says what to change.

**At evaluation**, before anything is built:

- `winpkgs.homes` lists no home: the installer installs one, so add it there.
- Several homes and `system.build.installer` cannot choose: use
  `system.build.installers.<user>`.
- The home is named for another machine: the host half of a home's name is the
  computer's name and how the `winpkgs` command finds the system, so a pair
  that disagrees would install a machine neither describes.
- The home sets `windows.taskbar.widgets` and the system leaves the User Choice
  Protection Driver running, which refuses that write whatever the permissions
  say. Set `windows.userChoiceProtection.enable = false` in the system
  configuration; Setup restarts between the two applies, which is what unloads
  the driver.
- A computer name over 15 characters, which Windows refuses, or a user named
  the same as the computer, which Windows also refuses and only says so after
  the image is on the disk.
- With {option}`winpkgs.installer.offline`, every package that cannot be
  carried, each with its reason ([Offline media](#offline-media)).

**When the program runs**, before anything is written:

- The image has no edition by the name `winpkgs.installer.edition` asks for.
  The editions it does have are listed; pick one.
- The file is not a Windows installation ISO: no `install.wim` or
  `install.esd`, or no Microsoft boot images.
- Too little room to unpack the ISO and the payload where `--work` points, or
  to write the result beside `--out`.
- The image's Foundation package cannot be found, so the Windows build cannot
  be read. `--os-version` names it by hand.

## Disk

The program unpacks the ISO under `--work` and copies the payload in, so that
directory needs as much free space as the two together, and the result beside
`--out` is as large again. The work directory is removed when the program
exits, however it exits, and neither is in the Nix store.

The store holds the payload, and with `wsl.enable` the payload holds the
distro's entire system as a binary cache. Offline media adds every installer:
for a real configuration that is around two gigabytes, which takes the result
past what a single-layer DVD (4.7 GB) holds -- a USB stick or a virtual
machine does not mind -- and `build-iso --help` says how much this payload
carries. The installers are fetched into the store once and the payload links
to them, so rebuilding the media after a change to the configuration fetches
only what changed, and a store that has fetched a release can rebuild the media
after upstream has deleted it. Every change to the configuration is a new
payload, and the old ones stay until collected:

```bash
nix-collect-garbage
```

Deleting store paths does not shrink the WSL distro's virtual disk on its own.
The distro's `ext4.vhdx` only grows unless it is told otherwise; to get the
space back on the Windows side, trim inside the distro, then compact the disk
from Windows with it stopped:

```bash
sudo fstrim /
```

```powershell
wsl --shutdown
Optimize-VHD -Path <path to ext4.vhdx> -Mode Full    # Hyper-V module, elevated
```

`wsl --manage <distro> --set-sparse true` makes the disk give space back as it
goes, at some cost in write speed.

## The parts on their own

Media you make yourself -- a USB stick, an ISO you already remaster -- needs
the same two things the program adds: the program's `passthru.payload` is the
directory first logon runs, to be copied to `winpkgs\` at the root of the
media, and `passthru.unattendTemplate` is `autounattend.xml` with
`@osVersion@` where the image's Foundation-package version goes. `build-iso
--help` prints both store paths, and `nix build` of the installer attribute
reaches them through `passthru`. An offline payload links to its installers,
so copy it following links (`cp -rL`), as the program does.

The functions they are built from are
[`winpkgs.lib.installer`](lib/winpkgs.lib.installer.html): `mkUnattend` for an
answer file with any of the above changed, `mkPayload` for a payload without a
home or without a distro, `offlinePlan` and `mkInstallers` for what offline
media carries, and `mkRemaster` for a program over an answer file and payload
of your own.
