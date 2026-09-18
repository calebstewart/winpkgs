# Architecture

Nix cannot run natively on Windows, and a native port is a multi-year project
before it configures a single registry key. Instead, Nix stays where it already
works -- WSL, or CI -- and evaluates a module tree into a **desired-state
document**. A small, Nix-agnostic PowerShell runtime converges the machine to
that document.

```
 your flake                              winpkgs
 +----------------------+                +-------------------------------+
 | windowsConfigurations|---imports----->| modules/   option schema      |
 |   .desktop = winpkgs |                | lib/       windowsSystem      |
 |   .lib.windowsSystem |                | runtime/   PowerShell applier |
 +----------+-----------+                +-------------------------------+
            | nix build
            v
 result/                       <- the closure
   config.json                 desired-state document
   files/                      every declared file's content
   fonts/                      every declared font's files
   runtime/                    the applier, pinned by construction
   bin/activate                wslpath + pwsh.exe ... apply
   wsl                         the NixOS-WSL distro's toplevel, with wsl.enable
```

The two halves live in one repository on purpose: the option schema and the
runtime that consumes it are one contract. The closure carries its own runtime
so schema/runtime skew is impossible -- the same reason a NixOS system
derivation bundles its own `activate` script.

```
flake.nix, lib/      windowsSystem and homeConfiguration -- the darwinSystem / homeManagerConfiguration analogues
modules/common/      primitives both kinds share; the kind fixes every resource's scope
modules/system/      the machine: wsl, developer, power, time, sudo, services, NixOS-shaped sugar
modules/home/        one user: home.*, xdg.*, cli, powershell, explorer, taskbar, theme, programs.*
overlays/            nixpkgs attribute -> winget id, pkgs.winpkgs.fromWinget; which attributes are fonts
runtime/winpkgs.ps1  plan | apply | rollback | generations | gc
runtime/cli.ps1      the `winpkgs` command: system | home subcommands
runtime/WinPkgs/     the module: document, state, plan/apply/rollback, one file per resource type
runtime/bootstrap.ps1  Windows PowerShell 5.1 -> pwsh + WinGet client, then hand off
runtime/setup.ps1    what first logon runs off the boot media: WSL, the distro, both configurations, one reboot
runtime/tests/       Pester, run on pwsh 7 and Windows PowerShell 5.1
install.ps1          bare Windows -> WSL, NixOS-WSL, your flake, applied; resumable across the reboot
docs/                this site: the generator and the hand-written pages
```

## Evaluation

Modules receive `pkgs` as a nixpkgs **cross** package set for the Windows target
(`pkgsCross.mingwW64`, or `ucrtAarch64` for `platform = "aarch64-windows"`).
That is Nix's own vocabulary for "evaluated here, for there":
`pkgs.stdenv.hostPlatform.isWindows` is true, so a module guarded the way NixOS
and nix-darwin modules are guarded means the right thing inside a Windows
configuration. The set allows unsupported and broken packages, because it is
read for names and annotations and never built; anything that must *run* while
the closure is built comes from `pkgs.buildPackages`.

A home configuration evaluates **home-manager's own modules** -- `lib/default.nix`
appends home-manager's module list with its extended `lib`, exactly as
`homeManagerConfiguration` does -- and `modules/home/home-manager.nix` carries
what they produce across: files, session variables, the PATH prefix, and the
package list. Everything else home-manager would do for a Nix profile is
filtered out.

The option surface is sorted by what it is about:

| About | Options | Precedent |
|---|---|---|
| the tool: identity, state, its own installs | `winpkgs.name`, `.kind`, `.generations`, `.prune`, `.cli`, `.powershell`, `.substitutions`, `.homes`, `.machinePackages`, `.groups` | `nix.*`, `programs.home-manager` |
| Windows, the OS being configured | `windows.explorer`, `.taskbar`, `.theme`, `.privacy`, `.keyboard`, `.developer`, `.services`; the escape hatches `windows.registry`, `.registryKeys`, `.files` beside them | nix-darwin `system.defaults.*` with `CustomUserPreferences` next to it |
| the installer that is not Nix | `winget.packages` | `homebrew.*` |
| the distro on the machine | `wsl.*` | `virtualisation.*` |
| NixOS's names, system tree | `networking.hostName`, `environment.systemPackages`, `environment.variables`, `time.*`, `security.sudo`, `fonts.packages` | NixOS |
| home-manager's names, home tree | `home.*`, `xdg.*`, `programs.*` | home-manager |

The sugar modules over the registry are tri-state and lose on purpose: every
option defaults to `null`, meaning unmanaged, and every write is `mkDefault` so
a hand-written `windows.registry` entry wins. Nothing in them emits resources
directly, so value typing, scope and deduplication stay in one place.

## The document

A flat list of typed resources. Flat rather than nested because it maps directly
onto the runtime's dispatch table; the Nix module tree is where the nesting and
ergonomics live.

```json
{
  "version": 2,
  "kind": "home",
  "name": "me@desktop",
  "settings": {
    "prune": { "winget": true, "files": true, "services": true },
    "generations": { "keep": 10, "deleteOlderThan": null },
    "substitutions": [ { "from": "/home/me", "to": "%USERPROFILE%" } ]
  },
  "resources": [
    {
      "type": "winpkgs/registry",
      "id": "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\Hidden",
      "scope": "user",
      "properties": { "key": "HKCU\\...\\Advanced", "name": "Hidden",
                      "type": "DWord", "value": 1, "restartExplorer": true }
    },
    { "type": "winpkgs/winget", "id": "BurntSushi.ripgrep.MSVC", "scope": "user",
      "properties": { "id": "BurntSushi.ripgrep.MSVC", "version": "14.1.1", "pinned": false,
                      "upgrade": false, "source": "winget", "scope": "user" } },
    { "type": "winpkgs/file", "id": "%APPDATA%\\wezterm\\wezterm.lua", "scope": "user",
      "properties": { "target": "%APPDATA%\\wezterm\\wezterm.lua", "source": "files/0-wezterm.lua" } },
    { "type": "winpkgs/font", "id": "nerd-fonts-jetbrains-mono", "scope": "user",
      "properties": { "name": "nerd-fonts-jetbrains-mono", "source": "fonts/nerd-fonts-jetbrains-mono", "scope": "user" } }
  ]
}
```

