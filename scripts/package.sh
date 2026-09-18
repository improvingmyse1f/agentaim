#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/dist/AgentAim.app"
source_plist="$project_dir/Resources/Info.plist"
version="${AGENTAIM_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_plist")}"
build_number="${AGENTAIM_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_plist")}"

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "AGENTAIM_VERSION must use x.y.z format."
  exit 1
}
[[ "$build_number" =~ '^[0-9]+$' ]] || {
  print -u2 "AGENTAIM_BUILD_NUMBER must be an integer."
  exit 1
}

cd "$project_dir"
swift build -c release

rm -rf -- "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS"
mkdir -p "$bundle_dir/Contents/Resources"
mkdir -p "$bundle_dir/Contents/Resources/hooks"
cp "$project_dir/.build/release/AgentAim" "$bundle_dir/Contents/MacOS/AgentAim"
cp "$project_dir/.build/release/AgentAimHook" "$bundle_dir/Contents/MacOS/AgentAimHook"
cp "$source_plist" "$bundle_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/hooks/codex-hooks.example.json" "$bundle_dir/Contents/Resources/hooks/codex-hooks.example.json"
cp "$project_dir/hooks/claude-settings.example.json" "$bundle_dir/Contents/Resources/hooks/claude-settings.example.json"
cp "$project_dir/hooks/workbuddy-settings.example.json" "$bundle_dir/Contents/Resources/hooks/workbuddy-settings.example.json"
chmod +x "$bundle_dir/Contents/MacOS/AgentAim"
chmod +x "$bundle_dir/Contents/MacOS/AgentAimHook"
codesign --force --sign - "$bundle_dir/Contents/MacOS/AgentAim"
codesign --force --sign - "$bundle_dir/Contents/MacOS/AgentAimHook"
codesign --force --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
touch "$bundle_dir"

print "$bundle_dir ($version, build $build_number)"
