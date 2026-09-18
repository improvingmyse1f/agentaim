param(
    [string]$Version = "latest",
    [string]$InstallDir = "$env:LOCALAPPDATA\AgentAim",
    [switch]$LaunchAtLogin,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$Repository = "improvingmyse1f/agentaim"
$Headers = @{ "User-Agent" = "AgentAim-Installer" }

if ($Version -eq "latest") {
    $Version = "preview"
}
if ($Version -eq "preview" -or $Version -eq "stable") {
    $ChannelUrl = "https://raw.githubusercontent.com/$Repository/main/release-channels/$Version"
    $Version = (Invoke-WebRequest -Headers $Headers -Uri $ChannelUrl).Content.Trim()
}
if (-not $Version.StartsWith("v")) { $Version = "v$Version" }
if ($Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}

$AssetVersion = $Version.Substring(1)
$ZipName = "AgentAim-Windows-x64-$AssetVersion.zip"
$ZipUrl = "https://github.com/$Repository/releases/download/$Version/$ZipName"
$HashUrl = "$ZipUrl.sha256"

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AgentAim-" + [guid]::NewGuid())
New-Item -ItemType Directory $TempDir | Out-Null
try {
    $ZipPath = Join-Path $TempDir $ZipName
    $HashPath = "$ZipPath.sha256"
    Invoke-WebRequest -Headers $Headers -Uri $ZipUrl -OutFile $ZipPath
    Invoke-WebRequest -Headers $Headers -Uri $HashUrl -OutFile $HashPath
    $Expected = ((Get-Content $HashPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 $ZipPath).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA-256 verification failed. Expected $Expected, got $Actual." }

    Get-Process AgentAim -ErrorAction SilentlyContinue | Stop-Process -Force
    $Expanded = Join-Path $TempDir "expanded"
    Expand-Archive -Path $ZipPath -DestinationPath $Expanded
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Copy-Item "$Expanded/*" $InstallDir -Recurse -Force

    $StartMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    $ShortcutPath = Join-Path $StartMenu "AgentAim.lnk"
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = Join-Path $InstallDir "AgentAim.exe"
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Save()

    $StartupFile = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\AgentAim.cmd"
    if ($LaunchAtLogin) {
        "@start `"`" `"$(Join-Path $InstallDir 'AgentAim.exe')`"" | Set-Content -Encoding ascii $StartupFile
    }
    if (-not $NoStart) { Start-Process (Join-Path $InstallDir "AgentAim.exe") }
    Write-Output "AgentAim $Version installed in $InstallDir"
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
