$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 の Set-Content -Encoding UTF8 は BOM 付きで書き出すため、
# pip の configparser が BOM を [global] セクション名に含めてしまい設定が効かなくなる。
# .npmrc / YAML / TOML も BOM 無しで書くべきなので、全書き込みをこの関数経由に統一する。
function Write-ConfigFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Lines
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

# ============================================================
# Takumi Guard 一括配布 (registry 切替 + 3 日遅延)
# ------------------------------------------------------------
# 各 PM の対応状況 (一次情報で検証済):
#
#   pip / uv / poetry: サーバー側で 3 日 quarantine 自動適用。
#     URL: https://pypi.flatt.tech/simple/
#     Ref: https://shisho.dev/docs/r/202603-takumi-guard-pypi-quarantine/
#
#   npm: .npmrc の min-release-age=<日数の整数> (v11+)
#     Ref: https://docs.npmjs.com/cli/v11/using-npm/config/
#
#   pnpm: .npmrc は registry/auth のみ。minimumReleaseAge は
#     pnpm-workspace.yaml か <user>\AppData\Local\pnpm\config\config.yaml に書く必要。
#     単位は分 (3 日 = 4320 分)。pnpm v11+ の default は 1440 分。
#     Ref: https://pnpm.io/settings
#
#   bun: bunfig.toml の [install].minimumReleaseAge (秒単位、3 日 = 259200)。
#     system-wide パスは無く ~/.bunfig.toml のみ。
#     Ref: https://bun.sh/docs/runtime/bunfig
#
#   yarn (classic & berry): release-age 相当の機能が無い。registry 切替のみ。
# ============================================================

$NpmRegistry = "https://npm.flatt.tech/"
$PipIndexUrl = "https://pypi.flatt.tech/simple/"

$NpmMinReleaseAgeDays    = 3        # npm v11+: 整数日数
$PnpmMinReleaseAgeMin    = 4320     # pnpm v10+: 分単位 (3d)
$BunMinReleaseAgeSec     = 259200   # bun:       秒単位 (3d)

$MarkerDir     = "C:\ProgramData\TakumiGuard"
$MarkerFile    = Join-Path $MarkerDir ".installed"

# system-wide .npmrc — npm / yarn classic が registry を読む。
# pnpm は registry/auth のみ .npmrc から読む。bun も .npmrc から registry を読む。
$NpmConfigDir  = "C:\ProgramData\npm-config"
$NpmConfigFile = Join-Path $NpmConfigDir ".npmrc"

# pip system-wide config
$PipConfigDir  = "C:\ProgramData\pip"
$PipConfigFile = Join-Path $PipConfigDir "pip.ini"

# pnpm / bun は per-user config しか持たないので、Default User と
# 既存ユーザー全員のプロファイルに書き込む。
function Get-TargetUserProfiles {
    # C:\Users\Default は新規ログオン時にユーザーへ複製される雛形
    $defaults = @("C:\Users\Default")
    $existing = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Default","Public","Default User","All Users","WDAGUtilityAccount") } |
        Select-Object -ExpandProperty FullName
    return @($defaults + $existing)
}

function Write-PnpmConfigYaml {
    param([string]$ProfilePath)
    $dir = Join-Path $ProfilePath "AppData\Local\pnpm\config"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $file = Join-Path $dir "config.yaml"
    # registry はファイルレベルでは .npmrc が優先されるが、明示しておく
    Write-ConfigFile -Path $file -Lines @(
        "# Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."
        "registry: $NpmRegistry"
        "minimum-release-age: $PnpmMinReleaseAgeMin"
    )
    Write-Host "  pnpm config -> $file"
}

function Write-BunfigToml {
    param([string]$ProfilePath)
    $file = Join-Path $ProfilePath ".bunfig.toml"
    Write-ConfigFile -Path $file -Lines @(
        "# Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."
        "[install]"
        "registry = `"$NpmRegistry`""
        "minimumReleaseAge = $BunMinReleaseAgeSec"
    )
    Write-Host "  bun config  -> $file"
}

try {
    foreach ($d in @($MarkerDir, $NpmConfigDir, $PipConfigDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
    }

    # ----- system-wide .npmrc (npm / yarn classic / bun が registry, pnpm が registry を読む) -----
    Write-ConfigFile -Path $NpmConfigFile -Lines @(
        "# Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."
        "registry=$NpmRegistry"
        "min-release-age=$NpmMinReleaseAgeDays"
    )
    Write-Host "Wrote $NpmConfigFile"

    [System.Environment]::SetEnvironmentVariable(
        "NPM_CONFIG_GLOBALCONFIG", $NpmConfigFile, "Machine")
    Write-Host "Set system env NPM_CONFIG_GLOBALCONFIG=$NpmConfigFile"

    # ----- yarn berry (registry のみ; release-age 機能無し) -----
    [System.Environment]::SetEnvironmentVariable(
        "YARN_NPM_REGISTRY_SERVER", $NpmRegistry, "Machine")
    Write-Host "Set system env YARN_NPM_REGISTRY_SERVER=$NpmRegistry"

    # ----- pnpm / bun: per-user config を Default + 既存全ユーザーに配布 -----
    Write-Host "Distributing pnpm/bun per-user configs:"
    foreach ($p in Get-TargetUserProfiles) {
        if (Test-Path -LiteralPath $p) {
            try {
                Write-PnpmConfigYaml -ProfilePath $p
                Write-BunfigToml     -ProfilePath $p
            } catch {
                Write-Warning "  Skipped $p : $_"
            }
        }
    }

    # ----- pip / uv / poetry -----
    # pip.ini は BOM があると Python の configparser が [global] セクション名に BOM を
    # 含めてしまい設定が効かない。Write-ConfigFile は BOM 無しで書き出す。
    Write-ConfigFile -Path $PipConfigFile -Lines @(
        "# Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."
        "[global]"
        "index-url = $PipIndexUrl"
    )
    Write-Host "Wrote $PipConfigFile"

    [System.Environment]::SetEnvironmentVariable(
        "PIP_INDEX_URL", $PipIndexUrl, "Machine")
    [System.Environment]::SetEnvironmentVariable(
        "UV_INDEX_URL", $PipIndexUrl, "Machine")
    Write-Host "Set system env PIP_INDEX_URL / UV_INDEX_URL=$PipIndexUrl"

    # ----- marker -----
    Set-Content -LiteralPath $MarkerFile `
        -Value (Get-Date -Format "o") -Encoding UTF8 -Force
    Write-Host "Wrote marker $MarkerFile"

    Write-Output "Takumi Guard applied. Quarantine: pip/uv/poetry=server-side 3d, npm/pnpm/bun=client-side 3d, yarn=registry-only (no release-age support)."
    exit 0
}
catch {
    Write-Error "Takumi Guard install failed: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
