<#
.SYNOPSIS
  PowerShell スクリプトの構文を AST パーサで検査する。

.DESCRIPTION
  指定パス配下の *.ps1 を再帰的に列挙し、
  [System.Management.Automation.Language.Parser]::ParseFile で構文エラーを抽出する。

  ローカル (pre-commit hook) と CI の両方から呼び出せる単一の入口。

.PARAMETER Path
  検査対象ディレクトリ (複数可)。既定は scripts/ のみ。

.PARAMETER Files
  個別ファイル指定 (pre-commit hook で staged ファイルを渡す用途)。
  指定された場合 Path は無視される。

.EXAMPLE
  pwsh -File scripts/check-syntax.ps1
  pwsh -File scripts/check-syntax.ps1 -Path scripts, .githooks
  pwsh -File scripts/check-syntax.ps1 -Files scripts/build-intunewin.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Path = @('scripts'),
    [string[]]$Files = @()
)

$ErrorActionPreference = 'Stop'

$targets = @()
if ($Files.Count -gt 0) {
    # ファイル個別指定 (pre-commit hook 用途) と同時にディレクトリを渡された
    # ケースでも落ちないようハイブリッドに扱う
    foreach ($f in $Files) {
        if (Test-Path -Path $f -PathType Leaf) {
            $targets += Get-Item -Path $f
        } elseif (Test-Path -Path $f -PathType Container) {
            $targets += Get-ChildItem -Path $f -Filter *.ps1 -Recurse -File
        }
    }
} else {
    foreach ($p in $Path) {
        if (Test-Path $p) {
            $targets += Get-ChildItem -Path $p -Filter *.ps1 -Recurse -File
        }
    }
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Host "No .ps1 files found to check."
    exit 0
}

$totalErrors = 0
foreach ($file in $targets) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($e in $parseErrors) {
            $rel = try { Resolve-Path $file.FullName -Relative } catch { $file.FullName }
            $line = $e.Extent.StartLineNumber
            $col  = $e.Extent.StartColumnNumber
            Write-Host ("{0}:{1}:{2}: {3}" -f $rel, $line, $col, $e.Message) -ForegroundColor Red
            $totalErrors++
        }
    }
}

Write-Host ""
if ($totalErrors -gt 0) {
    Write-Host ("FAILED: {0} syntax error(s) in {1} file(s)" -f $totalErrors, $targets.Count) -ForegroundColor Red
    exit 1
}

Write-Host ("OK: {0} file(s) parsed without errors" -f $targets.Count) -ForegroundColor Green
exit 0
