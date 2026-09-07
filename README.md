# winpkgs

Declarative Windows desktop configuration in the shape of nix-darwin.
**Nix evaluates, PowerShell applies.**

```nix
{
  winpkgs.name = "desktop";

  winpkgs.packages.winget = [ "Git.Git" "wez.wezterm" ];

  winpkgs.registry."HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced" = {
    Hidden = 1;
    HideFileExt = 0;
  };

  winpkgs.files."%USERPROFILE%/.wezterm.lua".source = ./wezterm.lua;
}
```

`nix build` turns that into a self-contained closure — a JSON desired-state
document, the declared files, and the PowerShell runtime that understands them.
`nix run` from WSL hands the closure to Windows, which converges to it:
idempotently, with one UAC prompt at most, and with every change journaled
into a generation you can roll back.

Read [DESIGN.md](DESIGN.md) for the why.

## Status

Slice 0: the pipeline exists end to end but has not yet converged a real
machine. Resources: `winpkgs/registry`, `winpkgs/winget`, `winpkgs/file`.

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

From WSL:

```bash
# see what would change
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- plan

# converge
nix run .#windowsConfigurations.desktop.config.system.build.toplevel

# history and rollback
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
