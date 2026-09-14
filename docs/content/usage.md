# Usage

## Two configurations, one machine

A machine has one **system configuration** (`windowsConfigurations.<host>`,
built with `winpkgs.lib.windowsSystem`) and, per user, a **home configuration**
(`windowsHomeConfigurations."<user>@<host>"`, built with
`winpkgs.lib.homeConfiguration`). They are separate module trees over shared
primitives, and the kind fixes the scope of every resource:

| | system | home |
|---|---|---|
| owns | `HKLM`, `%ProgramData%`, machine-scope winget, the WSL distro | `HKCU`, `%USERPROFILE%`, user-scope winget, the shell, the `winpkgs` command |
| applied | elevated, by construction; one UAC prompt, only if something changed | as the user; never elevates |
| sugar | NixOS's names: `environment.systemPackages`, `environment.variables`, `time.*`, `security.sudo` | home-manager's names: `home.*`, `xdg.*`, `programs.*` |
| state | `%ProgramData%\winpkgs\system\`, its own generation sequence | `%LOCALAPPDATA%\winpkgs\home\`, its own |
| command | `winpkgs system …` | `winpkgs home …` |

Modules that span both hives (`windows.privacy`, `windows.keyboard`) are
imported by both trees and declare only the half whose keys belong there, so
{option}`windows.privacy.telemetry` exists in a system configuration and
{option}`windows.privacy.advertisingId` in a home one. The
[System](options/system/index.html) and [Home](options/home/index.html) option
sets list each tree's half.

## The `winpkgs` command

The first home activation installs a `winpkgs` command on Windows
({option}`winpkgs.cli.enable`, on by default) and ensures PowerShell 7 is
installed and current ({option}`winpkgs.powershell.ensure`, on by default).
Set where the flake lives and everything runs from any Windows terminal --
Windows PowerShell, pwsh or cmd:

```nix
winpkgs.cli.flake = ''%USERPROFILE%\git\config'';
```

Every verb names its kind, the way `nixos-rebuild` and `home-manager` are two
commands: `winpkgs system …` may prompt for UAC, `winpkgs home …` never does.

```powershell
winpkgs system switch          # WSL distro, then the machine (one UAC prompt, if anything changed)
winpkgs home switch            # this user
winpkgs system plan            # read-only, either kind
winpkgs home apply
winpkgs home generations       # each kind keeps its own; local, no WSL involved
winpkgs home rollback          # back to the generation before the current one
winpkgs system rollback 3      # to generation 3, with its own runtime; elevates once
winpkgs home gc -Keep 5 -OlderThan 30d   # or set winpkgs.generations.{keep,deleteOlderThan} and forget it
winpkgs home plan -Flake 'D:\src\config' -Home 'me@other-host' -ShowUnchanged
winpkgs shell                  # a shell in the distro, in the flake directory
winpkgs flake update komorebi-asc   # nix flake <args> in the distro, in the flake directory
winpkgs rollback --help        # options for any verb
```

`plan`, `apply`, `switch` and `build` translate the flake path with `wslpath`
inside the distro and run `nix run <flake>#…toplevel -- <verb>` there.
`generations`, `rollback` and `gc` run locally, without WSL at all, so a wedged
distro cannot stop a Windows rollback.

## home-manager modules on Windows

A home configuration evaluates home-manager's own module list against a `pkgs`
that is a nixpkgs cross package set for Windows, so
`pkgs.stdenv.hostPlatform.isWindows` is true inside it and a module guarded the
way NixOS and nix-darwin modules are guarded means the right thing:

```nix
{ lib, pkgs, ... }: {
  programs.git = { enable = true; settings.user = { name = "Me"; email = "me@example.com"; }; };
  programs.starship.enable = true;                                 # winget on Windows, Nix elsewhere
  home.packages = [ pkgs.ripgrep pkgs.wezterm ];
  xdg.configFile."wezterm/wezterm.lua".source = ./wezterm.lua;     # %APPDATA% on Windows, ~/.config elsewhere
  home.sessionVariables.EDITOR = "nvim";
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.file.".config/nvim" = { source = ./nvim; recursive = true; };
  windows.files."%LOCALAPPDATA%/nvim" = lib.mkIf pkgs.stdenv.hostPlatform.isWindows { source = ./nvim; recursive = true; };
}
```

What home-manager produces is translated to Windows; what has no Windows
meaning (the activation script, the Nix profile, systemd and launchd services,
the manual) is left unevaluated:

| home-manager | Windows |
|---|---|
| `home.file` (fed by `xdg.configFile` & co.) | `windows.files` under `%USERPROFILE%`, `%APPDATA%` or `%LOCALAPPDATA%` |
| `home.sessionVariables` | `HKCU\Environment` |
| `home.sessionPath` | the user `PATH` |
| `home.packages` | winget, through the overlay's annotations; fonts installed per user from their files |

