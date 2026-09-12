# winpkgs — design

Declarative Windows desktop configuration in the shape of nix-darwin: **Nix
evaluates, PowerShell applies.**

Nix cannot run natively on Windows, and a native port is a multi-year project
before it configures a single registry key (that road was explored and
abandoned). Instead, Nix stays where it already works — WSL, or CI — and
evaluates a module tree into a **desired-state document**. A small,
Nix-agnostic PowerShell runtime converges the machine to that document.

## Goals

- Boot a clean Windows install and return to a known state with one command.
- Idempotent apply: running it twice changes nothing the second time.
- Declarative in the strong sense: something removed from the configuration is
  removed from the machine (for the things winpkgs installed).
- Readable configuration that shares values with an existing Nix flake
  (`stewos`): the same username, git identity, fonts, theme and aliases feed
  NixOS, nix-darwin and Windows.
- Best-effort rollback via a change journal.

## Non-goals

- A content-addressed store, generations in the Nix sense, purity or build
  isolation. Windows configuration is mutation of shared global state; winpkgs
  converges it (Terraform/Ansible semantics), it does not build it.
- Managing the opaque tier: Start menu pins, taskbar pins, default browser,
  Store sign-in, Windows Hello. These resist automation and belong in a manual
  checklist rather than a fight.

## Architecture

```
 stewos (consumer flake)                 winpkgs (this repo)
 +----------------------+                +-------------------------------+
 | windowsConfigurations|---imports----->| modules/   option schema      |
 |   .desktop = winpkgs |                | lib/       windowsSystem      |
 |   .lib.windowsSystem |                | runtime/   PowerShell applier |
 +----------+-----------+                +-------------------------------+
            | nix build
            v
 result/                       <- the "system closure"
   config.json                 desired-state document
   files/                      every declared file's content
   runtime/                    the applier, pinned by construction
   bin/activate                wslpath + pwsh.exe ... apply
```

The two halves live in one repository on purpose: the option schema and the
runtime that consumes it are one contract. The closure carries its own runtime
so schema/runtime skew is impossible — the same reason a NixOS system
derivation bundles its own `activate` script.

### The WSL distro is part of the machine

`wsl.enable` makes the Windows configuration also carry the NixOS
configuration of the machine's WSL distro. winpkgs calls `nixosSystem` itself
with the NixOS-WSL module and a slim base -- flakes enabled and `git`, which is
all winpkgs needs from the distro in order to evaluate and apply -- plus the
consumer's optional `wsl.modules`, `specialArgs` and `pkgs`. The whole
evaluation is exposed as `config.system.build.wsl` -- a real nixosConfiguration,
so a consumer can surface it under its own `nixosConfigurations` for
`nixos-rebuild` and docs. The distro's toplevel is linked into the closure as
`result/wsl`, which is what makes one `nix build` build both halves.

The distro is deliberately not a workstation. It is the evaluator that lives on
the Windows machine; the machine the person sits at is Windows. A consumer that
wants more in the distro adds modules; nothing is imposed.

This is the NixOS `containers.<name>` / nix-darwin-embeds-home-manager pattern:
one module system evaluating another. It exists so a clean machine needs one
configuration and one command (`activate switch`: activate the distro, then
converge Windows), not two configurations kept in step by hand. Activation is
deliberately sequential and explicit -- WSL first, since it is the evaluator;
Windows second -- rather than one side's activation hooking the other's.

### The `winpkgs` command installs itself

`winpkgs.cli.enable` (default on) makes the apply install a `winpkgs` command
into `%LOCALAPPDATA%\winpkgs\bin`, put that directory on the user's `PATH`, and
drop a copy of the runtime plus a `cli.json` of defaults (`flake`, `name`,
`distro`) beside it -- all as ordinary `windows.files` / `home.sessionPath`
resources, so they are versioned with the closure and refreshed by every apply.
This is `programs.home-manager.enable`: the tool that manages the system is part
of what it manages.

After the first activation from WSL, nothing needs a WSL shell. Every verb
names its kind -- `winpkgs system …` or `winpkgs home …` -- because a command
that did "both" would make elevation contextual again, which the split exists
to prevent; `nixos-rebuild` and `home-manager` are two commands for the same
reason. `winpkgs system|home plan|apply|switch|build` translate the configured
Windows flake path with `wslpath` *inside the distro* and run `nix run
<path>#…toplevel -- <cmd>` there. `winpkgs system|home generations|rollback|gc`
run the installed runtime locally, without WSL at all -- so a wedged distro
cannot stop a Windows rollback. Only `config`, `shell` and `help` take no kind.

