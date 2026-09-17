#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/dist/AgentAim.app"

cd "$project_dir"
swift build -c release

mkdir -p "$bundle_dir/Contents/MacOS"
mkdir -p "$bundle_dir/Contents/Resources"
mkdir -p "$bundle_dir/Contents/Resources/hooks"
cp "$project_dir/.build/release/AgentAim" "$bundle_dir/Contents/MacOS/AgentAim"
cp "$project_dir/.build/release/AgentAimHook" "$bundle_dir/Contents/MacOS/AgentAimHook"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/hooks/codex-hooks.example.json" "$bundle_dir/Contents/Resources/hooks/codex-hooks.example.json"
cp "$project_dir/hooks/claude-settings.example.json" "$bundle_dir/Contents/Resources/hooks/claude-settings.example.json"
cp "$project_dir/hooks/workbuddy-settings.example.json" "$bundle_dir/Contents/Resources/hooks/workbuddy-settings.example.json"
chmod +x "$bundle_dir/Contents/MacOS/AgentAim"
chmod +x "$bundle_dir/Contents/MacOS/AgentAimHook"
codesign --force --deep --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
touch "$bundle_dir"

echo "$bundle_dir"
