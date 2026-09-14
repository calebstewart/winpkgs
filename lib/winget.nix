# A winget-pkgs tree, read for what its directory names and its installer
# manifests say.
#
# microsoft/winget-pkgs is the winget manifest repository: for every package
# id, a directory per version, each holding that version's YAML manifests. A
# commit of it fixes what "latest" means for every id, the way a commit of
# nixpkgs fixes what `pkgs.git` is -- which is why it is a flake input, and why
# a `winget.packages` entry that names no version gets the one the input pins
# (modules/common/packages.nix).
#
# Versions are read from names alone: `builtins.readDir` on one directory of
# the fetched input is all a version costs. What an installer is -- its URL
# and hash, its type and switches, what it registers once it has run -- is in
# the version's installer manifest, which is what media that carries the
# installers needs (#44). That is YAML, and Nix has no reader for it, so this
# file has one: a subset parser for the block YAML winget-pkgs' tooling
# writes, which refuses anything else by manifest and line rather than
# guessing. No import-from-derivation: a manifest is a `builtins.readFile` of
# a file in the input, and parsing it is evaluation.
#
# Every function takes the tree first, so the module (over its
# `winget.manifests` option), the flake checks (over a fixture tree) and the
# documentation (over the real input) share one reader.
{ lib }:
let
  inherit (builtins)
    elemAt
    head
    length
    match
    split
    stringLength
    tail
    ;

  # -- the YAML subset ------------------------------------------------------
  #
  # A manifest is read in two passes. Each line becomes tokens that carry the
  # column they start at: one `item` for every `- ` the line opens with, then
  # a `key` (with its value, or none when a block follows) or a bare
  # `scalar`. Then a block -- a run of tokens at or right of its first one's
  # column -- is a sequence when it starts with an item and a mapping when it
  # starts with a key, split into entries at that column, each entry's rest a
  # block of its own. Recursion is as deep as the nesting, never as long as
  # the file.
  #
  # Every scalar is a string, quoted or not: winget reads each field by its
  # schema, so `PackageVersion: 1.10` is the version "1.10", not a float, and
  # a return code is a number because `installerRecord` makes it one.
  #
  # Results are `{ value; error = null; }` or `{ value = null; error = { line;
  # message; }; }`, so a refusal can say where it is without a throw.

  ok = value: {
    inherit value;
    error = null;
  };
  bad = line: message: {
    value = null;
    error = { inherit line message; };
  };
  firstError = lib.findFirst (r: r.error != null) null;

  # The UTF-8 byte-order mark some manifests start with; Nix strings have no
  # escape for it, JSON does.
  bom = builtins.fromJSON ("\"\\" + "uFEFF\"");

  trimEnd =
    s:
    let
      m = match "(.*[^ ]) *" s;
    in
    if m == null then "" else head m;

  # The escapes a YAML double-quoted string shares with JSON, which is how
  # it is unescaped. The others (\x41, \U..., \N, \_, an escaped space) are
  # refused rather than half-read.
  jsonEscapes = [
    "\""
    "\\"
    "/"
    "b"
    "f"
    "n"
    "r"
    "t"
    "u"
  ];

  # What follows `key: ` or `- ` on a line: `{ absent = true; }` when that is
  # nothing but a comment, else `{ value; }` or `{ error; }`.
  scalar =
    text:
    let
      single = match "'((''|[^'])*)'( +#.*| *)" text;
      double = match "\"((\\\\.|[^\"\\\\])*)\"( +#.*| *)" text;
      escapes = map head (lib.filter builtins.isList (split "\\\\(.)" (head double)));
      # A plain scalar ends where a comment starts: ` #`.
      plain = trimEnd (head (split " #" text));
      is = pattern: match pattern plain != null;
    in
    if text == "" || lib.hasPrefix "#" text then
      { absent = true; }
    else if lib.hasPrefix "'" text then
      if single == null then
        { error = "a single-quoted string that does not end on its line"; }
      else
        { value = builtins.replaceStrings [ "''" ] [ "'" ] (head single); }
    else if lib.hasPrefix "\"" text then
      if double == null then
        { error = "a double-quoted string that does not end on its line"; }
      else if !(lib.all (c: lib.elem c jsonEscapes) escapes) then
        {
          error = "a double-quoted string with an escape JSON does not have (\\${
            lib.findFirst (c: !(lib.elem c jsonEscapes)) "" escapes
          })";
        }
      else
        { value = builtins.fromJSON "\"${head double}\""; }
    else if is "[[] *[]]" then
      { value = [ ]; }
    else if is "[{] *[}]" then
      { value = { }; }
    else if is "[][{}].*" then
      { error = "a flow collection (`[a, b]` or `{a: b}`); only an empty `[]` or `{}` is read"; }
    else if is "[|>].*" then
      { error = "a block scalar (`|` or `>`), which is not read"; }
    else if is "[&*!].*" then
      { error = "an anchor, alias or tag, which is not read"; }
    else if is "[%@`].*" then
      { error = "a plain scalar starting with a reserved character (quote it)"; }
    else if is "[-?:]( .*)?" then
      { error = "a block indicator (`- `, `? `, `: `) where a value belongs"; }
    else if is ".*:( .*)?" then
      { error = "a `: ` inside a plain scalar (quote it)"; }
    else
      { value = plain; };

  # One line's tokens, left to right.
  lineTokens =
    line: column: text:
    let
      dash = match "-( +(.*))?" text;
      key = match "([A-Za-z0-9_]+):( +(.*))?" text;
      token = kind: attrs: { inherit kind line column; } // attrs;
      refuse = message: [ (token "error" { inherit message; }) ];
    in
    if text == "" || lib.hasPrefix "#" text then
      [ ]
    else if lib.hasPrefix "\t" text then
      refuse "a tab in the indentation, where YAML allows only spaces"
    else if column == 0 && match "(---|\\.\\.\\.)( .*)?" text != null then
      [ (token "document" { }) ]
    else if dash != null then
      [ (token "item" { }) ]
      ++ lib.optionals (head dash != null) (
        lineTokens line (column + 1 + stringLength (head dash) - stringLength (elemAt dash 1)) (
          elemAt dash 1
        )
      )
    else if key != null then
      let
        v = if elemAt key 2 == null then { absent = true; } else scalar (elemAt key 2);
      in
      if v ? error then
        refuse v.error
      else
        [
          (token "key" {
            name = head key;
            inline = !(v ? absent);
            value = v.value or null;
          })
        ]
    else
      let
        v = scalar text;
      in
      if v ? error then refuse v.error else [ (token "scalar" { inherit (v) value; }) ];

  indices = toks: lib.range 0 (length toks - 1);
  atColumn = column: toks: lib.filter (i: (elemAt toks i).column == column) (indices toks);

  # The block split at `starts` (indices into it), each entry running to the
  # next start.
  entries =
    toks: starts:
    let
      bounds = starts ++ [ (length toks) ];
    in
    lib.genList (i: lib.sublist (elemAt bounds i) (elemAt bounds (i + 1) - elemAt bounds i) toks) (
      length starts
    );

  block =
    toks:
    let
      first = head toks;
      under = lib.findFirst (t: t.column < first.column) null toks;
    in
    if under != null then
      bad under.line "a line indented less than the block it follows, and not at the column of any enclosing one"
    else if first.kind == "item" then
      sequence first.column toks
    else if first.kind == "key" then
      mapping first.column toks
    else if length toks == 1 then
      ok first.value
    else
      bad (elemAt toks 1).line "a plain scalar that runs onto another line, which is not read";

  sequence =
    column: toks:
    let
      starts = atColumn column toks;
      stray = lib.findFirst (i: (elemAt toks i).kind != "item") null starts;
      values = map (e: if tail e == [ ] then ok null else block (tail e)) (entries toks starts);
      failed = firstError values;
    in
    if stray != null then
      bad (elemAt toks stray).line "a ${(elemAt toks stray).kind} at the column of a sequence's `-`"
    else if failed != null then
      failed
    else
      ok (map (r: r.value) values);

  # A key's entry runs to the next key at its column, taking a sequence whose
  # `-` sits at that column too: winget-pkgs writes `Installers:` and its
  # items flush left.
  mapping =
    column: toks:
    let
      starts = lib.filter (i: (elemAt toks i).kind == "key") (atColumn column toks);
      stray = lib.findFirst (t: t.column == column && t.kind == "scalar") null toks;
      es = entries toks starts;
      names = map (e: (head e).name) es;
      again = lib.findFirst (i: lib.elem (elemAt names i) (lib.take i names)) null (indices names);
      value =
        e:
        let
          k = head e;
          rest = tail e;
        in
        if !k.inline then
          if rest == [ ] then ok null else block rest
        else if rest == [ ] then
          ok k.value
        else
          bad (head rest).line "more under `${k.name}`, which has its value on its own line";
      values = map value es;
      failed = firstError values;
    in
    if stray != null then
      bad stray.line "a scalar where a `key:` belongs"
    else if again != null then
      bad (head (elemAt es again)).line "`${elemAt names again}` a second time in one mapping"
    else if failed != null then
      failed
    else
      ok (lib.listToAttrs (lib.zipListsWith lib.nameValuePair names (map (r: r.value) values)));

  # -- installer manifests --------------------------------------------------

  # What a manifest's root says about the package or the file, not about an
  # installer. Every other root key is a default for each entry of
  # `Installers`.
  packageKeys = [
    "PackageIdentifier"
    "PackageVersion"
    "Channel"
    "Installers"
    "ManifestType"
    "ManifestVersion"
  ];

  # The type that decides how an entry installs: a zip's is what it holds.
  effectiveType =
    entry:
    if (entry.InstallerType or null) == "zip" then
      entry.NestedInstallerType or null
    else
      entry.InstallerType or null;

  # Root keys winget hands down only to the installer types that use them
  # (its DoesInstallerTypeUse* rules): a root ProductCode is not an MSIX
  # entry's, nor a root PackageFamilyName an MSI's.
  handedDown = {
    ProductCode =
      t:
      lib.elem t [
        "exe"
        "inno"
        "msi"
        "nullsoft"
        "wix"
        "burn"
        "portable"
      ];
    AppsAndFeaturesEntries =
      t:
      lib.elem t [
        "exe"
        "inno"
        "msi"
        "nullsoft"
        "wix"
        "burn"
      ];
    PackageFamilyName =
      t:
      lib.elem t [
        "msix"
        "appx"
      ];
  };

  # Types an undeclared scope does not bar from a user install; winget
  # (`winget show --scope user`) takes them and refuses an undeclared exe.
  scopeless = [
    "portable"
    "msix"
    "appx"
  ];

  attrsOr = v: if builtins.isAttrs v then v else { };

  foldInstaller =
    root: entry:
    let
      defaults = removeAttrs root packageKeys;
      type = effectiveType (defaults // entry);
      inherited = lib.filterAttrs (key: _: !(handedDown ? ${key}) || handedDown.${key} type) defaults;
      # Switches merge key by key, as winget populates them: a root Silent
      # and an entry's Custom are both the entry's.
      switches = lib.optionalAttrs (defaults ? InstallerSwitches || entry ? InstallerSwitches) {
        InstallerSwitches =
          attrsOr (defaults.InstallerSwitches or null) // attrsOr (entry.InstallerSwitches or null);
      };
    in
    inherited // entry // switches;

  # A return code as a process's exit code reads in PowerShell: a signed
  # 32-bit number, whether the manifest wrote it as -1978335189, 3010 or
  # 0x8004070b.
  returnCode =
    text:
    let
      hex = match "0[xX]([0-9a-fA-F]+)" text;
      n = if hex != null then (builtins.fromTOML "v = 0x${head hex}").v else lib.toInt text;
    in
    if n >= 2147483648 then n - 4294967296 else n;

  flag = v: v != null && lib.toLower v == "true";

  # One top-level key's value, from a manifest that is not parsed as a whole:
  # a locale manifest's Description is a block scalar more often than not,
  # which parseYAML refuses. A key at column 0 is always a line of its own --
  # a block scalar's text is indented -- so the line is read with the
  # parser's own scalar rules. `null` when the key is absent, empty or
  # outside those rules.
  topLevelValue =
    text: key:
    let
      lines = lib.filter builtins.isString (split "\r\n|\r|\n" (lib.removePrefix bom text));
      line = lib.findFirst (lib.hasPrefix "${key}:") null lines;
      rest = if line == null then null else match "[^:]*:( +(.*))?" line;
      v = if rest == null || elemAt rest 1 == null then { } else scalar (elemAt rest 1);
    in
    v.value or null;
in
rec {
  /**
    Where a package's manifests are in a winget-pkgs tree. The layout is
    winget's own: the id's first character, lowercased, then the id split at
    its dots, each piece a directory.

    A publisher's directory exists too (`manifests/g/Git` for `Git.Git`), so a
    directory being there says nothing about a package being there; that is
    what `hasPackage` is for.

    # Inputs

    `root`
    : The tree: the `winget-pkgs` flake input, or any directory laid out like
      it.

    `id`
    : A winget package id, exact and case-sensitive: `"Git.Git"`.

    # Example

    ```nix
    manifestDir inputs.winget-pkgs "Python.Python.3.13"
    => "/nix/store/...-source/manifests/p/Python/Python/3/13"
    ```

    # Type

    ```
    manifestDir :: Path -> String -> String
    ```
  */
  manifestDir =
    root: id:
    "${toString root}/manifests/${
      lib.toLower (lib.substring 0 1 id)
    }/${lib.concatStringsSep "/" (lib.splitString "." id)}";

  /**
    The versions a package has in the tree, in no particular order: the
    directories under `manifestDir` that hold the package's own version
    manifest, `<version>/<id>.yaml`.

    The manifest is the test, not the directory alone, because a package's
    directory also holds the packages named under it: `Microsoft.PowerShell`
    has `Preview/` beside its versions, and that is `Microsoft.PowerShell.Preview`,
    not a version of PowerShell. Empty when the package is not in the tree.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Example

    ```nix
    versionsOf inputs.winget-pkgs "Microsoft.PowerShell"
    => [ "7.4.6.0" "7.5.0.0" ... ]
    ```

    # Type

    ```
    versionsOf :: Path -> String -> [String]
    ```
  */
  versionsOf =
    root: id:
    let
      dir = manifestDir root id;
    in
    if !builtins.pathExists dir then
      [ ]
    else
      lib.filter (v: builtins.pathExists "${dir}/${v}/${id}.yaml") (
        lib.attrNames (lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir dir))
      );

  /**
    Whether the tree has the package at all: at least one version of it.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Type

    ```
    hasPackage :: Path -> String -> Bool
    ```
  */
  hasPackage = root: id: versionsOf root id != [ ];

  /**
    The package's newest version in the tree, or `null` when it has none.

    Newest by `builtins.compareVersions`: segment by segment, digits as
    numbers, so `7.4.10` is newer than `7.4.9` and `2.47.10` than `2.47.9`,
    which is how winget orders them too. A date-stamped version such as
    wezterm's `20240203-110809-5046fc22` orders by its date. Pre-releases are
    not a concern: winget-pkgs gives them ids of their own (`.Preview`,
    `.Nightly`) rather than versions beside the stable ones.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Example

    ```nix
    latestVersion inputs.winget-pkgs "Git.Git"
    => "2.51.0"
    ```

    # Type

    ```
    latestVersion :: Path -> String -> String | Null
    ```
  */
  latestVersion =
    root: id:
    let
      versions = versionsOf root id;
    in
    if versions == [ ] then
      null
    else
      lib.foldl' (a: b: if lib.versionOlder a b then b else a) (lib.head versions) (lib.tail versions);

  /**
    The tree, named for a message: the input's short revision when it has
    one, else where the tree is (a fixture, a `path:` input, a checkout).

    # Inputs

    `root`
    : As for `manifestDir`.

    # Example

    ```nix
    describe inputs.winget-pkgs
    => "winget-pkgs at 3f2a1c9"
    ```

    # Type

    ```
    describe :: Path -> String
    ```
  */
  describe =
    root:
    if builtins.isAttrs root && root ? shortRev then
      "winget-pkgs at ${root.shortRev}"
    else
      "the winget-pkgs tree at ${toString root}";

  /**
    What a `winget.packages` entry asks for, once the tree has been consulted:
    the version to hand the runtime, and whether it is a pin.

    An entry with a `version` is pinned to it exactly, whatever the tree says.
    An entry without one, from the `winget` source, gets the tree's latest and
    is not pinned: the runtime treats that version as a floor, installing it
    when the package is absent and upgrading to it when what is installed is
    older, but leaving a newer install alone. A package from another source
    (`msstore`) is not in winget-pkgs, so its version stays as given, usually
    `null`, and present is enough.

    `version` is `null` when the package is not in the tree; the module refuses
    that with a message naming the id before it reaches a document.

    # Inputs

    `root`
    : As for `manifestDir`.

    `package`
    : A merged `winget.packages` entry: `{ id; version; source; ... }`.

    # Example

    ```nix
    resolve inputs.winget-pkgs { id = "Git.Git"; version = null; source = "winget"; }
    => { version = "2.51.0"; pinned = false; }

    resolve inputs.winget-pkgs { id = "Git.Git"; version = "2.47.1"; source = "winget"; }
    => { version = "2.47.1"; pinned = true; }
    ```

    # Type

    ```
    resolve :: Path -> AttrSet -> { version :: String | Null; pinned :: Bool; }
    ```
  */
  resolve =
    root: package:
    let
      given = package.version or null;
    in
    if (package.source or "winget") != "winget" then
      {
        version = given;
        pinned = given != null;
      }
    else if given != null then
      {
        version = given;
        pinned = true;
      }
    else
      {
        version = latestVersion root package.id;
        pinned = false;
      };

  /**
    Parse YAML text, or say where and why not.

    The subset is the block YAML winget-pkgs' tooling (`wingetcreate`,
    `komac`, `YamlCreate.ps1`) writes: mappings, sequences (flush with their
    key, as winget-pkgs writes `Installers:`, or indented), plain and quoted
    scalars, comments on their own lines and after values, CRLF and CR line
    breaks, a byte-order mark, a leading `---`. Every scalar is a string, quoted or not;
    a key with nothing after it and nothing under it is `null`; `[]` and `{}`
    are empty.

    Anything else is refused rather than guessed at: flow collections that are
    not empty, block scalars (`|`, `>`), anchors, aliases and tags, a scalar
    that runs onto a second line, a `: ` inside a plain scalar, a double-quoted
    escape JSON does not share, a second document, a key twice in one mapping,
    tabs in the indentation.

    # Inputs

    `name`
    : What to call the text in a refusal: a file, usually.

    `text`
    : The YAML.

    # Example

    ```nix
    parseYAML "example.yaml" "Commands:\n- rg\n"
    => { value = { Commands = [ "rg" ]; }; error = null; }

    parseYAML "example.yaml" "Commands: [rg]\n"
    => { value = null; error = "example.yaml, line 1: a flow collection ..."; }
    ```

    # Type

    ```
    parseYAML :: String -> String -> { value :: Any; error :: String | Null; }
    ```
  */
  parseYAML =
    name: text:
    let
      # A line break is LF, CRLF or a lone CR, as YAML has it; manifests
      # written on Windows end their lines with CRLF, and a few with CR CRLF.
      lines = lib.filter builtins.isString (split "\r\n|\r|\n" (lib.removePrefix bom text));
      tokens = lib.concatLists (
        lib.imap1 (
          n: l:
          let
            m = match "( *)(.*)" l;
          in
          lineTokens n (stringLength (head m)) (elemAt m 1)
        ) lines
      );
      # One leading `---` opens the document; any other marker is a second
      # document or an end, and not read.
      body = if tokens != [ ] && (head tokens).kind == "document" then tail tokens else tokens;
      broken = lib.findFirst (t: t.kind == "error" || t.kind == "document") null body;
      result =
        if broken != null then
          bad broken.line (
            broken.message or "a second document (`---`) or a document end (`...`), which is not read"
          )
        else if body == [ ] then
          ok null
        else
          block body;
    in
    if result.error == null then
      result
    else
      {
        value = null;
        error = "${name}, line ${toString result.error.line}: ${result.error.message}";
      };

  /**
    Parse YAML text, as `parseYAML` does, throwing its refusal.

    # Inputs

    `name`, `text`
    : As for `parseYAML`.

    # Type

    ```
    fromYAML :: String -> String -> Any
    ```
  */
  fromYAML =
    name: text:
    let
      parsed = parseYAML name text;
    in
    if parsed.error == null then parsed.value else throw "winpkgs: cannot read ${parsed.error}";

  /**
    A package version's installer manifest, `<id>.installer.yaml`, parsed,
    with each entry of `Installers` holding everything that applies to it.

    A manifest's root may state what most of its installers share --
    `InstallerType`, `InstallerSwitches`, `Scope`, `ProductCode`,
    `Dependencies`, `NestedInstallerFiles` and the rest -- and an entry states
    only what differs. The root's installer keys are folded into every entry
    the way winget reads them: an entry's own key replaces the root's, except
    `InstallerSwitches`, which merge key by key; and `ProductCode`,
    `AppsAndFeaturesEntries` and `PackageFamilyName` pass down only to entries
    whose type uses them (a zip's type is the one it holds). The root keeps
    its keys too.

    Throws when the tree has no such manifest, when the manifest is outside
    what `parseYAML` reads -- naming the file and line, and what to do -- and
    when it is not the installer manifest of `id` at `version`;
    `readInstallerManifest` says so instead.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    `version`
    : One of `versionsOf root id`.

    # Example

    ```nix
    (installerManifest inputs.winget-pkgs "BurntSushi.ripgrep.MSVC" "14.1.1").Installers
    => [ { Architecture = "x86"; InstallerType = "zip"; NestedInstallerType = "portable"; ... } ... ]
    ```

    # Type

    ```
    installerManifest :: Path -> String -> String -> AttrSet
    ```
  */
  installerManifest =
    root: id: version:
    let
      read = readInstallerManifest root id version;
    in
    if read.error == null then read.value else throw "winpkgs: ${read.error}";

  /**
    `installerManifest`, with its refusal as a value: `{ value; error = null;
    }`, or `{ value = null; error; }` with the message `installerManifest`
    would throw. For a caller that has several packages to read and wants to
    say what is wrong with all of them at once, as installation media does.

    # Inputs

    `root`, `id`, `version`
    : As for `installerManifest`.

    # Type

    ```
    readInstallerManifest :: Path -> String -> String -> { value :: AttrSet | Null; error :: String | Null; }
    ```
  */
  readInstallerManifest =
    root: id: version:
    let
      relative = "${lib.removePrefix "${toString root}/" (manifestDir root id)}/${version}/${id}.installer.yaml";
      file = "${toString root}/${relative}";
      parsed = parseYAML "${relative} in ${describe root}" (builtins.readFile file);
      m = parsed.value;
      refuse = error: {
        value = null;
        inherit error;
      };
    in
    if !builtins.pathExists file then
      refuse "${describe root} has no installer manifest for ${id} ${version} (no ${relative})"
    else if parsed.error != null then
      refuse ''
        cannot read the installer manifest of ${id} ${version}: ${parsed.error}.
        lib.winget reads the block YAML winget-pkgs' tooling writes, and this is outside it. Pin another version of ${id} (winget.packages = [ { id = "${id}"; version = "..."; } ]), or report the line so the reader can be widened''
    else if
      !(builtins.isAttrs m)
      || (m.ManifestType or null) != "installer"
      || (m.PackageIdentifier or null) != id
      || (m.PackageVersion or null) != version
    then
      refuse "${relative} in ${describe root} is not the installer manifest of ${id} ${version}"
    else
      {
        value = m // {
          Installers = map (foldInstaller m) (
            if builtins.isList (m.Installers or null) then m.Installers else [ ]
          );
        };
        error = null;
      };

  /**
    The name and publisher a package version goes by, from its default
    locale's manifest: `<id>.locale.<DefaultLocale>.yaml`, the locale named by
    the version manifest, `<id>.yaml`. They are what winget writes into
    Add/Remove Programs for a portable it installs, and -- with nothing else
    to go on, since a portable has no product code -- how it recognises that
    install as the package afterwards.

    Only `PackageName` and `Publisher` are read, each off its own line: a
    locale manifest's description is usually a block scalar, which
    `parseYAML` does not read. Each is `null` when the tree has no such
    manifest or the line is not one `parseYAML` would read.

    # Inputs

    `root`, `id`, `version`
    : As for `installerManifest`.

    # Example

    ```nix
    packageNames inputs.winget-pkgs "BurntSushi.ripgrep.MSVC" "14.1.1"
    => { name = "RipGrep MSVC"; publisher = "BurntSushi"; }
    ```

    # Type

    ```
    packageNames :: Path -> String -> String -> { name :: String | Null; publisher :: String | Null; }
    ```
  */
  packageNames =
    root: id: version:
    let
      dir = "${manifestDir root id}/${version}";
      read = file: if builtins.pathExists file then builtins.readFile file else "";
      locale = topLevelValue (read "${dir}/${id}.yaml") "DefaultLocale";
      text = if locale == null then "" else read "${dir}/${id}.locale.${locale}.yaml";
    in
    {
      name = topLevelValue text "PackageName";
      publisher = topLevelValue text "Publisher";
    };

  /**
    The installer types `selectInstaller` picks, most preferred first. A
    `zip` is picked for what it holds, which must be one of the others.
    Types winget has and these do not (`pwa`, `font`) are never picked.

    # Type

    ```
    installerTypes :: [String]
    ```
  */
  installerTypes = [
    "msi"
    "wix"
    "inno"
    "nullsoft"
    "burn"
    "exe"
    "msix"
    "appx"
    "zip"
    "portable"
  ];

  /**
    The entry of an installer manifest a configuration would get, or `null`
    when none fits: winget's selection, in miniature.

    Scope first. An entry that declares the configuration's scope is
    preferred; for a `machine` scope, an entry that declares none is
    acceptable after it -- run from the elevated system apply, it installs
    for the machine, which is why the runtime asks winget for
    `SystemOrUnknown` -- and for a `user` scope it is not, as a home
    configuration never elevates. Except a portable, bare or in a zip, and
    an MSIX: a portable installs wherever it is put and an MSIX installs for
    the user, so winget takes one that declares no scope for either, and so
    does this. Then architecture: `arch` itself, then
    `neutral`, then what the machine also runs (`x86` on `x64`; `x64` then
    `x86` on `arm64`). Then `installerTypes` order, then the manifest's own.
    Nothing else is weighed: where winget would consult the machine's locale
    or OS version, the manifest's order decides.

    # Inputs

    `manifest`
    : As `installerManifest` returns it.

    `scope`
    : `"machine"` or `"user"`.

    `arch`
    : The machine's architecture: `"x64"` (the default), `"arm64"` or `"x86"`.

    # Example

    ```nix
    selectInstaller {
      manifest = installerManifest inputs.winget-pkgs "Git.Git" "2.51.0";
      scope = "machine";
    }
    => { Architecture = "x64"; Scope = "machine"; InstallerType = "inno"; ... }
    ```

    # Type

    ```
    selectInstaller :: { manifest :: AttrSet; scope :: String; arch :: String ? } -> AttrSet | Null
    ```
  */
  selectInstaller =
    {
      manifest,
      scope,
      arch ? "x64",
    }:
    let
      architectures =
        {
          x64 = [
            "x64"
            "neutral"
            "x86"
          ];
          arm64 = [
            "arm64"
            "neutral"
            "x64"
            "x86"
          ];
          x86 = [
            "x86"
            "neutral"
          ];
        }
        .${arch} or (throw "winpkgs: selectInstaller: no architecture ${arch}; x64, arm64 or x86");
      rank = list: v: lib.lists.findFirstIndex (x: x == v) null list;
      scopeRank =
        e:
        let
          declared = e.Scope or null;
        in
        if declared == scope then
          0
        else if declared == null && (scope == "machine" || lib.elem (effectiveType e) scopeless) then
          1
        else
          null;
      typeRank =
        e:
        let
          type = e.InstallerType or null;
          held = e.NestedInstallerType or null;
        in
        if type == "zip" && (held == "zip" || rank installerTypes held == null) then
          null
        else
          rank installerTypes type;
      candidates = lib.filter (c: lib.all (r: r != null) c.ranks) (
        lib.imap0 (i: e: {
          entry = e;
          ranks = [
            (scopeRank e)
            (rank architectures (e.Architecture or null))
            (typeRank e)
            i
          ];
        }) manifest.Installers
      );
      before =
        a: b:
        let
          go = xs: ys: xs != [ ] && (head xs < head ys || (head xs == head ys && go (tail xs) (tail ys)));
        in
        go a.ranks b.ranks;
    in
    assert lib.assertOneOf "selectInstaller scope" scope [
      "machine"
      "user"
    ];
    if candidates == [ ] then
      null
    else
      (lib.foldl' (best: c: if before c best then c else best) (head candidates) (tail candidates)).entry;

  /**
    What leaves Nix about a package's installer: one flat attrset, with the
    manifest's names in camelCase and its numbers as numbers. This is what
    installation media carries beside the installer, and what the runtime
    runs it by.

    - `id`, `version`: the package's.
    - `url`, `sha256`: where the installer is and its hash, lowercase hex.
    - `type`: `installerTypes`, one of them. `nestedType` is what a `zip`
      holds, and `nestedFiles` which of its files matter:
      `{ relativeFilePath; portableCommandAlias; }`, the alias `null` where
      the manifest gives none. `commands` are the manifest's `Commands`, the
      first of which names a bare `portable`. `archiveBinariesDependOnPath`:
      a zip's programs want its directory on PATH, not links to them.
    - `switches`: `{ silent; silentWithProgress; custom; installLocation; }`,
      each `null` where the manifest says nothing; winget's defaults for the
      type are the runtime's to supply.
    - `scope`: the scope the entry declares, `null` for none.
    - `productCode`, `packageFamilyName`, `appsAndFeaturesEntries` (`{
      displayName; publisher; displayVersion; productCode; upgradeCode;
      installerType; }`): how the install is found afterwards, in Add/Remove
      Programs or among the machine's packages.
    - `dependencies`: `{ packages = [ { id; minimumVersion; } ];
      windowsFeatures; windowsLibraries; external; }`. External ones cannot be
      carried; they are listed so they can be refused.
    - `expectedReturnCodes` (`{ code; response; responseUrl; }`) and
      `successCodes`: exit codes as PowerShell reads them, signed 32-bit, so
      `0x8004070b` is `-2147219701`.
    - `elevationRequirement`: `elevationRequired`, `elevatesSelf`,
      `elevationProhibited`, or `null`.

    # Inputs

    `manifest`
    : As `installerManifest` returns it.

    `installer`
    : One of its `Installers`, usually the one `selectInstaller` picked.

    # Example

    ```nix
    installerRecord { inherit manifest; installer = selectInstaller { inherit manifest; scope = "user"; }; }
    => { id = "BurntSushi.ripgrep.MSVC"; type = "zip"; nestedType = "portable";
         nestedFiles = [ { relativeFilePath = "ripgrep-14.1.1-x86_64-pc-windows-msvc/rg.exe"; portableCommandAlias = "rg"; } ];
         ... }
    ```

    # Type

    ```
    installerRecord :: { manifest :: AttrSet; installer :: AttrSet; } -> AttrSet
    ```
  */
  installerRecord =
    { manifest, installer }:
    let
      i = installer;
      id = manifest.PackageIdentifier;
      required =
        key: i.${key} or (throw "winpkgs: an installer of ${id} ${manifest.PackageVersion} has no ${key}.");
      list = v: if builtins.isList v then v else [ ];
      switches = attrsOr (i.InstallerSwitches or null);
      dependencies = attrsOr (i.Dependencies or null);
    in
    {
      inherit id;
      version = manifest.PackageVersion;
      url = required "InstallerUrl";
      sha256 = lib.toLower (required "InstallerSha256");
      type = required "InstallerType";
      nestedType = i.NestedInstallerType or null;
      nestedFiles = map (f: {
        relativeFilePath = f.RelativeFilePath;
        portableCommandAlias = f.PortableCommandAlias or null;
      }) (list (i.NestedInstallerFiles or null));
      commands = list (i.Commands or null);
      archiveBinariesDependOnPath = flag (i.ArchiveBinariesDependOnPath or null);
      switches = {
        silent = switches.Silent or null;
        silentWithProgress = switches.SilentWithProgress or null;
        custom = switches.Custom or null;
        installLocation = switches.InstallLocation or null;
      };
      scope = i.Scope or null;
      productCode = i.ProductCode or null;
      packageFamilyName = i.PackageFamilyName or null;
      appsAndFeaturesEntries = map (e: {
        displayName = e.DisplayName or null;
        publisher = e.Publisher or null;
        displayVersion = e.DisplayVersion or null;
        productCode = e.ProductCode or null;
        upgradeCode = e.UpgradeCode or null;
        installerType = e.InstallerType or null;
      }) (list (i.AppsAndFeaturesEntries or null));
      dependencies = {
        packages = map (p: {
          id = p.PackageIdentifier;
          minimumVersion = p.MinimumVersion or null;
        }) (list (dependencies.PackageDependencies or null));
        windowsFeatures = list (dependencies.WindowsFeatures or null);
        windowsLibraries = list (dependencies.WindowsLibraries or null);
        external = list (dependencies.ExternalDependencies or null);
      };
      expectedReturnCodes = map (c: {
        code = returnCode c.InstallerReturnCode;
        response = c.ReturnResponse or null;
        responseUrl = c.ReturnResponseUrl or null;
      }) (list (i.ExpectedReturnCodes or null));
      successCodes = map returnCode (list (i.InstallerSuccessCodes or null));
      elevationRequirement = i.ElevationRequirement or null;
    };
}
