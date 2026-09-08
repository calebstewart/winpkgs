# winpkgs

Declarative Windows desktop configuration in the shape of nix-darwin.
**Nix evaluates, PowerShell applies.**

```nix
{
  winpkgs.name = "desktop";

  winpkgs.packages.winget = [ "Git.Git" "wez.wezterm" ];

  winpkgs.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
    contextMenu = "classic";
  };
  winpkgs.taskbar.alignment = "left";
  winpkgs.theme.mode = "dark";
  winpkgs.keyboard.remap.CapsLock = "LeftCtrl";

  # Anything not modelled above is still one attrset away.
  winpkgs.registry."HKCU\\Environment".EDITOR = "nvim";

  winpkgs.files."%USERPROFILE%/.wezterm.lua".source = ./wezterm.lua;
}
```

A home configuration evaluates **home-manager's own modules**, so a module
written for home-manager works as it is, guarded the way NixOS and nix-darwin
modules are -- `pkgs` inside a winpkgs module is a cross package set for
Windows, so `pkgs.stdenv.hostPlatform.isWindows` is true:

```nix
{ lib, pkgs, ... }: {
  programs.git = { enable = true; settings.user = { name = "Me"; email = "me@example.com"; }; };
  programs.starship.enable = true;                                 # winget on Windows, Nix elsewhere
  home.packages = [ pkgs.ripgrep pkgs.wezterm ];
  xdg.configFile."wezterm/wezterm.lua".source = ./wezterm.lua;     # ~/.config everywhere, Windows included
  home.sessionVariables.EDITOR = "nvim";
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.file.".config/nvim" = { source = ./nvim; recursive = true; };
  winpkgs.files."%LOCALAPPDATA%/nvim" = lib.mkIf pkgs.stdenv.hostPlatform.isWindows { source = ./nvim; recursive = true; };
}
```

What home-manager produces -- files under the home directory, session
variables, `home.sessionPath`, `home.packages` -- is translated to Windows:
`%USERPROFILE%`, `HKCU\Environment`, the user `PATH`, winget. `programs.git`
above installs Git and writes `.config/git/config`. What has no Windows meaning
(the activation script, the Nix profile, systemd and launchd services) is left
unevaluated. Packages work because the winpkgs overlay annotates nixpkgs
packages with their winget id (`pkgs.git.winget.id == "Git.Git"`; the table is
`overlays/winget.nix`, grown from use) and `pkgs.winpkgs.fromWinget
"Microsoft.PowerToys"` names software winget has and nixpkgs does not. Nothing
is cross-compiled; a package without an annotation is an error that names it.

Options like those are sugar over `winpkgs.registry`, and they are tri-state:
each defaults to `null`, meaning *leave whatever is there alone*. Turning a
module on never rewrites a setting you did not name. Where the sugar is wrong,
a `winpkgs.registry` entry for the same value wins.

`nix build` turns that into a self-contained closure — a JSON desired-state
document, the declared files, and the PowerShell runtime that understands them.
`nix run` from WSL hands the closure to Windows, which converges to it:
idempotently, with one UAC prompt at most, and with every change journaled
into a generation you can roll back.

Read [DESIGN.md](DESIGN.md) for the why.

## Status

Converging a real Windows 11 desktop daily: system and home configurations,
rollback, generation GC and the `winpkgs` command are all in use. Resources:
`winpkgs/registry`, `winpkgs/registryKey`, `winpkgs/winget`, `winpkgs/file`,
`winpkgs/path`, `winpkgs/environment`. Modules over them: `winpkgs.explorer`,
`winpkgs.taskbar`, `winpkgs.theme`, `winpkgs.privacy`, `winpkgs.keyboard`,
`winpkgs.developer`.

## Using it

A machine has a **system** configuration (the machine: `HKLM`, `%ProgramData%`,
machine-scope packages, the WSL distro; applied elevated) and, per user, a
**home** configuration (`HKCU`, `%USERPROFILE%`, user-scope packages, the shell;
applied as the user, never elevated) -- the NixOS + home-manager shape. Each
keeps its own generations. In your flake:

