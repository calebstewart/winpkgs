# Programs that are not on winget and ship as a plain zip of files: a home
# configuration installs one by copying its files to
# %LOCALAPPDATA%\Programs\<name> and putting that directory on the user's
# PATH. Each entry names a release archive and the hash of its unpacked
# contents (`nix store prefetch-file --unpack <url>`); `flat` says the archive
# has no top-level directory; `mainProgram` names the program `getExe` means,
# when it is not the entry's own name. Bump an entry to update the program.
{
  # https://github.com/amnweb/thide -- hides the taskbar; `thide toggle` from
  # a hotkey brings it back. GUI mode (no arguments) hides it at once.
  thide = {
    version = "0.1.3";
    url = "https://github.com/amnweb/thide/releases/download/v0.1.3/thide-0.1.3-x64-portable.zip";
    hash = "sha256-Jf+81/1f/pjhhH73Z5Ow/j8X83xzXJ/xy+ViJ3+GSdA=";
    flat = true;
  };
}
