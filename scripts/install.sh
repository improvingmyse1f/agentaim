#!/bin/zsh
set -euo pipefail

repository="improvingmyse1f/agentaim"
version="${1:-latest}"
install_root="${AGENTAIM_INSTALL_DIR:-$HOME/Applications}"
app="$install_root/AgentAim.app"

curl_release() {
  curl --proto '=https' --tlsv1.2 -fsSL -H 'User-Agent: AgentAim-Installer' "$@"
}

if [[ "$version" == "latest" ]]; then
  version="preview"
fi
if [[ "$version" == "preview" || "$version" == "stable" ]]; then
  channel_url="https://raw.githubusercontent.com/$repository/main/release-channels/$version"
  version="$(curl_release "$channel_url")"
  version="${version//$'\r'/}"
  version="${version//$'\n'/}"
fi
if [[ "$version" != v* ]]; then
  version="v$version"
fi
[[ "$version" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]] || {
  print -u2 "Invalid release version: $version"
  exit 1
}

asset_version="${version#v}"
archive_url="https://github.com/$repository/releases/download/$version/AgentAim-macOS-$asset_version.zip"
checksum_url="${archive_url}.sha256"

temp_dir="$(mktemp -d)"
staged_app="$install_root/.AgentAim.app.new.$$"
backup_app="$install_root/.AgentAim.app.backup.$$"

cleanup() {
  rm -rf -- "$temp_dir" "$staged_app"
}
trap cleanup EXIT

archive="$temp_dir/AgentAim-macOS.zip"
curl_release "$archive_url" -o "$archive"
curl_release "$checksum_url" -o "$archive.sha256"
expected="$(awk '{print $1}' "$archive.sha256")"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$expected" =~ '^[[:xdigit:]]{64}$' ]] || { print -u2 "Invalid SHA-256 file."; exit 1; }
[[ "$expected" == "$actual" ]] || { print -u2 "SHA-256 verification failed."; exit 1; }

ditto -x -k "$archive" "$temp_dir/unpacked"
unpacked_app="$temp_dir/unpacked/AgentAim.app"
[[ -x "$unpacked_app/Contents/MacOS/AgentAim" ]] || {
  print -u2 "Release does not contain a valid AgentAim app."
  exit 1
}
codesign --verify --deep --strict "$unpacked_app"

mkdir -p "$install_root"
rm -rf -- "$staged_app" "$backup_app"
ditto "$unpacked_app" "$staged_app"
xattr -dr com.apple.quarantine "$staged_app" 2>/dev/null || true

if [[ -e "$app" ]]; then
  mv "$app" "$backup_app"
fi

if ! mv "$staged_app" "$app"; then
  [[ -e "$backup_app" ]] && mv "$backup_app" "$app"
  print -u2 "Installation failed; the previous version was restored."
  exit 1
fi

if ! open "$app"; then
  rm -rf -- "$app"
  [[ -e "$backup_app" ]] && mv "$backup_app" "$app"
  print -u2 "Launch failed; the previous version was restored."
  exit 1
fi

rm -rf -- "$backup_app"
print "Installed $app"
