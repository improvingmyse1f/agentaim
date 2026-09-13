#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
bundle_dir="$project_dir/dist/AgentAim.app"

cd "$project_dir"
swift build -c release

mkdir -p "$bundle_dir/Contents/MacOS"
mkdir -p "$bundle_dir/Contents/Resources"
cp "$project_dir/.build/release/AgentAim" "$bundle_dir/Contents/MacOS/AgentAim"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
chmod +x "$bundle_dir/Contents/MacOS/AgentAim"
codesign --force --deep --sign - "$bundle_dir"

echo "$bundle_dir"
