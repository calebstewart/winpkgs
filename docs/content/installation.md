# Installation

There are three ways in, and they end in the same place: a Windows machine
running your configuration, with a `winpkgs` command on it that keeps it there.

- **A flake and a WSL distro** you already have: add winpkgs as an input and
  apply from WSL once. The usual path on a machine that is already set up.
- **A machine with nothing on it**: `install.ps1` takes a fresh Windows install
  to a machine running your configuration, in one command, WSL included.
- **A committed closure and no WSL at all**: `bootstrap.ps1` applies a closure
  built elsewhere. The break-glass path.

Whichever way, Nix does the evaluating and PowerShell does the applying. Only
winget has to already be there, which on Windows 11 it is.

## A consumer flake

winpkgs is consumed as a flake input, the way nix-darwin is. In your flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    winpkgs.url = "github:calebstewart/winpkgs";
    winpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { winpkgs, ... }: {
    # The machine: applied elevated. `winpkgs system switch`.
    windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
      modules = [ ./hosts/desktop/configuration.nix ];
    };

    # One user on it: applied as that user. `winpkgs home switch`.
    # Named <Windows user name>@<host>, which is how the winpkgs command finds it.
    windowsHomeConfigurations."me@desktop" = winpkgs.lib.homeConfiguration {
      modules = [ ./hosts/desktop/home.nix ];
    };
  };
}
```

`nix flake init -t github:calebstewart/winpkgs` scaffolds exactly this, with a
small system configuration and a small home configuration beside it. The two
evaluators are documented under [Library](lib/index.html); every option the
modules accept is under [Options](options/index.html).

A resource in the wrong tree -- an `HKLM` key in the home configuration, an
`%APPDATA%` path in the system one -- is an evaluation error naming the other.
The system tree speaks NixOS's names where they apply
(`environment.systemPackages`, `environment.variables`, `time.timeZone`); the
home tree speaks home-manager's.

Some winget packages only have a machine-wide installer (Alacritty, LLVM; most
MSI and NSIS ones), which a home configuration cannot run since it never
elevates. A home still declares them in `home.packages`; the overlay records
the scope; and the system configuration that lists the home installs them,
elevated, the way `home-manager.useUserPackages` works on NixOS:

```nix
windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
  modules = [
    ./hosts/desktop/configuration.nix
    { winpkgs.homes = [ self.windowsHomeConfigurations."me@desktop" ]; }
  ];
};
```

Apply the system first, then the home.

### The first time, from WSL

From a WSL distro with Nix and flakes -- NixOS-WSL, or any distro with the Nix
installer -- in the directory of your flake:

```bash
# the machine: activate the WSL distro (if embedded), then apply elevated
nix run .#windowsConfigurations.desktop.config.system.build.toplevel

# this user: installs the winpkgs command, among other things
nix run '.#windowsHomeConfigurations."me@desktop".config.system.build.toplevel'

# either one, read-only
nix run .#windowsConfigurations.desktop.config.system.build.toplevel -- plan
```

`nix build` of the same attribute is the closure on its own: `result/` holds
`config.json` (the desired-state document), `files/`, `runtime/` and
`bin/activate`, and `activate plan|apply|switch` runs the runtime on the Windows
side through `pwsh.exe`. The first home activation installs the `winpkgs`
command, after which nothing needs a WSL shell -- see [Usage](usage.html).

The configuration can also carry the machine's NixOS-WSL distro, so one host
declaration and one command cover both:

```nix
wsl = {
  enable = true;
  modules = [ { system.stateVersion = "26.05"; } ];   # optional extras; NixOS-WSL, flakes and git are in the base
};
```

The distro is a slim base -- just what winpkgs needs to evaluate and apply --
not a workstation; add ordinary NixOS modules for anything more.
`config.system.build.wsl` is a full nixosConfiguration (expose it under your own
`nixosConfigurations` if you like), and the closure links its toplevel as
`result/wsl`. `switch` activates the distro first, then the machine.

## A machine with nothing on it

`install.ps1` takes a Windows install that has just finished setting itself up
to a machine running your configuration, in one command from Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/calebstewart/winpkgs/main/install.ps1 -OutFile install.ps1
.\install.ps1 https://github.com/you/config
```

It installs PowerShell 7 and the winget client module, enables the WSL and
Virtual Machine Platform features, imports the latest NixOS-WSL release as a
distro, clones your flake to `%USERPROFILE%\git\<repo>` -- with `nix run
nixpkgs#git` from inside the distro, so nothing reaches Windows that your
configuration did not ask for -- and applies the system configuration and then
your home one. Only winget has to already be there.

Run it as yourself rather than elevated: it elevates the two phases that need
it, and the system apply prompts for UAC on its own. A home configuration is
never applied elevated.

Enabling the WSL feature costs one reboot. The script records how far it got
under `%LOCALAPPDATA%\winpkgs\install` and registers itself in `RunOnce`, so the
run continues at the next sign-in -- and re-running the same command after any
failure carries on from the phase that failed rather than starting over.

A flake already on the machine works the same way, and the configurations to
apply can be named when the flake holds several and none is named after this
computer:

```powershell
.\install.ps1 D:\src\config -System desktop -Home 'me@desktop'
.\install.ps1 github:you/config -Ref develop -Destination C:\src\config
.\install.ps1 https://github.com/you/config -SkipHome -Yes    # system only, no prompts
```

`-Destination` is where the flake ends up, and it is a Windows path because that
is what {option}`winpkgs.cli.flake` is: set the option to the same value and the
`winpkgs` command works from any terminal afterwards.

## Clean machine, a committed closure

Without a flake to evaluate -- `nix build` the closure anywhere and commit the
`result/` contents to a repo -- `bootstrap.ps1` applies one with no WSL at all:

```powershell
irm https://raw.githubusercontent.com/calebstewart/winpkgs/main/runtime/bootstrap.ps1 -OutFile bootstrap.ps1
.\bootstrap.ps1 -Repo https://github.com/you/config -Path closures/desktop
```

Bootstrap installs PowerShell 7 and the winget client module, clones the repo,
and applies. Only winget needs to already exist. Commit the closure *without*
its `wsl` link -- that is a whole NixOS system.

This exists so that a wedged WSL cannot lock you out of converging the host: the
runtime does not know or care whether the document came from `nix build` five
seconds ago or was committed to a repo and cloned onto a machine with no WSL.
