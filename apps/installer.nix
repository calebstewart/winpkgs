# `nix run winpkgs#installer`: the boot media for a flake's Windows
# configurations, in one command, from a NixOS host or from the distro.
#
# `mkWindowsInstaller` works end to end but asks for a hand-written expression,
# a Windows ISO added to the store under the right name and hash, and knowing
# which output to build. This does those parts: it hashes and adds the media,
# evaluates the installer through the flake's *own* winpkgs input
# (installer-driver.nix), builds the ISO, copies it out, and leaves nothing
# rooted -- or, unless asked otherwise, present -- in the store. `winpkgs
# installer` on Windows is a thin wrapper that runs this in the distro, so
# there is one implementation.
{ pkgs }:
pkgs.writeShellApplication {
  name = "winpkgs-installer";
  # nix itself is deliberately not here: the one on PATH is the client of this
  # machine's daemon, and that is the one whose store the media goes into.
  runtimeInputs = [
    pkgs.jq
    pkgs.coreutils
  ];
  meta.description = "Build boot media that installs Windows and applies a flake's configuration to it";
  text = ''
    usage() {
      cat <<'EOF'
    winpkgs-installer: boot media that installs Windows and applies a flake's configuration to it.

      winpkgs-installer --windows-iso <file> [--flake <ref>] [--system <name>] [--home <name>] [--out <file>] [options]

    Your Windows ISO with an answer file and the two configurations added. The
    ISO is put in the Nix store once (a rebuild finds it there), the installer is
    built by the flake's own winpkgs input, and the result is copied to --out.
    Nothing is left rooted in the store.

      --windows-iso <file>    the Windows ISO, from microsoft.com/software-download/windows11 (required)
      --out <file>            where the finished ISO goes (default: ./winpkgs-installer-<system>.iso)
      --flake <ref>           the flake with the configurations (default: .)
      --system <name>         windowsConfigurations.<name> (default: the only one)
      --home <name>           windowsHomeConfigurations."<name>" (default: the only <user>@<system>)
      --wsl-rootfs <file>     the NixOS-WSL image a system with wsl.enable imports (default: a pinned release, downloaded)

      --edition <name>        the image in install.wim to install (default: Windows 11 Pro)
      --product-key <key>     default: none; the edition alone selects the image
      --locale <tag>          default: en-US
      --disk-id <n>           the disk Setup wipes and installs to (default: 0)

      --keep-result           leave the built ISO in the store too, and print its path
      --delete-windows-iso    delete the Windows ISO from the store afterwards (default: keep it for the next build)
      --winpkgs-input <name>  the flake's winpkgs input (default: winpkgs)
      --help
    EOF
    }

    die() { echo "winpkgs installer: $*" >&2; exit 1; }
    value() { [ $# -ge 2 ] || die "$1 needs a value; see --help"; }

    windowsIso=""
    out=""
    flake=.
    system=""
    home=""
    wslRootfs=""
    edition=""
    productKey=""
    locale=""
    diskId=""
    keepResult=false
    deleteWindowsIso=false
    winpkgsInput=winpkgs
    while [ $# -gt 0 ]; do
      case "$1" in
        --windows-iso) value "$@"; windowsIso=$2; shift 2 ;;
        --out) value "$@"; out=$2; shift 2 ;;
        --flake) value "$@"; flake=$2; shift 2 ;;
        --system) value "$@"; system=$2; shift 2 ;;
        --home) value "$@"; home=$2; shift 2 ;;
        --wsl-rootfs) value "$@"; wslRootfs=$2; shift 2 ;;
        --edition) value "$@"; edition=$2; shift 2 ;;
        --product-key) value "$@"; productKey=$2; shift 2 ;;
        --locale) value "$@"; locale=$2; shift 2 ;;
        --disk-id) value "$@"; diskId=$2; shift 2 ;;
        --keep-result) keepResult=true; shift ;;
        --delete-windows-iso) deleteWindowsIso=true; shift ;;
        --winpkgs-input) value "$@"; winpkgsInput=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1'; see --help" ;;
      esac
    done

    [ -n "$windowsIso" ] || die "--windows-iso <file> is required: the Windows ISO to build on, from https://www.microsoft.com/software-download/windows11"
    [ -f "$windowsIso" ] || die "no such file: $windowsIso"
    [ -z "$wslRootfs" ] || [ -f "$wslRootfs" ] || die "no such file: $wslRootfs"
    if [ -n "$diskId" ] && ! [[ $diskId =~ ^[0-9]+$ ]]; then die "--disk-id takes a number, not '$diskId'"; fi
    # builtins.getFlake wants an absolute path or a URL, never `.`; anything
    # that is not a directory here (github:..., git+https:...) is a URL already.
    if [ -d "$flake" ]; then flake=$(realpath "$flake"); fi
    command -v nix > /dev/null || die "nix is not on PATH"

    # Puts a file in the store the way requireFile will look for it -- by its
    # own name and its content hash -- and remembers both. Hashing is one read
    # of the file, which is how it knows whether the copy can be skipped; the
    # first add reads it once more and copies. A Windows ISO is eight
    # gigabytes, so this says what it is doing.
    added_path=""
    added_hash=""
    add_to_store() {
      local file=$1 name
      name=$(basename "$file")
      echo "hashing $name ($(du -h "$file" | cut -f1); a Windows ISO takes a few minutes)" >&2
      added_hash=$(nix-hash --flat --type sha256 --base32 "$file")
      added_path=$(nix-store --print-fixed-path sha256 "$added_hash" "$name")
      if nix-store --check-validity "$added_path" 2> /dev/null; then
        echo "$name is in the store already: $added_path" >&2
      else
        echo "copying $name into the store" >&2
        nix-store --add-fixed sha256 "$file" > /dev/null
      fi
    }

    add_to_store "$windowsIso"
    isoPath=$added_path
    isoHash=$added_hash
    rootfsName=""
    rootfsHash=""
    if [ -n "$wslRootfs" ]; then
      add_to_store "$wslRootfs"
      rootfsName=$(basename "$wslRootfs")
      rootfsHash=$added_hash
    fi

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    # Only what was given goes into `setup`, so mkWindowsInstaller's own
    # defaults apply to the rest.
    jq -n \
      --arg flake "$flake" --arg input "$winpkgsInput" \
      --arg system "$system" --arg home "$home" \
      --arg isoName "$(basename "$windowsIso")" --arg isoHash "$isoHash" \
      --arg rootfsName "$rootfsName" --arg rootfsHash "$rootfsHash" \
      --arg edition "$edition" --arg productKey "$productKey" \
      --arg locale "$locale" --arg diskId "$diskId" \
      '{
        flake: $flake,
        winpkgsInput: $input,
        args: {
          system: (if $system == "" then null else $system end),
          home: (if $home == "" then null else $home end),
          windowsIso: { name: $isoName, sha256: $isoHash },
          wslRootfs: (if $rootfsName == "" then null else { name: $rootfsName, sha256: $rootfsHash } end),
          setup: ({}
            + (if $edition == "" then {} else { edition: $edition } end)
            + (if $productKey == "" then {} else { productKey: $productKey } end)
            + (if $locale == "" then {} else { locale: $locale } end)
            + (if $diskId == "" then {} else { diskId: ($diskId | tonumber) } end))
        }
      }' > "$work/args.json"

    # Evaluated on its own before anything is built, so that a pair
    # mkWindowsInstaller refuses -- a home whose machine-wide packages no
    # system installs, Widgets under UCPD, a host name too long -- is reported
    # in its own words, not from under nix's trace of how it got there.
    echo "evaluating $flake" >&2
    if ! summary=$(nix eval --impure --json --file ${./installer-driver.nix} \
        --argstr argsFile "$work/args.json" summary 2> "$work/eval.log"); then
      if grep -q 'error: winpkgs:' "$work/eval.log"; then
        sed -n '/error: winpkgs:/,$p' "$work/eval.log" | sed 's/^       //' >&2
      else
        cat "$work/eval.log" >&2
      fi
      exit 1
    fi
    drv=$(jq -r .drvPath <<< "$summary")
    systemName=$(jq -r .system <<< "$summary")
    homeName=$(jq -r .home <<< "$summary")
    wsl=$(jq -r .wsl <<< "$summary")

    [ -n "$out" ] || out="$PWD/winpkgs-installer-$systemName.iso"
    outDir=$(dirname "$out")
    [ -d "$outDir" ] || die "the directory for --out does not exist: $outDir"

    echo >&2
    echo "building the installer for windowsConfigurations.$systemName and windowsHomeConfigurations.\"$homeName\"" >&2
    [ "$wsl" != true ] || echo "with the machine's WSL distro on the media" >&2
    echo "(around 10 GB in the store while it builds; the result is copied to $out)" >&2
    result=$(nix build --no-link --print-out-paths "$drv^out")

    # Under a name that a cut-short copy cannot be mistaken for.
    echo "copying to $out" >&2
    cp "$result" "$out.part"
    mv -f "$out.part" "$out"
    [ "$(stat -c %s "$out")" = "$(stat -c %s "$result")" ] || die "the copy at $out is the wrong size"

    if [ "$keepResult" = true ]; then
      echo "kept in the store: $result" >&2
    else
      # Unrooted, but ten gigabytes until the next collection, and every
      # rebuild adds another; the copy is the result now.
      nix store delete "$result" > /dev/null 2>&1 \
        || echo "could not delete $result from the store (something roots it); nix-collect-garbage will" >&2
    fi
    if [ "$deleteWindowsIso" = true ]; then
      nix store delete "$isoPath" > /dev/null 2>&1 \
        || echo "could not delete $isoPath from the store (something roots it)" >&2
    fi
    echo "$out"
  '';
}
