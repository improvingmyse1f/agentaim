#!/bin/zsh
set -euo pipefail

install_root="${AGENTAIM_INSTALL_DIR:-$HOME/Applications}"
app="$install_root/AgentAim.app"
pkill -x AgentAim 2>/dev/null || true
if [[ -d "$app" ]]; then
  rm -rf "$app"
fi
print "Removed $app. User settings were preserved."
