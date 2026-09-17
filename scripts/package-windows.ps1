param(
    [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$PortDir = Join-Path $ProjectDir "port"
$StageDir = Join-Path $ProjectDir "dist/windows/AgentAim"
$Archive = Join-Path $ProjectDir "dist/AgentAim-Windows-x64-$Version.zip"

Push-Location $PortDir
try {
    cargo build --release -p agentaim-windows
    cargo test --workspace
} finally {
    Pop-Location
}

if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force $StageDir | Out-Null
Copy-Item (Join-Path $PortDir "target/release/AgentAim.exe") $StageDir
Copy-Item (Join-Path $PortDir "target/release/AgentAimHook.exe") $StageDir
Copy-Item (Join-Path $ProjectDir "LICENSE") $StageDir
Copy-Item (Join-Path $ProjectDir "WINDOWS.md") $StageDir
Copy-Item (Join-Path $ProjectDir "AGENTS-WINDOWS.md") $StageDir
Copy-Item (Join-Path $ProjectDir "hooks/windows-*.json") $StageDir

if (Test-Path $Archive) { Remove-Item -Force $Archive }
Compress-Archive -Path "$StageDir/*" -DestinationPath $Archive -CompressionLevel Optimal
$Hash = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
"$Hash  $(Split-Path -Leaf $Archive)" | Set-Content -Encoding ascii "$Archive.sha256"
Write-Output $Archive
