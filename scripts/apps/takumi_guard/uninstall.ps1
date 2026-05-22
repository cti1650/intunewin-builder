$ErrorActionPreference = "Stop"

$MarkerDir     = "C:\ProgramData\TakumiGuard"
$NpmConfigFile = "C:\ProgramData\npm-config\.npmrc"
$PipConfigFile = "C:\ProgramData\pip\pip.ini"

# ============================================================
# Helper functions (install.ps1 と共通; .intunewin に同梱できる .ps1 は
# install.ps1 / uninstall.ps1 のみのためインライン重複)
# ============================================================

$MARKER_DISABLED = "# [TakumiGuard-disabled] "
$BLOCK_BEGIN     = "# === BEGIN TakumiGuard ==="
$BLOCK_END       = "# === END TakumiGuard ==="
# 旧 install.ps1 (PR #47 初版) が書き出していた「丸ごと管理」形式の識別子
$LEGACY_HEADER   = "Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."

function Write-FileNoBom {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

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

# 指定パスの config から自分の追記分だけ取り除き、disabled prefix を剥がして元の値を復元する。
# - 自分が触れていなかった (どちらのマーカーも無い) ファイル → 何もしない
# - 旧形式 (LEGACY_HEADER のみ) → ファイル丸ごと削除 (旧 install で他キーは尊重していなかったため)
# - 新形式 (BEGIN/END ブロックあり) → block 削除 + disabled prefix 剥がし
# - 復元後の中身が空白/コメントのみになった場合はファイルごと削除
function Restore-Config {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return }

    $hasBlock  = $raw.Contains($BLOCK_BEGIN)
    $hasLegacy = $raw.Contains($LEGACY_HEADER)

    if (-not $hasBlock -and -not $hasLegacy) {
        Write-Output "Skip (not managed): $Path"
        return
    }

    if ($hasLegacy -and -not $hasBlock) {
        Remove-Item -LiteralPath $Path -Force
        Write-Output "Removed (legacy fully-managed): $Path"
        return
    }

    $lines = @(Get-Content -LiteralPath $Path)
    $lines = Remove-ManagedBlock -Lines $lines
    $lines = Restore-DisabledLines -Lines $lines

    # 復元後に意味のある行 (空でもコメントでもない行) が残っているか
    $meaningful = @($lines | Where-Object {
        $t = $_.Trim()
        ($t -ne "") -and -not $t.StartsWith("#") -and -not $t.StartsWith(";")
    })

    if ($meaningful.Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force
        Write-Output "Removed (empty after restore): $Path"
    } else {
        # 末尾の連続する空行は片付ける
        while ($lines.Count -gt 0 -and $lines[-1].Trim() -eq "") {
            $lines = $lines[0..($lines.Count - 2)]
        }
        Write-FileNoBom -Path $Path -Lines $lines
        Write-Output "Restored ($($meaningful.Count) non-Takumi line(s) kept): $Path"
    }
}

# ============================================================
# Main
# ============================================================
# Pester から dot-source されたときは helper だけ露出させ main を実行しない。
if ($MyInvocation.InvocationName -eq '.') { return }

# system-wide
Restore-Config -Path $NpmConfigFile
Restore-Config -Path $PipConfigFile

# per-user (Default + 既存ユーザー)
$ProfileRoots = @("C:\Users\Default") + (
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Default","Public","Default User","All Users","WDAGUtilityAccount") } |
        Select-Object -ExpandProperty FullName
)
foreach ($p in $ProfileRoots) {
    Restore-Config -Path (Join-Path $p "AppData\Local\pnpm\config\config.yaml")
    Restore-Config -Path (Join-Path $p ".bunfig.toml")
}

# Machine 環境変数を解除
foreach ($v in @("NPM_CONFIG_GLOBALCONFIG", "YARN_NPM_REGISTRY_SERVER", "YARN_NPM_MINIMAL_AGE_GATE", "PIP_INDEX_URL", "UV_INDEX_URL")) {
    [System.Environment]::SetEnvironmentVariable($v, $null, "Machine")
    Write-Output "Cleared system env $v"
}

if (Test-Path -LiteralPath $MarkerDir) {
    Remove-Item -LiteralPath $MarkerDir -Recurse -Force
    Write-Output "Removed $MarkerDir"
}

exit 0
