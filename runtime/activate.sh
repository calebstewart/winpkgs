#!/usr/bin/env bash
# Runs inside WSL. Hands the closure at @out@ to the Windows-side runtime.
# Usage: activate [plan|apply|rollback|generations] [extra winpkgs.ps1 args]
set -euo pipefail

out="@out@"
cmd="${1:-apply}"
if [ $# -gt 0 ]; then shift; fi

if ! command -v wslpath >/dev/null 2>&1; then
  echo "winpkgs: activate must run inside WSL (wslpath not found)" >&2
  exit 1
fi

win_out="$(wslpath -w "$out")"
config="$win_out\\config.json"

if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass \
    -File "$win_out\\runtime\\winpkgs.ps1" "$cmd" -Config "$config" "$@"
fi

echo "winpkgs: pwsh.exe not found on the Windows side; bootstrapping with Windows PowerShell" >&2
exec powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "$win_out\\runtime\\bootstrap.ps1" -Then "$cmd" -Config "$config" "$@"
