$ErrorActionPreference = "Stop"

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
#   yarn berry 4.10+: npmMinimalAgeGate ("3d" 形式の文字列, 2025-09 追加)。
#     .yarnrc.yml の global パスは per-user (~/.yarnrc.yml) しか無いので、
#     Machine env YARN_NPM_MINIMAL_AGE_GATE で全ユーザーに強制する。
#     Ref: https://yarnpkg.com/configuration/yarnrc#npmMinimalAgeGate
#   yarn classic (1.x): release-age 機能なし。registry 切替のみ。
#
# 既存ファイルの取り扱い:
#   - 既存の競合キーは "# [TakumiGuard-disabled] " prefix で無効化 (削除はしない)
#   - 自分の追記は "# === BEGIN/END TakumiGuard ===" ブロックで囲む
#   - uninstall.ps1 でブロック削除 + disabled prefix 剥がしで元に戻せる
# ============================================================

# ============================================================
# Helper-scope constants (referenced from helper functions; safe to load
# on Linux pwsh for Pester testing — no Windows-specific paths here)
# ============================================================

$MARKER_DISABLED = "# [TakumiGuard-disabled] "
$BLOCK_BEGIN     = "# === BEGIN TakumiGuard ==="
$BLOCK_END       = "# === END TakumiGuard ==="

# ============================================================
# Helper functions (uninstall.ps1 と共通; .intunewin に同梱できる .ps1 は
# install.ps1 / uninstall.ps1 のみのためインライン重複)
# ============================================================

function Write-FileNoBom {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

function Read-LinesOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return @(Get-Content -LiteralPath $Path)
    }
    return @()
}

# 既存の BEGIN/END ブロック (および中身) を完全に取り除く
function Remove-ManagedBlock {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $Lines) {
        $t = $line.TrimEnd()
        if (-not $inBlock -and $t -eq $BLOCK_BEGIN) { $inBlock = $true; continue }
        if ($inBlock -and $t -eq $BLOCK_END) { $inBlock = $false; continue }
        if (-not $inBlock) { $out.Add($line) }
    }
    return ,@($out.ToArray())
}

# "# [TakumiGuard-disabled] foo=bar" → "foo=bar" に戻す
function Restore-DisabledLines {
    param([string[]]$Lines)
    return ,@($Lines | ForEach-Object {
        if ($_.StartsWith($MARKER_DISABLED)) {
            $_.Substring($MARKER_DISABLED.Length)
        } else {
            $_
        }
    })
}

# 指定セクション (空文字なら top-level) 内で、Keys に一致する行を disabled prefix 付き
# のコメントに置換する。
function Disable-MatchingKeys {
    param(
        [string[]]$Lines,
        [string]$Section,
        [string[]]$Keys,
        [string]$Separator     # "=" or ":"
    )
    $keyAlt = ($Keys | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $sepEsc = [regex]::Escape($Separator)
    # top-level 指定 (Section が "") のときは先頭にインデント許可しない (YAML のネストキーを誤検出しないため)
    $lead = if ($Section) { "\s*" } else { "" }
    $keyPattern = "^${lead}($keyAlt)\s*$sepEsc"

    $inSection = ($Section -eq "")
    $headerStr = if ($Section) { "[$Section]" } else { "" }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if ($Section -and $t -match '^\[[^\]]+\]$') {
            $inSection = ($t -eq $headerStr)
            $out.Add($line)
            continue
        }
        if ($inSection -and $line -match $keyPattern) {
            $out.Add($MARKER_DISABLED + $line)
        } else {
            $out.Add($line)
        }
    }
    return ,@($out.ToArray())
}

# 管理ブロックを末尾 (または該当セクションの直下) に挿入。
function Add-ManagedBlock {
    param(
        [string[]]$Lines,
        [string]$Section,
        [System.Collections.Specialized.OrderedDictionary]$Settings,
        [string]$Separator     # "=" or " = " or ": "
    )
    $inner = New-Object System.Collections.Generic.List[string]
    $inner.Add($BLOCK_BEGIN)
    foreach ($k in $Settings.Keys) {
        $inner.Add("$k$Separator$($Settings[$k])")
    }
    $inner.Add($BLOCK_END)

    if (-not $Section) {
        return ,@(@($Lines) + @($inner.ToArray()))
    }

    # 既存のセクションヘッダ直下に挿入。なければ末尾にセクションごと追加。
    $sectionHeader = "[$Section]"
    $idx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $sectionHeader) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $head = $Lines[0..$idx]
        $tail = if ($idx + 1 -lt $Lines.Count) { $Lines[($idx + 1)..($Lines.Count - 1)] } else { @() }
        return ,@(@($head) + @($inner.ToArray()) + @($tail))
    }
    $appended = @($Lines)
    if ($appended.Count -gt 0 -and $appended[-1].Trim() -ne "") { $appended += "" }
    $appended += $sectionHeader
    $appended += @($inner.ToArray())
    return ,@($appended)
}

