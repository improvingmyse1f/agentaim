#!/bin/zsh
set -euo pipefail

repository="improvingmyse1f/agentaim"
version="${1:-latest}"
install_root="${AGENTAIM_INSTALL_DIR:-$HOME/Applications}"

if [[ "$version" == "latest" ]]; then
  release_json="$(curl -fsSL -H 'User-Agent: AgentAim-Installer' "https://api.github.com/repos/$repository/releases?per_page=1")"
else
  release_json="$(curl -fsSL -H 'User-Agent: AgentAim-Installer' "https://api.github.com/repos/$repository/releases/tags/$version")"
fi

archive_url="$(printf '%s' "$release_json" | sed -n 's/.*"browser_download_url": "\([^"]*AgentAim-macOS[^"/]*\.zip\)".*/\1/p' | head -1)"
checksum_url="${archive_url}.sha256"
[[ -n "$archive_url" ]] || { print -u2 "Release does not contain a macOS package."; exit 1; }

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
archive="$temp_dir/AgentAim-macOS.zip"
curl -fsSL -H 'User-Agent: AgentAim-Installer' "$archive_url" -o "$archive"
curl -fsSL -H 'User-Agent: AgentAim-Installer' "$checksum_url" -o "$archive.sha256"
expected="$(awk '{print $1}' "$archive.sha256")"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || { print -u2 "SHA-256 verification failed."; exit 1; }

ditto -x -k "$archive" "$temp_dir/unpacked"
mkdir -p "$install_root"
rm -rf "$install_root/AgentAim.app"
ditto "$temp_dir/unpacked/AgentAim.app" "$install_root/AgentAim.app"
xattr -dr com.apple.quarantine "$install_root/AgentAim.app" 2>/dev/null || true
open "$install_root/AgentAim.app"
print "Installed $install_root/AgentAim.app"
