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
    $Releases = Invoke-RestMethod -Headers $Headers "https://api.github.com/repos/$Repository/releases?per_page=10"
    $Release = $Releases | Select-Object -First 1
    if (-not $Release) { throw "The repository does not have a published release yet." }
    $Version = $Release.tag_name
} else {
    $Release = Invoke-RestMethod -Headers $Headers "https://api.github.com/repos/$Repository/releases/tags/$Version"
}

$ZipAsset = $Release.assets | Where-Object { $_.name -match '^AgentAim-Windows-x64-.*\.zip$' } | Select-Object -First 1
$HashAsset = $Release.assets | Where-Object { $_.name -eq ($ZipAsset.name + '.sha256') } | Select-Object -First 1
if (-not $ZipAsset -or -not $HashAsset) { throw "Release $Version does not contain a Windows x64 package and checksum." }

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AgentAim-" + [guid]::NewGuid())
New-Item -ItemType Directory $TempDir | Out-Null
try {
    $ZipPath = Join-Path $TempDir $ZipAsset.name
    $HashPath = "$ZipPath.sha256"
    Invoke-WebRequest -Headers $Headers -Uri $ZipAsset.browser_download_url -OutFile $ZipPath
    Invoke-WebRequest -Headers $Headers -Uri $HashAsset.browser_download_url -OutFile $HashPath
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