function Apply-ManagedConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Section,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Settings,
        [Parameter(Mandatory)][string]$Separator
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $lines = Read-LinesOrEmpty $Path
    $lines = Remove-ManagedBlock -Lines $lines
    $lines = Restore-DisabledLines -Lines $lines
    $lines = Disable-MatchingKeys -Lines $lines -Section $Section `
        -Keys @($Settings.Keys) -Separator $Separator.Trim()
    $lines = Add-ManagedBlock -Lines $lines -Section $Section `
        -Settings $Settings -Separator $Separator
    Write-FileNoBom -Path $Path -Lines $lines
    Write-Host "  $Path"
}

# uv.toml 専用 (TOML array-of-tables [[index]] 構文。Apply-ManagedConfig の
# 単一 [section] モデルでは扱えないため別 helper)。
# 既存の `default = true` は disabled prefix でコメントアウトし、自分の
# [[index]] エントリを default = true で末尾に追記する。
function Apply-UvIndex {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $lines = Read-LinesOrEmpty $Path
    $lines = Remove-ManagedBlock -Lines $lines
    $lines = Restore-DisabledLines -Lines $lines

    # 既存の `default = true` をコメントアウト (`default = false` は触らない)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*default\s*=\s*true\b') {
            $out.Add($MARKER_DISABLED + $line)
        } else {
            $out.Add($line)
        }
    }
    $appended = @($out.ToArray())

    # 末尾に [[index]] ブロック (BEGIN/END で囲む)
    if ($appended.Count -gt 0 -and $appended[-1].Trim() -ne "") { $appended += "" }
    $appended += $BLOCK_BEGIN
    $appended += "[[index]]"
    $appended += "url = `"$Url`""
    $appended += "default = true"
    $appended += $BLOCK_END

    Write-FileNoBom -Path $Path -Lines $appended
    Write-Host "  $Path"
}

function Get-TargetUserProfiles {
    $defaults = @("C:\Users\Default")
    $existing = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Default","Public","Default User","All Users","WDAGUtilityAccount") } |
        Select-Object -ExpandProperty FullName
    return @($defaults + $existing)
}

# ============================================================
# Main
# ============================================================
# Pester から `. ./install.ps1` で dot-source されたときは helper だけ
# 露出させ main を実行しないようにする (Linux pwsh で C:\ パスを評価できないため)。
# Intune 実行 (powershell.exe -File install.ps1) では InvocationName は
# script のパスになるので main が走る。
if ($MyInvocation.InvocationName -eq '.') { return }

# Windows-only path constants. Top-level に置くと Linux pwsh の Join-Path が
# "drive 'C' does not exist" で死ぬので guard の内側に置く。
$NpmRegistry = "https://npm.flatt.tech/"
$PipIndexUrl = "https://pypi.flatt.tech/simple/"

$NpmMinReleaseAgeDays = 3        # npm v11+: 整数日数
$PnpmMinReleaseAgeMin = 4320     # pnpm v10+: 分単位 (3d)
$BunMinReleaseAgeSec  = 259200   # bun:       秒単位 (3d)

$MarkerDir     = "C:\ProgramData\TakumiGuard"
$MarkerFile    = Join-Path $MarkerDir ".installed"
$NpmConfigDir  = "C:\ProgramData\npm-config"
$NpmConfigFile = Join-Path $NpmConfigDir ".npmrc"
$PipConfigDir  = "C:\ProgramData\pip"
$PipConfigFile = Join-Path $PipConfigDir "pip.ini"

try {
    foreach ($d in @($MarkerDir, $NpmConfigDir, $PipConfigDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
    }

    # ----- system-wide .npmrc (no section, '=' separator) -----
    Write-Host "Applying .npmrc:"
    Apply-ManagedConfig -Path $NpmConfigFile -Section "" `
        -Settings ([ordered]@{
            "registry"        = $NpmRegistry
            "min-release-age" = $NpmMinReleaseAgeDays
        }) -Separator "="

    [System.Environment]::SetEnvironmentVariable(
        "NPM_CONFIG_GLOBALCONFIG", $NpmConfigFile, "Machine")
    Write-Host "Set system env NPM_CONFIG_GLOBALCONFIG=$NpmConfigFile"

    # ----- yarn berry (registry + npmMinimalAgeGate; yarn 4.10+ で release-age 対応) -----
    [System.Environment]::SetEnvironmentVariable(
        "YARN_NPM_REGISTRY_SERVER", $NpmRegistry, "Machine")
    Write-Host "Set system env YARN_NPM_REGISTRY_SERVER=$NpmRegistry"
    # yarn の npmMinimalAgeGate は "3d" のような duration 文字列を受ける
    [System.Environment]::SetEnvironmentVariable(
        "YARN_NPM_MINIMAL_AGE_GATE", "3d", "Machine")
    Write-Host "Set system env YARN_NPM_MINIMAL_AGE_GATE=3d"

    # ----- pnpm / bun: per-user config を Default + 既存全ユーザーに配布 -----
    Write-Host "Applying pnpm/bun per-user configs:"
    foreach ($p in Get-TargetUserProfiles) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            # pnpm は registry/auth を INI (.npmrc 互換) から、それ以外を YAML
            # (pnpm-workspace.yaml or config.yaml) から読む二分体制。公式
            # takumi-guard-setup-0.4.0.ps1 と同じく registry は rc (INI) に書く。
            Apply-ManagedConfig `
                -Path (Join-Path $p "AppData\Local\pnpm\config\rc") `
                -Section "" `
                -Settings ([ordered]@{
                    "registry" = $NpmRegistry
                }) -Separator "="

            # minimumReleaseAge は config.yaml (YAML) の方に置く
            Apply-ManagedConfig `
                -Path (Join-Path $p "AppData\Local\pnpm\config\config.yaml") `
                -Section "" `
                -Settings ([ordered]@{
                    "minimum-release-age" = $PnpmMinReleaseAgeMin
                }) -Separator ": "

            Apply-ManagedConfig `
                -Path (Join-Path $p ".bunfig.toml") `
                -Section "install" `
                -Settings ([ordered]@{
                    # 公式 takumi-guard-setup-0.4.0.ps1 と同じ object 形式。
                    # token なしの anonymous でも { url = "..." } で書く方が
                    # 将来 token 追加するときに upgrade パスが素直になる。
                    "registry"          = "{ url = `"$NpmRegistry`" }"
                    "minimumReleaseAge" = $BunMinReleaseAgeSec
                }) -Separator " = "

            # pip per-user: pip の優先順位は site > user > global なので
            # system-wide pip.ini だけだと user に何か書かれていると負ける。
            # 各ユーザーの %APPDATA%\pip\pip.ini にも管理ブロックを置く。
            Apply-ManagedConfig `
                -Path (Join-Path $p "AppData\Roaming\pip\pip.ini") `
                -Section "global" `
                -Settings ([ordered]@{
                    "index-url" = $PipIndexUrl
                }) -Separator " = "

            # uv per-user: env だけだと CLI flag / project の pyproject.toml の
            # [tool.uv.sources] で容易に override される。file 配置で強度を上げる。
            Apply-UvIndex `
                -Path (Join-Path $p "AppData\Roaming\uv\uv.toml") `
                -Url $PipIndexUrl
        } catch {
            Write-Warning "  Skipped $p : $_"
        }
    }

    # ----- pip / uv / poetry -----
    Write-Host "Applying pip.ini:"
    Apply-ManagedConfig -Path $PipConfigFile -Section "global" `
        -Settings ([ordered]@{
            "index-url" = $PipIndexUrl
        }) -Separator " = "

    [System.Environment]::SetEnvironmentVariable(
        "PIP_INDEX_URL", $PipIndexUrl, "Machine")
    [System.Environment]::SetEnvironmentVariable(
        "UV_INDEX_URL", $PipIndexUrl, "Machine")
    Write-Host "Set system env PIP_INDEX_URL / UV_INDEX_URL=$PipIndexUrl"

    # ----- marker (Intune 検出ルール用; 中身は読まれないので BOM 不問) -----
    Set-Content -LiteralPath $MarkerFile -Value (Get-Date -Format "o") -Force
    Write-Host "Wrote marker $MarkerFile"

    Write-Output "Takumi Guard applied. Quarantine: pip/uv/poetry=server-side 3d, npm/pnpm/bun/yarn(4.10+)=client-side 3d, yarn-classic=registry-only."
    exit 0
}
catch {
    Write-Error "Takumi Guard install failed: $_"
    exit 1618  # MSI retry code: Intuneに再試行させる
}