`winpkgs.cli.flake` is the analogue of `programs.nh.flake`: the configuration
states where it lives.

### `pkgs` targets Windows; a shared surface carries home-manager's names

Modules receive `pkgs` as a nixpkgs **cross** package set for the Windows
target (`pkgsCross.mingwW64`, or `ucrtAarch64` for `platform =
"aarch64-windows"`). That is Nix's own vocabulary for "evaluated here, for
there": `pkgs.stdenv.hostPlatform.isWindows` is true and `isLinux`/`isDarwin`
are false, so a module guarded the way NixOS and nix-darwin modules are guarded
-- `lib.mkIf pkgs.stdenv.hostPlatform.isLinux` -- means the right thing inside a
Windows configuration. Nothing new for a module author to learn. The one
discipline is the cross one: anything that must *run* while the closure is
built (`writeText`, `runCommand`, `jq`) comes from `pkgs.buildPackages`.

On top of that, a home configuration **evaluates home-manager's own modules**
(`lib/default.nix` appends home-manager's module list, with its extended `lib`,
exactly as `homeManagerConfiguration` does, `useNixpkgsModule = false` so the
Windows `pkgs` is the one they see). `programs.*`, `home.file`, `xdg.*`,
`home.sessionVariables`, `home.sessionPath`, `home.packages` are therefore
home-manager's real options, not look-alikes, and a module written for
home-manager evaluates unchanged. home-manager knows nothing about Windows; what
it produces is a set of files relative to a home directory, environment
variables, a PATH prefix and a package list, and `modules/home/home-manager.nix`
carries exactly those four across:

| home-manager | Windows |
|---|---|
| `home.file` (fed by `xdg.configFile` & co.) | `windows.files` under `%USERPROFILE%`, `%APPDATA%` or `%LOCALAPPDATA%` |
| `home.sessionVariables` | `HKCU\Environment` |
| `home.sessionPath` | the user `PATH` |
| `home.packages` | winget, through the overlay's annotations; fonts installed per user from their files |

### Fonts are packages, installed from their files

NixOS has `fonts.packages`; home-manager has no font option at all -- a font
is an ordinary member of `home.packages`, and fontconfig finds it in the
profile. winpkgs keeps both shapes. A font package is data (fetched, unpacked,
copied to `share/fonts`), so it builds on the Windows cross set like anywhere
else, and its files travel in the closure as `windows.files` do, flattened into
`fonts/<package>/`. On the machine a font is a file in the scope's fonts
directory plus a value under the `Fonts` key -- per user in
`%LOCALAPPDATA%\Microsoft\Windows\Fonts` and `HKCU`, machine-wide in
`%WINDIR%\Fonts` and `HKLM` -- and the `winpkgs/font` resource does both, one
resource per package, then `AddFontResource` and a `WM_FONTCHANGE` broadcast so
the font is usable without signing out.

What tells a font in `home.packages` apart from a program that needs a winget
id is the overlay's `isFont` mark (`overlays/fonts.nix`, and every member of
`nerd-fonts`; `pkgs.winpkgs.font pkg` for one the table lacks). The mark is an
evaluation-time fact on purpose: the alternative, treating "no winget mapping"
as "must be a font" and finding out at build time, would send a stray
`pkgs.htop` off to cross-compile for Windows before failing. A system's
`fonts.packages` needs no mark; being listed there is the declaration, and the
closure build refuses a package with nothing under `share/fonts`.

winget's own font support (`InstallerType: font`, a `winget-font` source) is
real but not usable yet -- the source is empty and closed to submissions, and
the command is still gated as experimental -- so fonts do not go through the
package manager. Nothing in the document format precludes that later.

The home directory is a fiction, `/home/<user>`: home-manager needs an absolute
POSIX path to normalise targets against (its option type insists on a leading
slash, so the real `C:/Users/<user>` cannot be the value), and on the way out
any target, variable or PATH entry that starts with it or with `$HOME` becomes
`%USERPROFILE%`, or `%APPDATA%` / `%LOCALAPPDATA%` for the AppData subtrees.

