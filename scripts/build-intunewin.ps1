param (
  [Parameter(Mandatory)]
  [string]$App
)

$ErrorActionPreference = "Stop"

Write-Host "Building intunewin for app: $App"

# ==========
# Load app definition
# ==========
$appDefPath = "apps/$App.yml"
if (-not (Test-Path $appDefPath)) {
  throw "App definition not found: $appDefPath"
}

$appDef = Get-Content $appDefPath | ConvertFrom-Yaml

$url   = $appDef.download.url
$setup = $appDef.download.file

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
$file        = Get-Item "app/$setup"
$hash        = Get-FileHash "app/$setup" -Algorithm SHA256
$version     = $file.VersionInfo.FileVersion
if (-not $version) {
  $version = "unknown"
}
$downloadUtc = (Get-Date).ToUniversalTime().ToString("o")

# ==========
# Download IntuneWinAppUtil
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
# Rename intunewin
# ==========
$intunewin = Get-ChildItem output/intunewin/*.intunewin | Select-Object -First 1
if ($intunewin) {
  $newName = "$($appDef.name)-$version.intunewin"
  Rename-Item -Path $intunewin.FullName -NewName $newName
}

# ==========
# Save original installer
# ==========
Copy-Item "app/$setup" "output/installer/$setup" -Force

# ==========
# Write metadata
# ==========
@"
app: $($appDef.name)
download_url: $url
installer_name: $setup
file_version: $version
sha256: $($hash.Hash)
downloaded_at_utc: $downloadUtc
"@ | Out-File "output/metadata.txt" -Encoding utf8

Write-Host "Build completed successfully"