```nix
inputs.winpkgs.url = "github:calebstewart/winpkgs";

outputs = { winpkgs, ... }: {
  windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
    modules = [ ./hosts/desktop/configuration.nix ];
  };
  # Named <Windows user name>@<host>, which is how the winpkgs command finds it.
  windowsHomeConfigurations."me@desktop" = winpkgs.lib.homeConfiguration {
    modules = [ ./hosts/desktop/home.nix ];
  };
};
```

A resource in the wrong tree -- an `HKLM` key in the home configuration, an
`%APPDATA%` path in the system one -- is an evaluation error naming the other.
The system tree speaks NixOS's names where they apply
(`environment.systemPackages`, `environment.variables`); the home tree speaks
home-manager's (below).

The configuration can also carry the machine's NixOS-WSL distro, so one host
declaration and one command cover both:

```nix
winpkgs.wsl = {
  enable = true;
  modules = [ { system.stateVersion = "26.05"; } ];   # optional extras; NixOS-WSL, flakes and git are in the base
};
```

The distro is a slim base -- just what winpkgs needs to evaluate and apply --
not a workstation; add ordinary NixOS modules for anything more.
`config.system.build.wsl` is a full nixosConfiguration (expose it under your own
`nixosConfigurations` if you like), and the closure links its toplevel as
`result/wsl`.

### Day to day: the `winpkgs` command

The first home activation installs a `winpkgs` command on Windows
(`winpkgs.cli`, on by default) and ensures PowerShell 7 is installed and current
(`winpkgs.powershell`, on by default). Set where the flake lives and everything
runs from any Windows terminal -- Windows PowerShell, pwsh or cmd:

```nix
winpkgs.cli.flake = ''%USERPROFILE%\git\stewos'';
```

Every verb names its kind, the way `nixos-rebuild` and `home-manager` are two
commands: `winpkgs system …` may prompt for UAC, `winpkgs home …` never does.

```powershell
winpkgs system switch          # WSL distro, then the machine (one UAC prompt, if anything changed)
winpkgs home switch            # this user
winpkgs system plan            # read-only, either kind
winpkgs home apply
winpkgs home generations       # each kind keeps its own; local, no WSL involved
winpkgs system rollback 3      # elevates once
winpkgs home gc -Keep 5 -OlderThan 30d   # or set winpkgs.generations.{keep,deleteOlderThan} and forget it
winpkgs home plan -Flake 'D:\src\stewos' -Home 'me@other-host' -ShowUnchanged
winpkgs shell                  # a shell in the distro, in the flake directory
winpkgs rollback --help        # options for any verb
```

### The first time, from WSL

```bash
# the machine: activate the WSL distro (if embedded), then apply elevated
nix run .#windowsConfigurations.desktop.config.system.build.toplevel

# this user: installs the winpkgs command, among other things
nix run '.#windowsHomeConfigurations."me@desktop".config.system.build.toplevel'

# either one, read-only
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- plan
```

`nix flake init -t github:calebstewart/winpkgs` scaffolds a consumer flake.

### Clean machine, no WSL yet

`nix build` the closure anywhere, commit the `result/` contents to a repo, then
on the new machine from Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/calebstewart/winpkgs/main/runtime/bootstrap.ps1 -OutFile bootstrap.ps1
.\bootstrap.ps1 -Repo https://github.com/you/config -Path closures/desktop
```

Bootstrap installs PowerShell 7 and the winget client module, clones the repo,
and applies. Only winget needs to already exist.

## Layout

```
flake.nix, lib/      windowsSystem and homeConfiguration — the darwinSystem / homeManagerConfiguration analogues
modules/common/      primitives both kinds share; the kind fixes every resource's scope
modules/system/      the machine: wsl, developer, NixOS-shaped sugar
modules/home/        one user: home.*, xdg.*, cli, powershell, explorer, taskbar, theme
overlays/            nixpkgs attribute -> winget id, pkgs.winpkgs.fromWinget
runtime/winpkgs.ps1  plan | apply | rollback | generations | gc
runtime/cli.ps1      the `winpkgs` command: system | home subcommands
runtime/WinPkgs/     the module: document, state, plan/apply/rollback, resources
runtime/bootstrap.ps1  Windows PowerShell 5.1 -> pwsh + WinGet client, then hand off
runtime/tests/       Pester, run on pwsh 7 and Windows PowerShell 5.1
example/             configuration.nix (system) and home.nix, built by `nix flake check`
template/            `nix flake init` template
```

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
