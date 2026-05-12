# 開発環境セットアップ (任意)

> [← README に戻る](../README.md)

このリポジトリへの PR や apps/*.yml 追加を行う際にローカルで lint を回したい場合の手順。CI 側で最終ガードがかかるため、ローカルセットアップは強制ではない。

## 前提

- [PowerShell Core (pwsh)](https://learn.microsoft.com/powershell/scripting/install/) — macOS は `brew install --cask powershell`、Windows は `winget install Microsoft.PowerShell`、Linux は [公式手順](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)

## PowerShell 構文チェック (ローカル)

```bash
# 全 .ps1 を AST パーサで検査 (pwsh 未導入なら案内表示)
./scripts/dev-check.sh
```

[scripts/check-syntax.ps1](../scripts/check-syntax.ps1) 単体で pwsh から呼び出すこともできる:

```bash
pwsh -File scripts/check-syntax.ps1
pwsh -File scripts/check-syntax.ps1 -Files scripts/build-intunewin.ps1
```

## git pre-commit hook (オプトイン)

stage された `*.ps1` のみを構文チェックする pre-commit hook を有効化できる:

```bash
./scripts/install-hooks.sh    # core.hooksPath を .githooks/ に設定
```

- バイパス: `git commit --no-verify`
- 解除: `git config --unset core.hooksPath`
- pwsh 未導入時は警告のみで通す (CI 側で最終ガード前提)

## PowerShell スクリプトのエンコーディング

`.ps1` / `.psm1` / `.psd1` は **BOM 付き UTF-8** でチェックインする。

CI Windows runner と Intune 実機の `powershell.exe` (Windows PowerShell 5.1) は BOM 無し UTF-8 を Console code page (en-US 環境では CP1252) として解釈するため、日本語リテラルを含む .ps1 が mojibake してパースエラーになる。

- 新規作成・編集後は `head -c 3 <file>.ps1 | xxd -p` が `efbbbf` で始まることを確認
- BOM 付与漏れは `(printf '\xEF\xBB\xBF'; cat <file>) > <file>.tmp && mv <file>.tmp <file>` で付与
- ASCII のみの .ps1 にも一貫性のため BOM を付ける

## Action バージョン更新

`.github/dependabot.yml` で github-actions を週次監視。新版が出ると自動で PR が立つ。lint が通れば原則そのまま merge で良い。

## コミット規約

`feat:`, `fix:`, `chore:`, `ci:`, `docs:` の prefix を付ける。日本語本文 OK。`#PR番号` は GitHub が自動付与するので手動で入れない。
