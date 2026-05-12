# ローカル動作確認 (Intune を経由しない実機検証)

> [← README に戻る](../README.md)

`.intunewin` パッケージングや Intune を経由せず、Windows 端末上で `apps/<App>.yml` の **Install / Uninstall を単発で実行**して挙動を確認する用途。`build-and-verify` のような検出 / クリーンアップ検証は走らせず、純粋に install or uninstall だけを実行する。

エントリポイント: [scripts/local-run.ps1](../scripts/local-run.ps1)

## 使い方

```powershell
# 通常版 (msi/exe/msix)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox -Action Install
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox -Action Uninstall

# script_based 版 (端末側で URL から DL)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App firefox_script_based -Action Install

# custom_script 版 (同梱 PS1 を直接実行)
powershell.exe -ExecutionPolicy Bypass -File scripts\local-run.ps1 -App company_portal_shortcut -Action Install
```

## 特徴

- **Windows PowerShell 5.1 で動く** ので、素の Windows 10/11 で `pwsh` (PowerShell 7) を入れずに実行できる。pwsh 7 でも同じく動く
- 初回起動時に `powershell-yaml` モジュールが未導入なら CurrentUser スコープで自動取得する (`apps/*.yml` のパース用)
- `installer.type` (msi/exe/msix) と `uninstall.type` (msi/exe/msix/script/registry_string) の dispatch は CI の verify-installer / build-script-based と同等
- システムコンテキストインストーラの場合は管理者権限の PowerShell から実行する必要がある

## 注意

本物のインストーラを実機に流すため、レジストリ / ファイルシステム / サービス等が変更される。**Windows Sandbox / 検証用 VM / 使い捨て端末で実行することを強く推奨**する。Sandbox を使う場合はリポジトリを zip で持ち込み、上記コマンドを管理者権限の PowerShell から実行すれば十分。

[Windows Sandbox の有効化手順 (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install-configure)
