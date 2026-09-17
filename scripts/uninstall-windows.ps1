param(
    [string]$InstallDir = "$env:LOCALAPPDATA\AgentAim"
)

$ErrorActionPreference = "Stop"
Get-Process AgentAim -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AgentAim.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\AgentAim.cmd") -Force -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
Write-Output "AgentAim removed. User settings in $env:APPDATA\AgentAim were preserved."