The home directory is a fiction, `/home/<user>`: home-manager needs an absolute
POSIX path, so the real `C:/Users/<user>` cannot be the value. Targets, variables
and PATH entries under it become `%USERPROFILE%`, or `%APPDATA%` and
`%LOCALAPPDATA%` for the AppData subtrees, and the runtime rewrites the
placeholder inside every text file it writes to the real profile directory
({option}`winpkgs.substitutions`). A module that writes
`${config.home.homeDirectory}/.ssh/id_ed25519` into its git config therefore
means the right file on every platform.

XDG on Windows is the AppData split: `xdg.enable` defaults to true,
`configHome` to `%APPDATA%`, `dataHome` and `stateHome` to `%LOCALAPPDATA%`, all
at `mkDefault`. Programs that honour `XDG_CONFIG_HOME` follow the variable;
programs that do not (anything on Rust's `dirs::config_dir`) read `%APPDATA%`
regardless, and both find the same file.

A file that would contain a Nix store path -- a home-manager module that wraps a
Nix-built program and writes where its plugins live into its own config -- is
refused when the closure is built, by name: there is no store on the machine for
it to point into.

## Packages

nixpkgs is the only package namespace a shared module can speak, and winget is
the only installer Windows has, so the winpkgs overlay bridges them. `pkgs.git`
carries `winget.id == "Git.Git"` from a table grown from use; the
[Packages](catalog/index.html) page is that table. A package without an entry
is an evaluation error that names it. Nothing is cross-compiled: the set is read
for names and annotations, never built.

```nix
home.packages = [
  pkgs.ripgrep                                          # winget, from the table
  pkgs.nerd-fonts.jetbrains-mono                        # a font, installed from its files
  pkgs.thide                                            # a portable program, copied to %LOCALAPPDATA%\Programs
  (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")       # winget, for software nixpkgs lacks
  (pkgs.winpkgs.fromWinget { id = "LLVM.LLVM"; scope = "machine"; })
];
winget.packages = [ { id = "wez.wezterm"; version = "20240203-110809-5046fc22"; } ];   # ids directly, for pins
```

`winget.packages` takes ids directly, with an optional version pin and
`upgrade`; the same id from two places merges into one resource. The system
tree's `environment.systemPackages` works the same way at machine scope.

Versions have nixpkgs' semantics. winpkgs pins
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs), the winget
manifest repository, as a flake input, and a package that names no version gets
the latest one that pin knows -- as `pkgs.git` is whatever the pinned nixpkgs
says it is. Updating packages is updating the pin:

```bash
nix flake update winget-pkgs
```

and a flake that wants to move it on its own schedule pins winget-pkgs itself
and points winpkgs at that pin, the way it does for nixpkgs:

```nix
inputs.winget-pkgs = { url = "github:microsoft/winget-pkgs"; flake = false; };
inputs.winpkgs.inputs.winget-pkgs.follows = "winget-pkgs";
```

Where Windows differs from NixOS is that programs update themselves, so a
resolved version is a floor rather than a target: the package is installed at
it when absent and upgraded to it when what is installed is older, and a newer
install is left alone. A `version` you write is a pin and is enforced exactly,
downgrade included. `upgrade = true` follows winget's latest instead of the pin.
The first system apply after moving the pin prompts for elevation once and
upgrades every machine package the pin moved past; between updates, applies
stay quiet. An id the pinned tree does not have -- a misspelling, the wrong
case -- is an evaluation error naming it and the revision, and
{option}`winget.manifests` is the tree it reads.

Fonts come from Nix packages, not winget, with each tree's upstream shape:
`fonts.packages` in the system configuration installs machine-wide, and a font
package in `home.packages` -- how home-manager does it -- installs for that user.
The closure carries the font files; the runtime copies and registers them, and
removes them when the package leaves the configuration. The overlay marks which
attributes are fonts; `pkgs.winpkgs.font pkg` marks one it does not know.

Where a package's programs land is part of its annotation when the installer
fixes it, so `pkgs.winpkgs.getExe pkgs.alacritty` is
`%ProgramFiles%\Alacritty\alacritty.exe` the way `lib.getExe` is a store path on
Linux; `getExe'` names another program in the same directory, and
`pkgs.winpkgs.toPowerShell` turns either into a path a pwsh command can use.
All of them are under [Library](lib/index.html).

## Settings

