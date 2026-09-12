# The winpkgs overlay, applied to the Windows cross package set that modules
# see as `pkgs`. It:
#
#  - annotates nixpkgs packages with `winget = { id = ...; }` (or `null` for
#    "no Windows build") so that `home.packages = [ pkgs.git ]` can be turned
#    into a winget install; the derivations themselves are never built;
#  - provides `pkgs.winpkgs.fromWinget "Publisher.Id"` for software that is on
#    winget but not in nixpkgs, as a stub derivation carrying the same
#    annotation;
#  - marks font packages with `isFont = true` (fonts.nix, and every member of
#    `nerd-fonts`), so that `home.packages = [ pkgs.nerd-fonts.jetbrains-mono ]`
#    installs the font's files rather than looking for an installer. Those
#    derivations *are* built -- they are fetched and copied, nothing more --
#    and their files travel in the closure;
#  - adds programs that are not on winget but ship as a zip of files
#    (portable.nix), marked `isPortable = true`, so that `home.packages =
#    [ pkgs.thide ]` copies them under %LOCALAPPDATA%\Programs and puts that
#    on the PATH. Fetched and copied, like fonts;
#  - records where a package's programs land on the machine, as `programDir`,
#    so that `pkgs.winpkgs.getExe pkgs.alacritty` can say what `lib.getExe`
#    says on Linux: the program to run, as a Windows path.
final: prev:
let
  inherit (prev) lib;
  mappings = import ./winget.nix;
  fontNames = import ./fonts.nix;

  markFont = pkg: pkg // { isFont = true; };
  presentFonts = lib.filter (name: prev ? ${name}) fontNames;

  # Where a package's programs are once installed, and which of them is the
  # main one: the Windows counterparts of `bin/` and `meta.mainProgram`, which
  # is what `getExe` reads. `programDir` is a Windows directory in the `%VAR%`
  # form, since where Program Files or a profile is differs by machine.
  # `meta` is only read, never built, so replacing it on the attrset is enough.
  programsOf =
    entry:
    if builtins.isAttrs entry then
      {
        programDir = entry.programDir or null;
        mainProgram = entry.mainProgram or null;
      }
    else
      {
        programDir = null;
        mainProgram = null;
      };
  withPrograms =
    { programDir, mainProgram }:
    pkg:
    pkg
    // lib.optionalAttrs (programDir != null) { inherit programDir; }
    // lib.optionalAttrs (mainProgram != null) {
      meta = (pkg.meta or { }) // {
        inherit mainProgram;
      };
    };

  # A program installed from its files (overlays/portable.nix): the unpacked
  # release archive, marked, with the name its directory takes. Fetched by the
  # build platform, like fonts; nothing is compiled. Its programs are that
  # directory's, and its main program is named after it unless the entry or
  # the package says otherwise.
  portables = import ./portable.nix;
  markPortable =
    pname: pkg:
    withPrograms
      {
        programDir = ''%LOCALAPPDATA%\Programs\${pname}'';
        mainProgram = pkg.meta.mainProgram or pname;
      }
      (
        pkg
        // {
          isPortable = true;
          inherit pname;
        }
      );
  fetchPortable =
    name: p:
    final.buildPackages.fetchzip {
      name = "${name}-${p.version}";
      inherit (p) url hash;
      stripRoot = !(p.flat or false);
    };

  # A table entry or a fromWinget argument: an id, or { id; scope; } plus
  # optionally where its programs land. The annotation always has exactly
  # `id` and `scope`; scope null means either scope works.
  normalise =
    entry:
    if entry == null then
      null
    else if builtins.isString entry then
      {
        id = entry;
        scope = null;
      }
    else
      {
        inherit (entry) id;
        scope = entry.scope or null;
      };

  annotate =
    _name: entry: pkg:
    withPrograms (programsOf entry) (pkg // { winget = normalise entry; });

  # Only names this nixpkgs actually has; the `packages` check pins the pinned
  # nixpkgs to the full table, a consumer's nixpkgs may differ.
  present = lib.filterAttrs (name: _: prev ? ${name}) mappings;

  # A program's file name in its programDir. A name that already carries an
  # extension Windows runs is left alone, so that "Flow.Launcher" becomes
  # "Flow.Launcher.exe" and "npm.cmd" stays itself.
  runnable = [
    ".exe"
    ".cmd"
    ".bat"
    ".com"
  ];
  exeName =
    name: if lib.any (ext: lib.hasSuffix ext (lib.toLower name)) runnable then name else "${name}.exe";
  label = pkg: pkg.pname or pkg.name or "<unnamed package>";
in
lib.mapAttrs (name: entry: annotate name entry prev.${name}) present
// lib.genAttrs presentFonts (name: markFont prev.${name})
// lib.optionalAttrs (prev ? nerd-fonts) {
  nerd-fonts = lib.mapAttrs (_: p: if lib.isDerivation p then markFont p else p) prev.nerd-fonts;
}
// lib.mapAttrs (
  name: p:
  markPortable name (
    withPrograms {
      programDir = null;
      mainProgram = p.mainProgram or null;
    } (fetchPortable name p)
  )
) portables
// {
  winpkgs = (prev.winpkgs or { }) // {
    wingetMappings = mappings;
    fontPackages = fontNames;
    portablePackages = portables;

    # font pkg: mark a package the table does not know as a font, so a home
    # configuration installs its share/fonts instead of asking for a winget id.
    font = markFont;

    # portable "name" pkg: mark a package (a fetched archive, say) as a program
    # to install from its files, into %LOCALAPPDATA%\Programs\<name>.
    portable = markPortable;

    # fromWinget "Publisher.Id", or fromWinget { id; scope = "machine"; } for a
    # package whose installer is machine-wide. `programDir` and `mainProgram`
    # say where its programs land, for getExe.
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

    # getExe pkg: the package's main program as a Windows path, `lib.getExe`
    # for a machine without a store -- "%ProgramFiles%\Alacritty\alacritty.exe"
    # for pkgs.alacritty. getExe' pkg "name" names another program in the same
    # directory, as `lib.getExe'` does. Both need the package's `programDir`,
    # which the table, a portable package and fromWinget can each supply; a
    # package without one fails the evaluation by name rather than producing a
    # command that cannot run.
    getExe =
      pkg:
      final.winpkgs.getExe' pkg (
        pkg.meta.mainProgram or (throw ''
          winpkgs.getExe: ${label pkg} has no meta.mainProgram, so which of its programs is
          meant is unknown. Use `pkgs.winpkgs.getExe' pkg "name"`, or give it one.'')
      );
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

    # toPowerShell "%LOCALAPPDATA%\x" -> "$Env:LOCALAPPDATA\x": a `%VAR%` path,
    # as getExe and the Run key speak it, for a command PowerShell runs, which
    # does not expand cmd's syntax. A name PowerShell cannot take bare,
    # `ProgramFiles(x86)`, is braced.
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
  };
}
