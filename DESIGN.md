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
      "properties": { "target": "%APPDATA%\\wezterm\\wezterm.lua", "source": "files/0-wezterm.lua" } }
  ]
}
```

Every resource has `type`, `id` (unique, human-readable), `scope`
(`user` | `machine`) and `properties`. File sources are paths relative to the
document, so the closure is self-contained.

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

## Scopes and elevation

`HKCU` and `%APPDATA%`-style paths are user scope; `HKLM`, `%ProgramData%`
and machine-scoped winget installs are machine scope. The Nix modules derive
scope automatically and allow override.

`apply` runs user-scope resources in the calling process. If any machine-scope
resource is out of state and the process is not elevated, it launches **one**
elevated child (`-Verb RunAs`, hidden window, output tee'd to a log the parent
prints) with `-Scope machine`. One UAC prompt per apply, never per resource.

## State and rollback

State lives on the Windows side, never in the store:

```
%LOCALAPPDATA%\winpkgs\      user scope
%ProgramData%\winpkgs\       machine scope
  state.json                 ledger: { owned: { winget: [ids] }, generation: N }
  generations\NNN\
    journal.json             [{ resource, before }] in apply order
    config.json              the document that was applied
    files\                   Backup() output
```

The **ledger** records what winpkgs installed. Pruning uninstalls
`owned - declared`, never anything winpkgs did not install itself. That is what
makes package lists declarative rather than a bootstrap script.

A **generation** is one apply that changed at least one resource.
`rollback -Generation N` replays `Restore` over that journal in reverse.
Faithful for registry and files; best-effort for packages (reinstall the
previous version if known, otherwise uninstall). The journal is written
incrementally so a crash mid-apply still leaves a usable partial generation.

This is not Nix rollback. It is the achievable 70%, and reimage-from-clean is
the other 30%.

## Decisions

**PowerShell 7 for the runtime, not Rust.** Native registry/COM/WMI/policy
access, ships inside the closure as text with no cross-compilation, testable
with Pester on a hosted Windows runner. `bootstrap.ps1` is the only Windows
PowerShell 5.1-compatible file; its job is to install pwsh and get out of the
way. The resource contract is language-neutral if this ever changes. The
runtime avoids PS7-only *syntax* (ternary, `??`, `&&`) so the 5.1 parser can
still syntax-check it; it freely uses PS7 cmdlet features.

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

**Registry keys are double-quoted with doubled backslashes.** The first draft
used indented strings (`''HKCU\Software\...''`) as attribute names; Nix does
not allow that — attribute names may only be `"..."` or `${...}`. Substituting
`/` for `\` was rejected because real keys contain slashes
(`...\Content Type\application/json`). File targets, by contrast, may use
forward slashes since Win32 accepts them, so `winpkgs.files` keys stay readable.

## Roadmap

| Slice | Scope |
|---|---|
| **0** | This scaffold: `windowsSystem`, registry/winget/file modules, plan/apply/rollback, bootstrap, CI. |
| 1 | First real apply against a desktop from WSL; `stewos` consumes winpkgs as an input. |
| 2 | Resources: `policy` (registry.pol / `PolicyFileEditor`), `service`, `optionalFeature`, `scheduledTask`, `font`, `shortcut`, `env`. |
| 3 | Higher-level modules over raw registry (`winpkgs.explorer.*`, `winpkgs.theme.*`, `winpkgs.terminal.*`), the way NixOS wraps config files. |
| 4 | `autounattend.xml` generation from the same module tree — layer zero of a clean install. |
| 5 | Evaluate DSC v3 as an execution engine; scoop as a second package backend. |