`windows.explorer`, `windows.taskbar`, `windows.theme`, `windows.privacy`,
`windows.keyboard`, `windows.developer`, `windows.gaming`, `windows.console`,
`windows.pointer` and `power.*` are sugar over `windows.registry` -- the way
NixOS wraps a config file -- and they are tri-state: each option defaults to
`null`, meaning *leave whatever is there alone*. Turning a module on never
rewrites a setting you did not name. Sugar writes at `mkDefault`, so where the
sugar is wrong, a `windows.registry` entry for the same value wins.

```nix
windows.explorer.showHiddenFiles = true;
# The sugar spells this Hidden = 1; a hand-written entry replaces it.
windows.registry."HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced".Hidden = 2;
```

There is no sugar for *deleting* a value, since `null` is spoken for: that is
`windows.registry.<key>.<name> = null`. Whole keys are `windows.registryKeys`.

Files are `windows.files` (`text`, `source`, `recursive`), copied rather than
symlinked, compared by content; the `merge` attribute names a program-specific
JSON merge for a file the program rewrites too (Windows Terminal). Environment
is `environment.variables` and `environment.path` in the system tree,
`home.sessionVariables` and `home.sessionPath` in the home one. Programs that
should start at sign-in are `windows.startup`.

The clock is a system option under NixOS's names, and `time.timeZone` takes an
IANA name -- translated to the id Windows uses through CLDR's table -- so a host
can share the value with its NixOS side:

```nix
time.timeZone = "America/Chicago";
time.hardwareClockInLocalTime = false;    # the RTC holds UTC, as everything else assumes
time.ntp = {
  enable = true;
  servers = [ "time.cloudflare.com" "time.nist.gov" ];
  pollInterval = 3600;                    # Windows ships 32768 -- over nine hours
};
```

On a machine that boots both Windows and Linux, `hardwareClockInLocalTime =
false` is what stops the two disagreeing by the UTC offset every time you
switch.

## Programs and daemons

The home tree has modules for programs that need more than an install:
`programs.windows-terminal` (owns `settings.json`, with a base16 scheme),
`programs.powershell` (the profile, PSReadLine, aliases, execution policy, and
the shell integration hooks home-manager's `programs.starship`, `oh-my-posh`,
`zoxide` and `direnv` get on Windows), `programs.whkd`, `programs.komorebi`,
`programs.masir` and `programs.flow-launcher`. Each writes the program's
configuration where it looks for it and starts it from the Run key, or, with
`service.enable`, declares it as a `systemd.user.services.<name>` for a user
service manager to run.

The system tree declares Windows services (`windows.services`), scheduled
tasks (`windows.scheduledTasks`), sudo for Windows (`security.sudo`), the
computer name (`networking.hostName`), power plans and buttons (`power.*`), the
WSL distro (`wsl.*`), and what Windows Setup needs to install the machine
unattended (`winpkgs.installer.*`, on
[its own page](installer.html)).

Either tree can run a command when something changes:

```nix
winpkgs.activation.reload-thing = {
  command = "thing --reload";
  triggers = [ config.windows.files."%APPDATA%/thing/config.toml".text ];
};
```

An activation runs after every resource and after pruning, only when the hash of
its command and triggers differs from the one the ledger recorded, so a no-op
apply stays a no-op and the plan shows it as a change exactly when it will run.

## Generations

Every apply keeps its closure -- the document, the files and fonts it names, the
runtime that understands them -- as a generation, and each kind numbers its own.
`winpkgs system|home rollback [N]` runs generation N's own runtime against the
closure N keeps, so a generation that uses a resource type the installed runtime
has never heard of still rolls back, and no WSL is involved.

Generations are kept by policy: {option}`winpkgs.generations.keep` (the newest N
per kind) and {option}`winpkgs.generations.deleteOlderThan` are applied at the
end of every apply, and `gc` does the same by hand. The current generation is
never deleted.

Pruning is what makes lists declarative: the ledger records what winpkgs
installed, and a package, file, font or service that leaves the configuration
is removed at the next apply -- never anything winpkgs did not put there itself.
{option}`winpkgs.prune.winget`, {option}`winpkgs.prune.files` and
{option}`winpkgs.prune.services` switch each kind off.

## Developing

Runtime tests need pwsh 7 and touch only `HKCU\Software\winpkgs-tests` and the
Pester test drive:

```powershell
Invoke-Pester runtime/tests
```

Iterate on the framework from a consumer without pushing:

```bash
nix run .#windowsConfigurations.desktop.config.system.build.toplevel --override-input winpkgs path:../winpkgs -- plan
```

On a fresh NixOS-WSL without `git`, address the checkout as `path:.` so Nix
does not need the git fetcher:

```bash
nix flake check path:.
nix build path:.#checks.x86_64-linux.example && ./result/bin/activate plan
```

`nix flake check` evaluates the example configurations, runs the module-level
checks, and builds this site -- which fails on any option without a description.
