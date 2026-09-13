{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "flakedoc";
  version = "0.1.0";

  # An explicit file set rather than lib.cleanSource: the latter keeps target/,
  # so every stray local build ends up copied into the store. templates/ is part
  # of the source proper -- include_dir embeds it at compile time, so leaving it
  # out produces a binary that builds and then renders nothing.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./templates
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Render a Nix flake's extracted documentation into a static site";
    longDescription = ''
      The rendering half of the documentation generator; the extraction half is
      the Nix beside it in docs/, which evaluates a flake into the JSON this
      consumes. Everything it needs is compiled in -- templates, stylesheet,
      syntax grammars and search -- so it runs with no network and no writable
      store, and the site it emits is self-contained with every internal link
      relative. That last part is what lets the result be published under a
      path prefix on GitHub Pages.
    '';
    homepage = "https://github.com/calebstewart/winpkgs";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "flakedoc";
  };
}
