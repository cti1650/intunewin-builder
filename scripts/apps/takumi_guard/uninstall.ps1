$ErrorActionPreference = "Stop"

$MarkerDir     = "C:\ProgramData\TakumiGuard"
$NpmConfigFile = "C:\ProgramData\npm-config\.npmrc"
$PipConfigFile = "C:\ProgramData\pip\pip.ini"

# system-wide configs
foreach ($f in @($NpmConfigFile, $PipConfigFile)) {
    if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force
        Write-Output "Removed $f"
    } else {
        Write-Output "Not present, skip: $f"
    }
}

# per-user configs (Default + 既存ユーザー)
$ProfileRoots = @("C:\Users\Default") + (
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Default","Public","Default User","All Users","WDAGUtilityAccount") } |
        Select-Object -ExpandProperty FullName
)
foreach ($p in $ProfileRoots) {
    $pnpmCfg = Join-Path $p "AppData\Local\pnpm\config\config.yaml"
    $bunCfg  = Join-Path $p ".bunfig.toml"
    foreach ($f in @($pnpmCfg, $bunCfg)) {
        if (Test-Path -LiteralPath $f) {
            # 自前で書いたファイルかを Managed marker で確認してから消す
            $content = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match "Managed by Takumi Guard") {
                Remove-Item -LiteralPath $f -Force
                Write-Output "Removed $f"
            } else {
                Write-Output "Skipped (not ours): $f"
            }
        }
    }
}

# Machine 環境変数を解除
$EnvVarsToClear = @(
    "NPM_CONFIG_GLOBALCONFIG",
    "YARN_NPM_REGISTRY_SERVER",
    "PIP_INDEX_URL",
    "UV_INDEX_URL"
)
foreach ($v in $EnvVarsToClear) {
    [System.Environment]::SetEnvironmentVariable($v, $null, "Machine")
    Write-Output "Cleared system env $v"
}

if (Test-Path -LiteralPath $MarkerDir) {
    Remove-Item -LiteralPath $MarkerDir -Recurse -Force
    Write-Output "Removed $MarkerDir"
}

exit 0
