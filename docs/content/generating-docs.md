# How this site is generated

The generator is two halves with a JSON document between them, and it is the
one [StewOS's site](https://calebstew.art/stewos/) is built with, carried into
this repository so that winpkgs' site is built the same way.

`docs/*.nix` evaluates the flake and writes everything it finds to one
`docs.json`: the two option trees, the overlay's package tables, the flake's
outputs and inputs, and the library's doc-comments. `docs/flakedoc/` is a Rust
program that reads that document and writes HTML.

The split is the point. Evaluating a flake is slow, needs the flake's own
inputs, and only Nix can do it; rendering HTML is none of those things. Keeping
a serialized document in between means the renderer can be worked on without
re-evaluating anything.

```console
$ nix build .#docs          # the site, in result/
$ nix run .#docs            # the same, served on http://localhost:8080/
$ nix build .#docs.json     # the document on its own
```

Both halves read `docs/flakedoc.toml`: the Nix half takes the list of option
sets and library namespaces to extract, and `flakedoc` takes the title, the
navigation order and the theme. Hand-written pages are Markdown under
`docs/content/`; the file stem is the page's address and its id in the
navigation order.

The site is built as a flake check, so `nix flake check` fails on an option
without a description or a type -- which is a good deal more than "does it
evaluate". It is published by a GitHub Actions workflow on every push to
`main`, through a Pages deployment rather than a branch, so nothing generated is
ever committed.

## Four things worth knowing before changing it

**Module trees are evaluated against a configuration that does not exist.**
Each tree goes through its real evaluator -- `windowsSystem` or
`homeConfiguration` -- with a stub that sets `winpkgs.name` and nothing else.
Pointing it at a real host instead would work, and would be wrong: an option
whose default reads `config` would then be documented with that host's value
rather than its own default. The options that do read `winpkgs.name`
(`networking.hostName`, `winpkgs.cli.systemName`) carry a `defaultText` so the
stub never shows.

**Options are recognised by where they were declared, not by their name.** An
option belongs to this flake when one of its declarations is a file inside it.
That is what keeps home-manager's thousands of options out of the home set --
they are declared in home-manager's store path -- while keeping the handful
winpkgs adds to home-manager's own namespaces in, such as
{option}`programs.starship.enablePowerShellIntegration`. `excludeOptions` in
`flakedoc.toml` drops the one thing that passes the filter and is not worth a
page: a deprecated alias declared by a directory's `default.nix`.

**Packages are the overlay's tables.** winpkgs builds nothing, so there is no
`meta` to read and no derivation to describe. The [Packages](catalog/index.html)
page reads `overlays/winget.nix`, `overlays/fonts.nix` and
`overlays/portable.nix` as files -- the same tables the overlay applies -- and
takes each name's description from nixpkgs, since a description is the same on
every platform. A portable entry has no nixpkgs counterpart, so it carries its
own `description` and `homepage`, read by nothing else.

**The library reference is only what has a doc-comment.** nixdoc reads RFC-145
doc-comments -- `/** ... */` directly above a binding -- and nothing else, so a
function commented with `#` is not documented badly, it is absent. It also reads
the bindings of a file's top-level attrset, which an overlay's `final: prev:`
body is not; that is why the `pkgs.winpkgs.*` functions live in
`overlays/winpkgs.nix`, a plain attrset the overlay imports, rather than inline.

## The renderer

`flakedoc` is a pure function from JSON to a directory of HTML. Everything it
needs is compiled in -- templates, stylesheet, syntax grammars and search -- so
it runs with no network and no writable store, and nothing on the site it emits
is fetched at view time except its own search index. Two rules shape it: no URL
may start with `/`, because the site is published under a repository subpath,
and prose may cross-reference an option with `` {option}`name` ``, which becomes
a link only when the option actually exists in one of the documented sets.

It is the renderer StewOS uses, plus a catalog page for a flake that installs
packages rather than building them, and a flake page that lists module trees
and configurations by whatever output holds them (`windowsModules`,
`windowsConfigurations`) rather than by a fixed list of kinds.
