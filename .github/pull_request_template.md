<!--
タイトル prefix: feat: / fix: / chore: / ci: / docs: / refactor:
日本語本文 OK。`#PR番号` は GitHub が自動付与するので手動で入れない。
-->

## Summary

<!-- 何を変更したか、なぜ変更したか (1-3 行)。背景 issue / 失敗 CI run の URL があれば貼る。 -->

## 変更ファイル

<!-- 主要なファイルと変更点。新規アプリ追加なら apps/ + workflow choices + README の 3 箇所セット。 -->
- 

## Test plan

<!--
手元で実行した検証と、CI に期待する確認項目。該当しない行は削除して OK。
ローカル lint は pwsh 入りの環境で:
  pwsh -File scripts/check-syntax.ps1
  pwsh -File scripts/check-apps-schema.ps1
  pwsh -File scripts/check-choice-list.ps1
macOS で pwsh 不在なら docker mcr.microsoft.com/powershell:lts-debian-12 でも代用可。
-->

- [ ] `scripts/check-apps-schema.ps1` PASS (apps/*.yml 編集あり)
- [ ] `scripts/check-choice-list.ps1` PASS (apps/*.yml 追加・削除あり)
- [ ] `scripts/check-syntax.ps1` PASS (scripts/*.ps1 編集あり)
- [ ] actionlint PASS (.github/workflows/*.yml 編集あり)
- [ ] CI lint job (push 後の `.github/workflows/lint.yml`)
- [ ] auto-chain で対象 app の verify が **OverallResult: PASS** まで完走 (apps/*.yml or scripts/apps/<name>/** の変更時、PR push でも走る)

## 関連 / 学び (任意)

<!--
- 関連 PR / 過去の learnings / 注意点
- yml に書ききれない調査メモ (例: ベンダー側の挙動、CI 上の flaky 対処)
-->