Every resource has `type`, `id` (unique, human-readable), `scope` (`user` |
`machine`) and `properties`. File and font sources are paths relative to the
document, so the closure is self-contained. Resources are applied in document
order, which the build fixes: services after everything they might run, and
activations last.

## The runtime

`runtime/winpkgs.ps1 apply -Config <path>` takes a document and converges. It
does not know or care whether the JSON came from `nix build` five seconds ago
or was committed to a repo and cloned onto a machine with no WSL. It runs on
Windows PowerShell 5.1 as well as pwsh 7, because the elevated phase may have to
run under an unpackaged host: a UAC-elevated MSIX pwsh -- what winget installs
since 7.6 -- cannot open `HKLM\SOFTWARE` for write.

Each resource type registers these functions, all taking plain hashtables:

| Function | Purpose |
|---|---|
| `Get(props, ctx)` | Observe current state. Returns `@{ exists = bool; ... }`. Never mutates. |
| `Test(props, current, ctx)` | `$true` iff `current` satisfies `props`. Pure. |
| `Set(props, current, ctx)` | Converge. Called only when `Test` is false. |
| `Remove(props, ctx)` | Optional. Delete what winpkgs put there and forget it in the ledger. Only prune calls it, so only the types it prunes have one: `winget`, `file`, `font`, `service`, `activation`. |
| `Backup(props, current, ctx, dir)` | Optional. Stash anything `Get` cannot carry (file contents) before `Set` or `Remove`. |

This is the DSC Get/Test/Set contract plus removal for what winpkgs owns. `plan`
is `Get` + `Test` over every resource, plus a `remove` for what the ledger owns
and the document no longer declares; `apply` adds `Backup` + `Set` for the ones
that fail `Test`, and `Backup` + `Remove` for the removes. What `Get` and
`Backup` saw before each change goes into the generation's journal, as a
record.

**Elevation.** A system document is applied elevated. From an unelevated
session the runtime plans first (reading `HKLM` needs no rights), and only if
something is out of state, or the configuration is not the current generation's,
launches one elevated child under an unpackaged PowerShell host, output tee'd to
a log the parent prints. One UAC prompt per apply, never per resource, and none
for applying the current configuration again when nothing has drifted. A home
document never elevates; a home apply is also the only thing that restarts
Explorer, the shell being the user's.

**Files are copied, not symlinked.** Symlinks to `\\wsl.localhost\...` need
developer mode or elevation, and break when WSL is down. Content-hash comparison
keeps copies idempotent. A file in use is moved aside into the kind's trash and
replaced, the way updaters work; the trash is emptied at the end of every apply.

## State and generations

State lives on the Windows side, never in the store, one tree per kind:

```
%ProgramData%\winpkgs\system\    the machine; written elevated, writable by administrators only
%LOCALAPPDATA%\winpkgs\home\     this user
  state.json                     ledger: { owned: { winget: [ids], files: [targets], fonts: { name: [files] }, services: [names] } },
                                 activation revisions, and `current`: the generation the kind is on
  generations\NNN\               one sequence per kind
    closure\                     the closure applied: config.json, runtime\, files\, fonts\
    manifest.json                every closure file's SHA-256, and the fingerprint they add up to
    journal.json                 [{ resource, action, before }] in apply order: the apply that created it
    journal-K.json               the same for its K-th run: going back to it, applying it again over drift
    files\                       Backup() output
```

The **ledger** records what winpkgs installed, the files it *created* (a file
that already existed when winpkgs first wrote it is managed but not owned) and
the fonts it installed. Pruning removes `owned - declared`, never anything
winpkgs did not put there itself, which is what makes package lists and file
sets declarative rather than a bootstrap script.

A **generation** is a configuration that was applied. Every apply keeps its
closure in the generation's directory, and the runtime applies the resources
from that copy. The runtime tells one closure from another by a fingerprint over
every file in it, and applying one picks its generation the way Nix moves a
profile link: the current generation's closure again converges drift and records
the run beside it; the newest generation's, after going back from it, switches
back; anything else is a new generation. `current` moves before anything is
changed, so after an apply that failed part-way, going back means going to the
generation before it. Identical files are hard-linked across generations, so an
unchanged font costs nothing per generation.

**Rollback goes to a generation.** `rollback [N]` runs generation N's own
runtime against the closure N keeps, in a child process, and N becomes current.
It is exactly an apply of N's configuration, prune included. Running the
generation's own runtime is what NixOS does with a generation's
`switch-to-configuration`, and it means a generation that uses a resource type
the installed runtime has never heard of still rolls back, with no WSL
involved.

Generations are kept by policy -- the newest N per kind, and an age -- applied
at the end of every apply and by `gc`. The current generation is never deleted.

## Decisions

The reasoning behind each of these -- PowerShell over Rust for the runtime,
5.1 compatibility, an own reconciler over DSC v3, `Microsoft.WinGet.Client` over
parsing CLI output, how services and per-user service templates are managed,
why registry keys are spelled with doubled backslashes -- is recorded decision
by decision in
[DESIGN.md](https://github.com/calebstewart/winpkgs/blob/main/DESIGN.md),
along with the roadmap.
