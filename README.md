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

Files and environment variables also answer to home-manager's names, so a
module can be shared with a NixOS or macOS home configuration and guarded the
way NixOS and nix-darwin modules are -- `pkgs` inside a winpkgs module is a
cross package set for Windows, so `pkgs.stdenv.hostPlatform.isWindows` is true:

```nix
{ lib, pkgs, ... }: {
  home.packages = [ pkgs.git pkgs.ripgrep pkgs.starship ];         # winget on Windows, Nix elsewhere
  home.file.".gitconfig".text = lib.generators.toGitINI me.git;   # every platform
  xdg.configFile."starship.toml".source = ./starship.toml;         # ~/.config everywhere, Windows included
  home.sessionVariables.EDITOR = "nvim";
  home.file.".config/nvim" = { source = ./nvim; recursive = true; };
  winpkgs.files."%LOCALAPPDATA%/nvim" = lib.mkIf pkgs.stdenv.hostPlatform.isWindows { source = ./nvim; recursive = true; };
}
```

`home.packages` works because the winpkgs overlay annotates nixpkgs packages
with their winget id (`pkgs.git.winget.id == "Git.Git"`; the table is
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

Slice 0: the pipeline exists end to end but has not yet converged a real
machine. Resources: `winpkgs/registry`, `winpkgs/registryKey`, `winpkgs/winget`,
`winpkgs/file`, `winpkgs/path`. Modules over them: `winpkgs.explorer`,
`winpkgs.taskbar`, `winpkgs.theme`, `winpkgs.privacy`, `winpkgs.keyboard`,
`winpkgs.developer`.

## Using it

In your flake:

```nix
inputs.winpkgs.url = "github:calebstewart/winpkgs";

outputs = { winpkgs, ... }: {
  windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
    modules = [ ./hosts/desktop-win.nix ];
  };
};
```

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

The first activation installs a `winpkgs` command on Windows (`winpkgs.cli`,
on by default) and ensures PowerShell 7 is installed and current
(`winpkgs.powershell`, on by default). Set where the flake lives and everything
runs from any Windows terminal -- Windows PowerShell, pwsh or cmd:

```nix
winpkgs.cli.flake = ''%USERPROFILE%\git\stewos'';
```

```powershell
winpkgs plan                 # what apply would change
winpkgs switch               # activate the WSL distro, then converge Windows
winpkgs apply                # Windows only
winpkgs generations          # local; no WSL involved
winpkgs rollback 3           # local; elevates once if generation 3 is machine scope
winpkgs gc -Keep 5 -OlderThan 30d   # or set winpkgs.generations.{keep,deleteOlderThan} and forget it
winpkgs plan -Flake 'D:\src\stewos#other-host' -ShowUnchanged
winpkgs shell                # a shell in the distro, in the flake directory
winpkgs rollback --help      # options for any command
```

### The first time, from WSL

From WSL:

```bash
# see what would change on Windows
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- plan

# activate the WSL distro (if embedded), then converge Windows
nix run .#windowsConfigurations.desktop.config.system.build.toplevel

# Windows only / WSL only
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- apply
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- wsl

# history and rollback (Windows side)
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- generations
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- rollback -Scope user -Generation 3
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
flake.nix, lib/      windowsSystem — the darwinSystem analogue
modules/             option schema; each module appends normalised resources
runtime/winpkgs.ps1  plan | apply | rollback | generations
runtime/WinPkgs/     the module: document, state, plan/apply/rollback, resources
runtime/bootstrap.ps1  Windows PowerShell 5.1 -> pwsh + WinGet client, then hand off
runtime/tests/       Pester
example/             configuration built by `nix flake check`
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
