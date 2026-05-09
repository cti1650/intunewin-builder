<#
.SYNOPSIS
  build-and-verify.yml の choice options と apps/*.yml の整合性を検証する。

.DESCRIPTION
  workflow_dispatch の inputs.app.options に列挙されたアプリ名と、
  apps/*.yml のうち通常版 (script_based でも custom_script でもないもの) の集合が
  完全一致するかをチェックする。

  - apps/<name>.yml を新規追加したのに choice options に追加し忘れる事故
  - 削除したアプリが choice options に残ってしまう事故
  両方を Push 時に検出する。

.EXAMPLE
  pwsh -File scripts/check-choice-list.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkflowPath = '.github/workflows/build-and-verify.yml',
    [string]$AppsPath = 'apps'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing powershell-yaml..."
    Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module powershell-yaml -Scope CurrentUser -Force
}
Import-Module powershell-yaml

if (-not (Test-Path $WorkflowPath)) {
    Write-Host "ERROR: workflow file not found: $WorkflowPath" -ForegroundColor Red
    exit 1
}

# YAML 1.1 では 'on' が真偽値に解釈されうるため、複数経路で取得を試みる
$workflow = Get-Content $WorkflowPath -Raw | ConvertFrom-Yaml
$onBlock = $null
foreach ($key in $workflow.Keys) {
    # 'on' (string) でも True (bool) でも拾う
    if ($key -eq 'on' -or $key -eq $true) {
        $onBlock = $workflow[$key]
        break
    }
}
if (-not $onBlock) {
    Write-Host "ERROR: 'on:' block not found in $WorkflowPath" -ForegroundColor Red
    exit 1
}

$choices = @($onBlock.workflow_dispatch.inputs.app.options) | Where-Object { $_ } | Sort-Object

$apps = Get-ChildItem -Path $AppsPath -Filter *.yml -File | ForEach-Object {
    $def = Get-Content $_.FullName -Raw | ConvertFrom-Yaml
    if ($def.script_based -eq $true) { return }
    if ($def.custom_script -eq $true) { return }
    if ($_.BaseName -match '_script_based$') { return }
    $_.BaseName
} | Where-Object { $_ } | Sort-Object

$missing = @($apps | Where-Object { $_ -notin $choices })
$extra = @($choices | Where-Object { $_ -notin $apps })

$totalErrors = 0
if ($missing.Count -gt 0) {
    Write-Host "ERROR: choice options missing app(s): $($missing -join ', ')" -ForegroundColor Red
    Write-Host "  -> add them to $WorkflowPath under inputs.app.options" -ForegroundColor Yellow
    $totalErrors += $missing.Count
}
if ($extra.Count -gt 0) {
    Write-Host "ERROR: choice options reference non-existent app(s): $($extra -join ', ')" -ForegroundColor Red
    Write-Host "  -> remove them from $WorkflowPath or add corresponding apps/*.yml" -ForegroundColor Yellow
    $totalErrors += $extra.Count
}

Write-Host ""
if ($totalErrors -gt 0) {
    Write-Host "FAILED: build-and-verify.yml choice options and apps/*.yml are out of sync" -ForegroundColor Red
    exit 1
}
Write-Host "OK: $($choices.Count) choice option(s) match apps/*.yml" -ForegroundColor Green
exit 0
