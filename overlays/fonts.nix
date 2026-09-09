# nixpkgs attributes that are fonts: packages whose `share/fonts` is the
# whole point. The overlay marks each with `isFont = true`, which is what lets
# a home configuration tell a font in `home.packages` apart from a program
# that needs a winget mapping. (A system configuration's `fonts.packages` needs
# no mark; being listed there is the declaration.) The whole `nerd-fonts` set
# is marked as well, in default.nix.
#
# Grown from use, like winget.nix, and every name must exist in nixpkgs (the
# `fonts` flake check enforces it). Only fonts that are fetched and copied
# belong here, and each was cross-built once before being added: `pkgs` is a
# Windows cross set, so a font that is *built* from sources -- iosevka through
# npm, jetbrains-mono through gftools' Python, liberation_ttf and ubuntu-sans
# through fontforge -- drags a toolchain into a Windows build that fails, and
# a few (fira, ibm-plex, monaspace) come out of the cross set with nothing
# under share/fonts at all. (JetBrains Mono is `nerd-fonts.jetbrains-mono`
# here.) A consumer marks a font of their own with `pkgs.winpkgs.font pkg`.
[
  # monospace
  "cascadia-code"
  "commit-mono"
  "fira-code"
  "fira-code-symbols"
  "geist-font"
  "hack-font"
  "intel-one-mono"
  "julia-mono"
  "roboto-mono"
  "source-code-pro"
  "victor-mono"

  # text
  "atkinson-hyperlegible"
  "dejavu_fonts"
  "inter"
  "lato"
  "noto-fonts"
  "open-sans"
  "recursive"
  "roboto"
  "source-sans"
  "source-serif"

  # emoji and icons (openmoji is not here: nixpkgs builds it with nanoemoji,
  # an hours-long job)
  "font-awesome"
  "noto-fonts-color-emoji"
  "twemoji-color-font"
]
