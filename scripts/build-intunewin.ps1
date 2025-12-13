param (
  [Parameter(Mandatory)]
  [ValidateSet("chrome", "slack", "warp")]
  [string]$App
)

$ErrorActionPreference = "Stop"

# ==========
# App 定義
# ==========
switch ($App) {
  "chrome" {
    $url   = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
    $setup = "chrome.exe"
  }
  "slack" {
    $url   = "https://slack.com/ssb/download-win64"
    $setup = "slack.exe"
  }
  "warp" {
    $url   = "https://1111-releases.cloudflareclient.com/windows/Cloudflare_WARP_Release-x64.msi"
    $setup = "Cloudflare_WARP_Release-x64.msi"
  }
}

# ==========
# Prepare directories
# ==========
New-Item `
  app, `
  output/intunewin, `
  output/installer `
  -ItemType Directory -Force | Out-Null

# ==========
# Download installer
# ==========
Write-Host "Downloading installer..."
Invoke-WebRequest -Uri $url -OutFile "app/$setup"

# ==========
# Collect installer metadata
# ==========
$file     = Get-Item "app/$setup"
$hash     = Get-FileHash "app/$setup" -Algorithm SHA256
$version  = $file.VersionInfo.FileVersion
$download = (Get-Date).ToUniversalTime().ToString("o")

# ==========
# Download IntuneWinAppUtil (zip, stable)
# ==========
Write-Host "Downloading IntuneWinAppUtil..."

$zipPath  = "IntuneWinAppUtil.zip"
$toolDir  = "IntuneWinAppUtil"
$toolName = "IntuneWinAppUtil.exe"

Invoke-WebRequest `
  -Uri "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip" `
  -OutFile $zipPath

Expand-Archive -Path $zipPath -DestinationPath $toolDir -Force

$toolPath = Get-ChildItem `
  -Path $toolDir `
  -Recurse `
  -Filter $toolName `
  | Select-Object -First 1 `
  | Select-Object -ExpandProperty FullName

if (-not $toolPath) {
  throw "IntuneWinAppUtil.exe not found."
}

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin..."
& $toolPath `
  -c app `
  -s $setup `
  -o output/intunewin `
  -q

# ==========
# Rename intunewin with version
# ==========
$intunewin = Get-ChildItem output/intunewin/*.intunewin | Select-Object -First 1
if ($intunewin -and $version) {
  $newName = "$App-$version.intunewin"
  Rename-Item $intunewin.FullName "output/intunewin/$newName"
}

# ==========
# Save original installer (traceability)
# ==========
Copy-Item "app/$setup" "output/installer/$setup" -Force

# ==========
# Write metadata
# ==========
@"
app: $App
download_url: $url
installer_name: $setup
file_version: $version
sha256: $($hash.Hash)
downloaded_at_utc: $download
"@ | Out-File "output/metadata.txt" -Encoding utf8
