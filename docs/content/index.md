# winpkgs

Declarative Windows desktop configuration in the shape of nix-darwin.
**Nix evaluates, PowerShell applies.**

```nix
{
  winpkgs.name = "desktop";

  winget.packages = [ "Git.Git" "wez.wezterm" ];

  windows.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
    contextMenu = "classic";
  };
  windows.taskbar.alignment = "left";
  windows.theme.mode = "dark";
  windows.keyboard.remap.CapsLock = "LeftCtrl";

  # Anything not modelled above is still one attrset away.
  windows.registry."HKCU\\Environment".EDITOR = "nvim";

  windows.files."%USERPROFILE%/.wezterm.lua".source = ./wezterm.lua;
}
```

Nix cannot run natively on Windows, so it stays where it already works -- WSL,
or CI -- and evaluates a module tree into a desired-state document. `nix build`
turns a configuration into a self-contained closure: that document, the
declared files, and the PowerShell runtime that understands them. `nix run`
from WSL hands the closure to Windows, which converges to it idempotently, with
one UAC prompt at most. Each configuration applied is kept as a generation,
closure and all, and rolling back goes to one, as it does in NixOS and
home-manager.

A machine has a **system** configuration (the machine: `HKLM`, `%ProgramData%`,
machine-scope packages, the WSL distro; applied elevated) and, per user, a
**home** configuration (`HKCU`, `%USERPROFILE%`, user-scope packages, the
shell; applied as the user, never elevated) -- the NixOS + home-manager shape.
A home configuration evaluates **home-manager's own modules**, so a module
written for home-manager works as it is: `programs.git.enable` installs Git
through winget and writes the same git config a NixOS or macOS home gets.

## Where to start

- **[Installation](installation.html)** -- a consumer flake and the first apply
  from WSL; a bare machine with `install.ps1`; a committed closure with
  `bootstrap.ps1`.
- **[Usage](usage.html)** -- the `winpkgs` command, the two configuration
  trees, packages and fonts, home-manager modules on Windows, generations.
- **[Architecture](architecture.html)** -- what a closure is, what the runtime
  does with it, and how state, elevation and rollback work.
- **[Options](options/index.html)** -- every option the system and home trees
  declare, searchable in one place.
- **[Packages](catalog/index.html)** -- the nixpkgs names the overlay knows how
  to install on Windows, and what each one means there.
- **[Library](lib/index.html)** -- `winpkgs.lib.windowsSystem` and
  `homeConfiguration`, and the `pkgs.winpkgs.*` helpers modules see.
- **[Flake](flake/index.html)** -- outputs and inputs.

This site is generated from the flake itself. The option reference is evaluated
out of the two module trees, the package catalog out of the overlay's tables,
and the library reference out of the doc-comments in `lib/` and `overlays/`.
Nothing on it is maintained by hand, so nothing on it can drift from the code;
[how it is generated](generating-docs.html) is documented too.

## Status

Converging a real Windows 11 desktop daily: system and home configurations,
rollback, generation GC and the `winpkgs` command are all in use. The runtime
speaks these resources: `winpkgs/registry`, `winpkgs/registryKey`,
`winpkgs/winget`, `winpkgs/file`, `winpkgs/path`, `winpkgs/environment`,
`winpkgs/font`, `winpkgs/service`, `winpkgs/scheduledTask`,
`winpkgs/activation`, and one each for the wallpaper, pointer, power plan, time
zone, NTP client and computer name. The modules over them are the
[options reference](options/index.html).

Read [DESIGN.md](https://github.com/calebstewart/winpkgs/blob/main/DESIGN.md)
for the why, decision by decision.
