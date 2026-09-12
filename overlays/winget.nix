# nixpkgs attribute -> winget package id. What `home.packages = [ pkgs.git ]`
# means on Windows. `null` records that a package has no Windows build, so the
# error can say so instead of "no mapping".
#
# Grown from use, not curated up front: add an entry when you need it. Every
# name here must exist in nixpkgs (the `packages` flake check enforces it), and
# every id was checked against the winget source when added.
#
# An entry is the id, or `{ id; scope; }` when the manifest's installer works
# at one scope only: "machine" for most MSI/NSIS installers, "user" for the
# rare per-user-only one. A home configuration hands machine-scope packages to
# the system configuration (winpkgs.homes) instead of installing them itself.
# No scope means winget can do either and the kind of configuration decides.
#
# `programDir` says where the installer puts the package's programs, in the
# `%VAR%` form, which is what `pkgs.winpkgs.getExe` needs to name one; the
# program is `meta.mainProgram` from nixpkgs unless the entry gives a
# `mainProgram` of its own. Only worth saying where it is fixed: an installer
# that works at either scope lands in a different place at each.
{
  # shells and terminals
  alacritty = {
    id = "Alacritty.Alacritty";
    scope = "machine";
    programDir = ''%ProgramFiles%\Alacritty'';
  };
  wezterm = "wez.wezterm";
  starship = "Starship.Starship";
  oh-my-posh = "JanDeDobbeleer.OhMyPosh";
  powershell = "Microsoft.PowerShell";

  # editors
  neovim = {
    id = "Neovim.Neovim";
    scope = "machine";
    programDir = ''%ProgramFiles%\Neovim\bin'';
  };
  helix = "Helix.Helix";
  vscode = "Microsoft.VisualStudioCode";
  obsidian = "Obsidian.Obsidian";

  # command line
  git = "Git.Git";
  gh = "GitHub.cli";
  lazygit = "JesseDuffield.lazygit";
  delta = "dandavison.delta";
  ripgrep = "BurntSushi.ripgrep.MSVC";
  fd = "sharkdp.fd";
  bat = "sharkdp.bat";
  eza = "eza-community.eza";
  fzf = "junegunn.fzf";
  zoxide = "ajeetdsouza.zoxide";
  direnv = "direnv.direnv";
  jq = "jqlang.jq";
  glow = "charmbracelet.glow";
  curl = "cURL.cURL";
  _7zz = "7zip.7zip";
  ffmpeg = "Gyan.FFmpeg";
  imagemagick = "ImageMagick.ImageMagick";

  # languages and build
  nodejs = "OpenJS.NodeJS";
  deno = "DenoLand.Deno";
  bun = "Oven-sh.Bun";
  go = "GoLang.Go";
  rustup = "Rustlang.Rustup";
  python3 = "Python.Python.3.13";
  jdk21 = "Microsoft.OpenJDK.21";
  cmake = "Kitware.CMake";

  # desktop
  firefox = "Mozilla.Firefox";
  google-chrome = "Google.Chrome";
  thunderbird = "Mozilla.Thunderbird";
  discord = "Discord.Discord";
  spotify = "Spotify.Spotify";
  vlc = "VideoLAN.VLC";
  obs-studio = "OBSProject.OBSStudio";
  steam = "Valve.Steam";
  _1password-gui = "AgileBits.1Password";
  bitwarden-desktop = "Bitwarden.Bitwarden";
  keepassxc = "KeePassXCTeam.KeePassXC";

  # no Windows build
  tmux = null;
  zsh = null;
}
