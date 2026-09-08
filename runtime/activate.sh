#!/usr/bin/env bash
# Runs inside WSL. Hands the closure at @out@ to the Windows-side runtime, and
# activates the embedded NixOS-WSL system when the closure carries one.
#
# Usage: activate [switch|apply|plan|rollback|generations|wsl] [extra winpkgs.ps1 args]
#   switch       activate the WSL distro (if embedded), then apply Windows   (default)
#   wsl          activate the WSL distro only
#   apply, plan, rollback, generations   Windows side only; passed to winpkgs.ps1
set -euo pipefail

out="@out@"
cmd="${1:-switch}"
if [ $# -gt 0 ]; then shift; fi

if ! command -v wslpath >/dev/null 2>&1; then
  echo "winpkgs: activate must run inside WSL (wslpath not found)" >&2
  exit 1
fi

activate_wsl() {
  if [ ! -e "$out/wsl" ]; then
    echo "winpkgs: this configuration has no embedded WSL system (winpkgs.wsl.enable is off)" >&2
    return 1
  fi
  local target
  target="$(readlink -f "$out/wsl")"
  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then sudo=sudo
    elif command -v doas >/dev/null 2>&1; then sudo=doas
    else echo "winpkgs: need root to activate the WSL system (no sudo or doas)" >&2; return 1; fi
  fi
  echo "winpkgs: activating NixOS-WSL system $target"
  # What nixos-rebuild switch does, minus the evaluation we have already done.
  $sudo nix-env -p /nix/var/nix/profiles/system --set "$target"
  $sudo "$target/bin/switch-to-configuration" switch
}

case "$cmd" in
  wsl)
    activate_wsl
    exit $?
    ;;
  switch)
    if [ -e "$out/wsl" ]; then activate_wsl; fi
    cmd=apply
    ;;
esac

win_out="$(wslpath -w "$out")"
config="$win_out\\config.json"

if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass \
    -File "$win_out\\runtime\\winpkgs.ps1" "$cmd" -Config "$config" "$@"
fi

echo "winpkgs: pwsh.exe not found on the Windows side; bootstrapping with Windows PowerShell" >&2
exec powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$win_out\\runtime\\bootstrap.ps1" -Then "$cmd" -Config "$config" "$@"