**XDG on Windows is the AppData split.** Programs fall into two camps there:
those that honour `XDG_CONFIG_HOME` (Neovim, git, starship, wezterm) follow the
variable wherever it points, and those that do not (alacritty, bat, helix --
anything on Rust's `dirs::config_dir`) read `%APPDATA%` regardless. So the XDG
directories default to where the second camp looks, and `xdg.enable` defaults
to true so the variables bring the first camp along: `configHome` is
`%APPDATA%`, `dataHome` and `stateHome` are `%LOCALAPPDATA%`, `cacheHome` is
`%LOCALAPPDATA%\Temp` -- Roaming for settings, Local for data and caches, the
Known Folder convention. `programs.starship` therefore sets `STARSHIP_CONFIG` to
`%APPDATA%\starship.toml` and alacritty finds `xdg.configFile."alacritty/…"`
without being told. `~/.config`, the first cut, was only ever right for the
first camp. All of it is `mkDefault`, so a host may put it back. File
*contents* are handled on the machine: the
document carries `substitutions` (`winpkgs.substitutions`), and the runtime
replaces the placeholder in every text file it writes with the real profile
directory, forward slashes, `C:/Users/<user>`, comparing after substitution so
nothing is rewritten needlessly. A module that writes
`${config.home.homeDirectory}/.ssh/id_ed25519` into its git config therefore
means the right file on every platform, which is the whole point of sharing it. What has no Windows
meaning is left unevaluated: the activation script, the Nix profile, systemd and
launchd services, news, the manual. What home-manager adds *for* the Nix profile
(man-db, the manual, `.cache/.keep`, the session-variables script) is filtered
out; `onChange` hooks are a warning; a target outside the home directory is an
error pointing at `windows.files`. `winpkgs.cli` is `programs.home-manager`.

The real prize is `programs.git.enable = true` installing Git through winget
*and* writing the same git config a NixOS or macOS home gets, from one
module. `home.file` with `text` builds through home-manager's own
`pkgs.writeTextFile` on the cross set; that works because writing a file needs
nothing from the target platform.

`home.packages` is aligned through the **winpkgs overlay** on the cross set.
nixpkgs is the only package namespace a shared module can speak, and winget is
the only installer Windows has, so the overlay bridges them: `pkgs.git` carries
`winget = { id = "Git.Git"; }` from a table (`overlays/winget.nix`) of names
verified against the winget source and grown from use; `null` records "no
Windows build" so the error can say so; `pkgs.winpkgs.fromWinget "Publisher.Id"`
is a stub derivation for software winget has and nixpkgs does not. The cross set
is instantiated with `allowUnsupportedSystem`, so `pkgs.neovim` *evaluates* on
the Windows platform -- it is read for its annotation, never built. This is the
Windows stand-in for what `nixpkgs-darwin` gives nix-darwin: a `pkgs` whose
names mean something on the target. The set also allows broken packages, for
the same reason it allows unsupported systems: nixpkgs' verdict on whether
`python3` *would build* for Windows is irrelevant to a set that is never built,
and a module that so much as mentions it must evaluate. What genuinely cannot
reach Windows is a **store path inside a file** -- a home-manager module that
wraps a Nix-built program (nixvim, a wrapped shell) writes where its plugins and
providers live into its own config -- and the closure build refuses such a file
by name, since there is no Nix store on the machine for it to point into. The
translation module still reads packages for `name` and `winget` only, never
comparing them with `==`.

### The option surface is sorted by what it is about

`nixpkgs.*` configures nixpkgs and `nix.*` configures Nix; neither holds
`services.openssh`. winpkgs keeps the same discipline:

| About | Options | Precedent |
|---|---|---|
| the tool: identity, state, its own installs | `winpkgs.name`, `.kind`, `.generations`, `.prune`, `.cli`, `.powershell`, `.substitutions`, `.homes`, `.machinePackages` | `nix.*`, `programs.home-manager` |
| Windows, the OS being configured | `windows.explorer`, `.taskbar`, `.theme`, `.privacy`, `.keyboard`, `.developer`; the escape hatches `windows.registry`, `.registryKeys`, `.files` beside them | nix-darwin `system.defaults.*` with `CustomUserPreferences` next to it |
| the installer that is not Nix | `winget.packages` | `homebrew.*` |
| the distro on the machine | `wsl.*` | `virtualisation.*` |
| NixOS's names, system tree | `networking.hostName`, `environment.systemPackages`, `environment.variables`, `environment.path`, `security.sudo` | NixOS |
| home-manager's names, home tree | `home.*`, `xdg.*`, `programs.*` | home-manager |

The first cut had everything under `winpkgs.*`, which read as "the tool owns
the OS". The old names remain as `mkRenamedOptionModule` aliases, warning on
use, until no consumer needs them. `winpkgs.environment.*` survives as the
internal primitive both trees write to; nothing user-facing names it.

### Sugar modules are tri-state and lose on purpose

`windows.explorer`, `windows.taskbar`, `windows.theme`, `windows.privacy`,
`windows.keyboard` and `windows.developer` are ergonomics over
`windows.registry` -- the way NixOS wraps a config file. Nothing in them emits
`winpkgs.resources` directly, so value typing, scope and deduplication stay in
one place.

Two rules make them safe on a machine that already exists:

**Every option defaults to `null`, meaning unmanaged.** A NixOS module can own
a config file outright. A Windows registry arrives carrying years of settings
someone chose by hand, so "no opinion" has to mean *write nothing* rather than
*write the upstream default*. Turning a module on never rewrites a setting you
did not name. The cost is that `null` is spoken for, so there is no sugar for
*deleting* a value: that stays a raw `windows.registry.<key>.<name> = null`.

**Sugar writes at `mkDefault`, so a hand-written entry wins.** `windows.registry`
is the escape hatch, and an escape hatch that loses to the thing it is escaping
is not one. Two sugar modules that disagreed would still be an evaluation error,
which is the collision worth erroring on because both sides are winpkgs' fault.
The priority goes on the *leaf* value: at the key level the module system drops
the whole attrset, siblings included, as soon as anything else defines that key.

The settings a module writes are a table, one entry declaring both the option
and the value it maps to, so the two cannot drift apart. Some settings resist
this and are named as non-goals in the modules themselves: taskbar auto-hide is
a byte inside the packed `StuckRects3` blob, and wallpaper needs a
`SystemParametersInfo` call rather than a registry write.

### The runtime is Nix-agnostic

`runtime/winpkgs.ps1 apply -Config <path>` takes a JSON document and converges.
It does not know or care whether the JSON came from `nix build` five seconds
ago or was committed to a repo and cloned onto a machine with no WSL. Both
bootstrap paths therefore work with the same code:

- **WSL-first (mirrors macOS).** OOBE -> WSL + NixOS-WSL -> clone stewos ->
  `nixos-rebuild switch` for the distro -> `nix run .#...toplevel` for the
  host. The host apply then takes over managing WSL itself.
- **Committed closure (break-glass).** `nix build` in CI, commit the closure,
  `bootstrap.ps1 -Repo ... -Path ...` on a machine with nothing but winget.
  This exists so a wedged WSL cannot lock you out of converging the host.
  Commit the closure *without* its `wsl` link -- that is a whole NixOS system.

## Document format

A flat list of typed resources. Flat rather than nested because it maps
directly onto the runtime's dispatch table and leaves the door open to
translating into DSC v3 documents later; the Nix module tree is where the
nesting and ergonomics live.

```json
{
  "version": 1,
  "name": "desktop",
  "settings": { "prune": { "winget": true } },
  "resources": [
    {
      "type": "winpkgs/registry",
      "id": "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\Hidden",
      "scope": "user",
      "properties": { "key": "HKCU\\...\\Advanced", "name": "Hidden",
                      "type": "DWord", "value": 1, "restartExplorer": true }
    },
    { "type": "winpkgs/winget", "id": "Git.Git", "scope": "user",
      "properties": { "id": "Git.Git", "version": null, "source": "winget", "scope": null } },
    { "type": "winpkgs/file", "id": "%APPDATA%\\wezterm\\wezterm.lua", "scope": "user",
      "properties": { "target": "%APPDATA%\\wezterm\\wezterm.lua", "source": "files/0-wezterm.lua" } },
    { "type": "winpkgs/font", "id": "nerd-fonts-jetbrains-mono", "scope": "user",
      "properties": { "name": "nerd-fonts-jetbrains-mono", "source": "fonts/nerd-fonts-jetbrains-mono", "scope": "user" } }
  ]
}
```

Every resource has `type`, `id` (unique, human-readable), `scope`
(`user` | `machine`) and `properties`. File and font sources are paths
relative to the document, so the closure is self-contained; a font's source is
a directory, and the runtime installs whatever font files it finds there.

## Resource contract

Each resource type registers these functions, all taking plain hashtables:

| Function | Purpose |
|---|---|
| `Get(props, ctx)` | Observe current state. Returns `@{ exists = bool; ... }`. Never mutates. |
| `Test(props, current, ctx)` | `$true` iff `current` satisfies `props`. Pure. |
| `Set(props, current, ctx)` | Converge. Called only when `Test` is false. |
| `Restore(props, before, ctx)` | Undo: put the resource back to a `before` captured by `Get`. |
| `Backup(props, current, ctx, dir)` | Optional. Stash anything `Get` cannot carry (file contents) before `Set`. Returns extra keys merged into `before`. |

This is the DSC Get/Test/Set contract plus an explicit inverse. `plan` is
`Get` + `Test` over every resource; `apply` adds `Backup` + `Set` for the ones
that fail `Test`.

## Elevation

A system document is applied elevated. From an unelevated session the runtime
plans first (reading `HKLM` needs no rights), and only if something is out of
state launches **one** elevated child under an unpackaged PowerShell host
(`-Verb RunAs`, hidden window, output tee'd to a log the parent prints). One UAC
prompt per apply, never per resource, and none for a no-op apply. Rolling back
or garbage-collecting system generations elevates the same way. A home document
never elevates; a home apply is also the only thing that restarts Explorer, the
shell being the user's.

## State and rollback

State lives on the Windows side, never in the store, one tree per kind:

```
%ProgramData%\winpkgs\system\    the machine; written elevated
%LOCALAPPDATA%\winpkgs\home\     this user
  state.json                     ledger: { owned: { winget: [ids], files: [targets], fonts: { name: [files] }, services: [names] } }
  generations\NNN\               one sequence per kind
    journal.json                 [{ resource, action, before }] in apply order
    config.json                  the document that was applied
    files\                       Backup() output
```

The **ledger** records what winpkgs installed (`owned.winget`), the files it
*created* (`owned.files` -- a file that already existed when winpkgs first wrote
it is managed but not owned) and the fonts it installed (`owned.fonts`, each
with the file names it put in the fonts directory, since the closure no longer
carries them once the package has left the configuration). Pruning removes
`owned - declared`, never anything winpkgs did not put there itself. That is what makes package lists and file
sets declarative rather than a bootstrap script, and it is the same rule
home-manager follows for files that leave a configuration. `winpkgs.prune.*`
switches each kind off.

Generations are kept by policy, not forever: `winpkgs.generations.keep` (the
newest N per scope, untouchable whatever their age) and `deleteOlderThan` are
applied at the end of every apply, and `winpkgs system|home gc` does the same by hand.
Deleting a generation deletes the backups behind its rollback.

A **generation** is one apply that changed at least one resource. Generations
are numbered in one sequence across both scopes (the counter lives in the user
state directory, which the elevated child -- the same user -- can write too),
so a number identifies a generation by itself. `rollback N` finds the scope
from the number and replays `Restore` over that journal in reverse.
Faithful for registry and files; best-effort for packages (reinstall the
previous version if known, otherwise uninstall). The journal is written
incrementally so a crash mid-apply still leaves a usable partial generation.

This is not Nix rollback. It is the achievable 70%, and reimage-from-clean is
the other 30%.

## Decisions

**PowerShell for the runtime, not Rust.** Native registry/COM/WMI/policy
access, ships inside the closure as text with no cross-compilation, testable
with Pester on a hosted Windows runner. The resource contract is
language-neutral if this ever changes.

**The runtime runs on Windows PowerShell 5.1 as well as pwsh 7, and the
elevated phase uses an unpackaged host.** Found the hard way: a UAC-elevated
MSIX-packaged pwsh cannot open `HKLM\SOFTWARE` for write or delete registry
keys -- even the raw .NET API is refused -- while it *can* set values in
existing keys, which is how the failure hides (the first machine-scope apply
created the key and died writing the value). winget installs the MSIX by
default since 7.6 and only the MSIX from 7.7, so "use the MSI" is not a fix.
The machine-scope child therefore runs under this pwsh only if it is
unpackaged, else an MSI/zip pwsh in Program Files, else Windows PowerShell
5.1, which every machine has. That is why the runtime avoids PS7-only syntax
and polyfills `ConvertFrom-Json -AsHashtable`, and why CI runs the suite on
both hosts. The `winpkgs` CLI itself still wants pwsh 7 and is launched via a
5.1-compatible shim.

**Own reconciler first, DSC v3 later if it earns it.** DSC v3 (GA 2025, v3.2
April 2026) is the natural engine for this and its resource contract is what
ours mirrors. But cross-cutting concerns — restart Explorer once at the end,
prune-by-ledger, the generation journal — sit outside DSC's document model,
and the desktop-settings resource catalogue is thin enough that custom
resources would be needed anyway. Because the Nix side emits a flat typed
list, translating to a DSC document is a later, additive step.

**winget via `Microsoft.WinGet.Client`, not by parsing CLI output.** The
module returns objects; `winget list` output is a formatted table. Bootstrap
installs the module.

**Files are copied, not symlinked.** Symlinks to `\\wsl.localhost\...` need
developer mode or elevation, and break when WSL is down. Content-hash
comparison keeps copies idempotent.

**`security.sudo` borrows the NixOS name for the half of it Windows has.**
Sudo for Windows answers one of the questions `security.sudo` answers -- may a
user elevate a command from an unelevated console -- and none of the rest,
because it has no sudoers file: it elevates through UAC to the caller's own
administrator token and cannot run anything as another user. So `enable`
carries over, and `wheelNeedsPassword`, `extraRules`, `execWheelOnly` and
`package` are questions this sudo does not have rather than gaps in the
mapping. The Windows-only remainder -- `security.sudo.mode`, which console the
elevated process gets and whether the unelevated one may type at it -- sits in
the same tree the way `power.fastStartup` sits among nix-darwin's names. Where
the two rules collide, the local one wins: `enable` is tri-state though NixOS'
is `true` by default, because sudo is off on a fresh Windows and turning it on
is a choice this tool does not make for you.

**Services are read from the registry and changed through the SCM's API.**
`windows.services.<name>` (system tree) declares a service -- its command line,
start type, account, failure actions -- and `winpkgs/service` creates it or
brings an existing one into line. Reading the service's key needs no
elevation, so a plan stays unelevated; writing goes through
`CreateService`/`ChangeServiceConfig`, compiled once per process like the
other P/Invokes, because `sc.exe create ... binPath= "\"C:\Program Files\...\""`
depends on embedded quotes that Windows PowerShell 5.1 -- a host the elevated
phase may run under -- strips from a native command's arguments. Services
winpkgs created are owned (`owned.services`) and pruned like files; a service
that was already there is managed and never deleted. A service's type is not
changed in place.

`type = "userOwn"` is a per-user service template: Windows starts an instance,
`<name>_<suffix>`, in every session that signs in, as that user -- how a user
service manager such as steward is
hosted without a Run key. Instances copy the template when they are created
and never again, so the resource changes every existing instance along with
it, and creating a template starts nothing before the next sign-in.
`restartTriggers` borrows NixOS's name and meaning: a hash of them is kept
beside the service (`WinPkgsRevision`, a value the SCM ignores), and when it
changes, whatever runs the service -- the service, or every running instance
of a template -- is restarted once the new definition is in place. For
steward that restart is a detach and an adoption, so its services carry on.

**Registry keys are double-quoted with doubled backslashes.** The first draft
used indented strings (`''HKCU\Software\...''`) as attribute names; Nix does
not allow that — attribute names may only be `"..."` or `${...}`. Substituting
`/` for `\` was rejected because real keys contain slashes
(`...\Content Type\application/json`). File targets, by contrast, may use
forward slashes since Win32 accepts them, so `windows.files` keys stay readable.

## System and home are separate configurations

A machine has one **system configuration** (`windowsConfigurations.<host>`,
`winpkgs.lib.windowsSystem`) and, per user, a **home configuration**
(`windowsHomeConfigurations."<user>@<host>"`, `winpkgs.lib.homeConfiguration`)
-- the NixOS + home-manager shape, and nix-darwin's. They are separate module
trees (`modules/system`, `modules/home`) over shared primitives
(`modules/common`), and the kind fixes the scope of every resource:

| | system | home |
|---|---|---|
| owns | `HKLM`, `%ProgramData%`, machine-scope winget, the WSL distro | `HKCU`, `%USERPROFILE%`, user-scope winget, the shell, the `winpkgs` command |
| applied | elevated, by construction; one UAC prompt, only if something changed | as the user; never elevates |
| sugar | NixOS's names: `environment.systemPackages`, `environment.variables` | home-manager's names: `home.*`, `xdg.*` |
| state | `%ProgramData%\winpkgs\system\`, its own generation sequence | `%LOCALAPPDATA%\winpkgs\home\`, its own |
| command | `winpkgs system ...` | `winpkgs home ...` |

Modules that span both hives (`windows.privacy`, `windows.keyboard`) are
imported by both trees and declare only the half whose keys belong there, so
`windows.privacy.telemetry` exists in a system configuration and
`windows.privacy.advertisingId` in a home one. A resource that lands in the
wrong tree -- an `HKLM` key in a home configuration, an `%APPDATA%` path in a
system one, a `scope = "machine"` package in a home one -- is an evaluation
error naming the other tree. That one rule replaced every scope heuristic the
runtime used to apply per resource.

Why it was worth a refactor: **elevation stopped being a contextual check** --
"does this need UAC" is answered by which configuration is being applied -- and
**home-manager compatibility became well-defined** -- a home-manager module can
only ever be valid in the home tree, and keeping system options out of it is
what lets its names mean what they mean on Linux and macOS. winget's own
`--scope user|machine` maps onto the split directly: a home configuration passes
`user`, so a machine-only installer fails with "no applicable installer" rather
than a home apply quietly prompting for UAC.

That failure has a proper answer, because which scope an installer supports is
a fact about the *package*, not about who wants it. The overlay table records
it (`alacritty = { id = "Alacritty.Alacritty"; scope = "machine"; }`;
`fromWinget` takes the same form), and a home configuration that finds a
machine-scope package in `home.packages` does not install it: it exports the
id on the read-only `winpkgs.machinePackages`, and the system configuration
that lists the home in `winpkgs.homes` installs it, elevated, with machine
scope. This is `home-manager.useUserPackages` -- the user declares, the system
installs -- and it keeps shared modules shared: `home.packages = [ pkgs.alacritty ]`
means the same thing on NixOS, macOS and Windows, and only the overlay and the
host's `homes` list know that Windows needs help. The mirror case, a user-only
installer in `environment.systemPackages`, is an assertion. Apply order
follows: system, then home.

Standalone home configurations only, for now. Embedding a user's home
configuration in the system one (`home-manager.users.<name>`-style) is possible
for the invoking user and left for later. The document carries `kind` (format
version 2); the runtime keeps state per kind and migrated the pre-split
per-scope directories on first use.

## Roadmap

| Slice | Scope |
|---|---|
| **0** | This scaffold: `windowsSystem`, registry/winget/file modules, plan/apply/rollback, bootstrap, CI. |
| 1 | First real apply against a desktop from WSL; `stewos` consumes winpkgs as an input. |
| 2 | Resources: `policy` (registry.pol / `PolicyFileEditor`), `service` (done: `windows.services`, per-user templates included), `optionalFeature`, `scheduledTask`, `font`, `shortcut`, `env`, `wallpaper`. |
| **3** | Done: `windows.explorer`, `.taskbar`, `.theme`, `.privacy`, `.keyboard`, `.developer` over the registry. Still open: `winpkgs.terminal` (a settings.json builder, so a file rather than registry), `winpkgs.startMenu`, and per-key ownership so `winpkgs/registryKey` can refuse to delete keys winpkgs did not create. |
| **3b** | Done: home configurations evaluate home-manager's modules; files, variables, PATH and packages translate. Open: a command-running resource so `onChange` and `home.activation` could mean something. |
| 4 | `autounattend.xml` generation from the same module tree — layer zero of a clean install. |
| 5 | Evaluate DSC v3 as an execution engine; scoop as a second package backend. |
