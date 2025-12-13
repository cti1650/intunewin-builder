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
# Prepare
# ==========
New-Item app, output -ItemType Directory -Force | Out-Null

Write-Host "Downloading installer..."
Invoke-WebRequest -Uri $url -OutFile "app/$setup"

# ==========
# Intune Tool
# ==========
$tool = "IntuneWinAppUtil.exe"

Write-Host "Downloading IntuneWinAppUtil..."
Invoke-WebRequest `
  -Uri "https://aka.ms/IntuneWinAppUtil" `
  -OutFile $tool

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin..."
.\$tool `
  -c app `
  -s $setup `
  -o output `
  -q

# ==========
# Rename with version (best effort)
# ==========
try {
  $file = Get-Item "app/$setup"
  $version = $file.VersionInfo.FileVersion
  if ($version) {
    $intunewin = Get-ChildItem output/*.intunewin | Select-Object -First 1
    $newName = "$App-$version.intunewin"
    Rename-Item $intunewin.FullName "output/$newName"
  }
} catch {
  Write-Host "Version rename skipped."
}

