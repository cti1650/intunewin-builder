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
# Download IntuneWinAppUtil (ZIP方式・安定版)
# ==========
Write-Host "Downloading IntuneWinAppUtil (zip)..."

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
  throw "IntuneWinAppUtil.exe not found after extraction."
}

# ==========
# Build intunewin
# ==========
Write-Host "Building intunewin..."
& $toolPath `
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
    if ($intunewin) {
      $newName = "$App-$version.intunewin"
      Rename-Item $intunewin.FullName "output/$newName"
    }
  }
} catch {
  Write-Host "Version rename skipped."
}
