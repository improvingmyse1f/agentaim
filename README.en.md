<p align="center">
  <img src="Design/agentaim-app-icon-v2.png" width="128" alt="AgentAim icon">
</p>

<h1 align="center">AgentAim</h1>

<p align="center"><strong>Turn AI coding wait time into aim practice.</strong></p>

<p align="center">
  <a href="README.md">简体中文</a> · English
</p>

<p align="center">
  <a href="https://github.com/improvingmyse1f/agentaim/actions/workflows/ci.yml"><img src="https://github.com/improvingmyse1f/agentaim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/improvingmyse1f/agentaim/releases">Download preview</a> ·
  <a href="https://github.com/improvingmyse1f/agentaim/issues/new/choose">Report an issue</a> ·
  <a href="ROADMAP.md">Roadmap</a>
</p>

AgentAim is an open-source, native desktop aim trainer for the moments when Codex, Claude Code,
WorkBuddy, or another coding agent is working. It does not inspect game windows, control a game,
or provide aim assistance.

> [!NOTE]
> This is a public preview. The macOS release currently supports Apple Silicon only. The Windows
> release supports Windows 10 22H2 and Windows 11 x64. Release binaries are not commercially
> code-signed, so macOS Gatekeeper or Windows SmartScreen may show a warning.

## Why AgentAim

- Starts from the app menu, or shows a small confirmation ring when an agent begins working.
- Requires a two-second hover before an automatic trigger can take over the screen.
- Exits immediately with `Esc`, `Q`, or right-click; 90 seconds of inactivity is the final fallback.
- Matches VALORANT and Counter-Strike 2 sensitivity; DPI is optional and only used for `cm/360`.
- Requests no Accessibility, Input Monitoring, or Screen Recording permissions on macOS.
- Keeps automatic training and launch-at-login disabled by default.

## Install on macOS

### For people

1. Download `AgentAim-macOS-<version>.zip` from
   [GitHub Releases](https://github.com/improvingmyse1f/agentaim/releases).
2. Extract it and move `AgentAim.app` to Applications.
3. Try to open it once. If Gatekeeper blocks it, open **System Settings → Privacy & Security**,
   scroll to Security, choose **Open Anyway**, and confirm with your login password.

The current macOS interface is primarily Simplified Chinese. English UI localization is tracked in
the [roadmap](ROADMAP.md).

### For an agent

Run this only after the user explicitly agrees to install an unsigned and unnotarized build:

```bash
curl -fsSL https://raw.githubusercontent.com/improvingmyse1f/agentaim/main/scripts/install.sh | zsh
```

The installer downloads the latest GitHub Release, verifies its SHA-256, installs it to
`~/Applications/AgentAim.app`, removes quarantine from that app, and opens it. It does not use
`sudo` or install agent hooks. During an update it keeps the previous app until the new copy has
been installed and a launch request succeeds, and restores the previous version on failure.

The default channel is `preview`. An agent can also pin an exact version:

```bash
./scripts/install.sh v0.1.0-preview.1
```

After installation, tell the user that `Esc` exits training. If pointer input ever appears stuck,
run `killall AgentAim` in Terminal.

## Install on Windows

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/improvingmyse1f/agentaim/main/scripts/install-windows.ps1 | iex
```

The installer places AgentAim in `%LOCALAPPDATA%\AgentAim`, creates a Start Menu shortcut, and
launches it without administrator privileges. See [WINDOWS.md](WINDOWS.md) for details.

## Optional agent integration

AgentAim includes hook templates for Codex, Claude Code, and WorkBuddy. Hooks are never installed
silently. They forward only allowlisted lifecycle metadata over a private local socket and exclude
prompts, transcripts, tool inputs, tool outputs, working directories, and error text.

See the Chinese [README](README.md) and [AGENTS.md](AGENTS.md) for the full integration and safety
contract.

## Build and test

macOS:

```bash
swift test
./scripts/package.sh
```

Portable Rust core and Windows shell:

```bash
cd port
cargo test --workspace
```

Gameplay changes must update and verify the shared fixture in `fixtures/gameplay-v1.json`.

## Project documents

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Roadmap](ROADMAP.md)
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE)
