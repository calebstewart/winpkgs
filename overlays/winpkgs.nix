# `pkgs.winpkgs`: what the overlay adds to `pkgs` for modules and consumers to
# call. Split out of default.nix so that the documentation site can read it --
# nixdoc documents the bindings of a file's top-level attrset, from RFC-145
# doc-comments (`/** ... */`), and an overlay's `final: prev:` body is not one.
# The tables and the marking functions stay in default.nix, which applies them
# to nixpkgs; this file only exposes them.
{
  lib,
  final,
  # The annotation helpers default.nix applies to nixpkgs' own packages.
  normalise,
  programsOf,
  withPrograms,
  markFont,
  markPortable,
  label,
  exeName,
  # The tables, for a consumer that wants to read them.
  mappings,
  fontNames,
  portables,
}:
{
  /**
    The nixpkgs attribute to winget id table, `overlays/winget.nix`, as it is
    in the source: an id, `{ id; scope; programDir; mainProgram; }`, or `null`
    for a package with no Windows build.
  */
  wingetMappings = mappings;

  /**
    The nixpkgs attributes marked as fonts, `overlays/fonts.nix`. Every member
    of `pkgs.nerd-fonts` is marked as well, without being listed here.
  */
  fontPackages = fontNames;

  /**
    The portable programs the overlay adds, `overlays/portable.nix`: name to
    `{ version; url; hash; flat; mainProgram; }`.
  */
  portablePackages = portables;

  /**
    Mark a package the tables do not know as a font, so that a home
    configuration installs its `share/fonts` for the user instead of asking
    for a winget id. A system configuration's `fonts.packages` needs no mark.

    # Inputs

    `pkg`
    : A font package: a derivation with font files under `share/fonts`.

    # Example

    ```nix
    home.packages = [ (pkgs.winpkgs.font pkgs.some-font) ];
    ```

    # Type

    ```
    font :: Derivation -> Derivation
    ```
  */
  font = markFont;

  /**
    Mark a package -- a fetched archive, typically -- as a program to install
    from its files, into `%LOCALAPPDATA%\Programs\<name>` and onto the user's
    `PATH`. The overlay's own portable packages are built this way from
    `overlays/portable.nix`; this is for one it does not have.

    # Inputs

    `name`
    : The directory under `%LOCALAPPDATA%\Programs`, and the main program's
      name unless the package's `meta.mainProgram` says otherwise.

    `pkg`
    : The unpacked files, as a derivation.

    # Example

    ```nix
    home.packages = [
      (pkgs.winpkgs.portable "tool" (pkgs.fetchzip {
        url = "https://example.com/tool-1.0-win64.zip";
        hash = "sha256-...";
      }))
    ];
    ```

    # Type

    ```
    portable :: String -> Derivation -> Derivation
    ```
  */
  portable = markPortable;

  /**
    A package winget has and nixpkgs does not: a stub derivation carrying the
    same annotation the table gives nixpkgs packages, so it can sit in
    `home.packages` or `environment.systemPackages` beside them. Nothing is
    built.

    # Inputs

    `spec`
    : The winget id, or `{ id; scope; programDir; mainProgram; }`. `scope` is
      `"machine"` or `"user"` when the installer works at one scope only -- a
      home configuration hands a machine-scope package to the system
      configuration that lists it in `winpkgs.homes`. `programDir` says where
      the installer puts its programs, in `%VAR%` form, which is what `getExe`
      needs; `mainProgram` names the one `getExe` means.

    # Example

    ```nix
    home.packages = [
      (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")
      (pkgs.winpkgs.fromWinget {
        id = "LLVM.LLVM";
        scope = "machine";
        programDir = ''%ProgramFiles%\LLVM\bin'';
        mainProgram = "clang";
      })
    ];
    ```

    # Type

    ```
    fromWinget :: (String | AttrSet) -> Derivation
    ```
  */
  fromWinget =
    spec:
    let
      winget = normalise spec;
    in
    withPrograms (programsOf spec) (
      final.buildPackages.runCommandLocal "winget-${lib.strings.sanitizeDerivationName winget.id}"
        {
          passthru = {
            inherit winget;
          };
        }
        ''
          mkdir -p $out
        ''
    );

  /**
    The package's main program as a Windows path -- `lib.getExe` for a machine
    without a store. `pkgs.winpkgs.getExe pkgs.alacritty` is
    `%ProgramFiles%\Alacritty\alacritty.exe`, the way `lib.getExe` is a store
    path on Linux. The package needs a `programDir`, which the table, a portable
    package and `fromWinget` can each supply, and a `meta.mainProgram`; a
    package without either fails the evaluation by name rather than producing a
    command that cannot run.

    The result is in `%VAR%` form, as the Run key and `cmd` speak it; see
    `toPowerShell` for a command pwsh runs.

    # Inputs

    `pkg`
    : A package with a `programDir` and a `meta.mainProgram`.

    # Example

    ```nix
    windows.startup.alacritty = "\"${pkgs.winpkgs.getExe pkgs.alacritty}\"";
    ```

    # Type

    ```
    getExe :: Derivation -> String
    ```
  */
  getExe =
    pkg:
    final.winpkgs.getExe' pkg (
      pkg.meta.mainProgram or (throw ''
        winpkgs.getExe: ${label pkg} has no meta.mainProgram, so which of its programs is
        meant is unknown. Use `pkgs.winpkgs.getExe' pkg "name"`, or give it one.'')
    );

  /**
    Another program in a package's directory, as `lib.getExe'` names one in a
    package's `bin/`. A name that already carries an extension Windows runs
    (`.exe`, `.cmd`, `.bat`, `.com`) is left alone; anything else gets `.exe`.

    # Inputs

    `pkg`
    : A package with a `programDir`.

    `name`
    : The program's name, with or without its extension.

    # Example

    ```nix
    pkgs.winpkgs.getExe' pkgs.komorebi "komorebic"
    # => "%ProgramFiles%\\komorebi\\bin\\komorebic.exe"
    ```

    # Type

    ```
    getExe' :: Derivation -> String -> String
    ```
  */
  getExe' =
    pkg: name:
    let
      dir =
        pkg.programDir or (throw ''
          winpkgs.getExe: where ${label pkg} installs its programs is unknown.
          Give its entry in winpkgs' overlays/winget.nix a `programDir`, or pass
          one to `pkgs.winpkgs.fromWinget { id = ...; programDir = ...; }`.'');
    in
    "${dir}\\${exeName name}";

  /**
    A `%VAR%` path, as `getExe` and the Run key speak it, rewritten for a
    command PowerShell runs -- which does not expand cmd's syntax. A name
    PowerShell cannot take bare, `ProgramFiles(x86)`, is braced.

    # Inputs

    `s`
    : A string containing `%VAR%` references.

    # Example

    ```nix
    pkgs.winpkgs.toPowerShell ''%LOCALAPPDATA%\Programs\thide\thide.exe''
    # => "$Env:LOCALAPPDATA\\Programs\\thide\\thide.exe"
    ```

    # Type

    ```
    toPowerShell :: String -> String
    ```
  */
  toPowerShell =
    s:
    lib.concatMapStrings (
      part:
      if builtins.isList part then
        let
          var = builtins.head part;
        in
        if builtins.match "[A-Za-z_][A-Za-z0-9_]*" var != null then "$Env:${var}" else "\${Env:${var}}"
      else
        part
    ) (builtins.split "%([^%]+)%" s);
}
