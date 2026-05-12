<#
.SYNOPSIS
  src/ ディレクトリの中身を 1 つの .intunewin にパッケージ化する手動用ヘルパ。

.DESCRIPTION
  apps/*.yml を経由しない一発変換向け (docs/windows-quickstart.md の手順を 1 コマンドに圧縮)。
  IntuneWinAppUtil.exe を scripts/.tools/ にキャッシュし、src 直下のインストーラを自動検出して
  -s に渡す。src 直下に .msi / .exe / .msix が複数ある場合は -Setup で明示する。

  実行後、Out 直下に <setup名>.intunewin が生成される。

.PARAMETER Src
  パック対象ディレクトリ。既定: ./src

.PARAMETER Out
  .intunewin 出力先。既定: ./out

.PARAMETER Setup
  エントリポイントファイル名 (Src 直下からの相対)。未指定時は Src 直下の
  .msi / .exe / .msix が 1 件に絞れれば自動採用。

.EXAMPLE
  # ./src に setup.msi だけある場合
  powershell.exe -ExecutionPolicy Bypass -File scripts\pack-local.ps1

.EXAMPLE
  # 別パス・複数インストーラのとき
  powershell.exe -ExecutionPolicy Bypass -File scripts\pack-local.ps1 `
    -Src C:\work\app -Out C:\work\out -Setup installer.exe
#>
param(
  [string]$Src   = './src',
  [string]$Out   = './out',
  [string]$Setup
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/lib.ps1"

# ==========
# Resolve Src / Out
# ==========
if (-not (Test-Path -Path $Src -PathType Container)) {
  New-Item -Path $Src -ItemType Directory -Force | Out-Null
  throw "Src directory '$Src' was empty (just created). Place installer files in it and re-run."
}
New-Item -Path $Out -ItemType Directory -Force | Out-Null

$srcFull = (Resolve-Path -Path $Src).ProviderPath
$outFull = (Resolve-Path -Path $Out).ProviderPath

# ==========
# Determine entry point (hybrid: explicit -Setup wins, else auto-detect single installer)
# ==========
if (-not $Setup) {
  $candidates = Get-ChildItem -Path $srcFull -File -Force |
    Where-Object { @('.msi', '.exe', '.msix') -contains $_.Extension.ToLower() }

  if ($candidates.Count -eq 0) {
    throw "No installer (.msi / .exe / .msix) found in src '$srcFull'. Specify -Setup <filename> or add an installer."
  }
  if ($candidates.Count -gt 1) {
    $names = ($candidates | ForEach-Object Name) -join ', '
    throw "Multiple installers found in src '$srcFull' ($names). Specify one with -Setup <filename>."
  }
  $Setup = $candidates[0].Name
  Write-Host "Auto-detected entry point: $Setup"
}

$setupPath = Join-Path -Path $srcFull -ChildPath $Setup
if (-not (Test-Path -Path $setupPath -PathType Leaf)) {
  throw "Entry point '$Setup' not found in src '$srcFull'."
}

# ==========
# Resolve IntuneWinAppUtil (cached under scripts/.tools/)
# ==========
$cacheDir = Join-Path -Path $PSScriptRoot -ChildPath '.tools'
New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
$toolPath = Get-IntuneWinAppUtilPath -CacheDir $cacheDir

# IntuneWinAppUtil.exe must not live inside Src — it would be embedded into the .intunewin
# (https://learn.microsoft.com/en-us/intune/app-management/deployment/create-win32-package)
$strayTool = Get-ChildItem -Path $srcFull -Filter 'IntuneWinAppUtil.exe' -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($strayTool) {
  throw "IntuneWinAppUtil.exe must not be placed inside src ('$($strayTool.FullName)'). Remove it and re-run."
}

# ==========
# Pack
# ==========
Write-Host "Packing..."
Write-Host "  -c $srcFull"
Write-Host "  -s $Setup"
Write-Host "  -o $outFull"
& $toolPath -c $srcFull -s $Setup -o $outFull -q

$generated = Get-ChildItem -Path $outFull -Filter '*.intunewin' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $generated) {
  throw "IntuneWinAppUtil.exe finished but no .intunewin was found in '$outFull'."
}

$sizeMB = [math]::Round($generated.Length / 1MB, 2)
Write-Host "Created: $($generated.FullName) ($sizeMB MB)"
