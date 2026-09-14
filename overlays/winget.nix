# nixpkgs attribute -> winget package id. What `home.packages = [ pkgs.git ]`
# means on Windows. `null` records that a package has no Windows build, so the
# error can say so instead of "no mapping".
#
# Grown from use, not curated up front: add an entry when you need it. Every
# name here must exist in nixpkgs, every id in the pinned winget-pkgs, and
# every entry's scope must be one winget has an installer for; the `packages`
# flake check enforces all three, and its build log shows what each scope gets.
#
# An entry is the id, or `{ id; scope; }` when the manifest's installer works
# at one scope only: "machine" for most MSI/NSIS installers, "user" for the
# rare per-user-only one. A home configuration hands machine-scope packages to
# the system configuration (winpkgs.homes) instead of installing them itself,
# and a system configuration refuses user-scope ones. No scope means winget
# has an installer at either scope and the kind of configuration decides.
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
  wezterm = {
    id = "wez.wezterm";
    scope = "machine";
  };
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
  # The manifest lists a user installer, but it is the machine one's exe with no
  # /CURRENTUSER, and it elevates itself: asked for user scope, it raises UAC and
  # installs to Program Files anyway.
  git = {
    id = "Git.Git";
    scope = "machine";
    programDir = ''%ProgramFiles%\Git\cmd'';
  };
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
  _7zz = {
    id = "7zip.7zip";
    scope = "machine";
  };
  ffmpeg = "Gyan.FFmpeg";
  imagemagick = {
    id = "ImageMagick.ImageMagick";
    scope = "machine";
  };

  # languages and build
  nodejs = "OpenJS.NodeJS";
  deno = "DenoLand.Deno";
  bun = "Oven-sh.Bun";
  go = {
    id = "GoLang.Go";
    scope = "machine";
  };
  rustup = {
    id = "Rustlang.Rustup";
    scope = "machine";
  };
  python3 = "Python.Python.3.13";
  jdk21 = {
    id = "Microsoft.OpenJDK.21";
    scope = "machine";
  };
  cmake = "Kitware.CMake";

  # desktop
  firefox = {
    id = "Mozilla.Firefox";
    scope = "machine";
  };
  google-chrome = {
    id = "Google.Chrome";
    scope = "machine";
  };
  thunderbird = {
    id = "Mozilla.Thunderbird";
    scope = "machine";
  };
  discord = {
    id = "Discord.Discord";
    scope = "user";
  };
  spotify = {
    id = "Spotify.Spotify";
    scope = "user";
  };
  vlc = "VideoLAN.VLC";
  obs-studio = "OBSProject.OBSStudio";
  steam = {
    id = "Valve.Steam";
    scope = "machine";
  };
  _1password-gui = "AgileBits.1Password";
  bitwarden-desktop = "Bitwarden.Bitwarden";
  keepassxc = {
    id = "KeePassXCTeam.KeePassXC";
    scope = "machine";
  };

  # no Windows build
  tmux = null;
  zsh = null;
}
