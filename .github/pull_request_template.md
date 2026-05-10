<!--
タイトルの接頭辞: feat: / fix: / chore: / ci: / docs: / refactor:
本文は日本語で OK。`#PR番号` は GitHub が自動付与するため手書きしない。
-->

## 概要

<!-- 何を変更したか、なぜ変更したか (1〜3 行)。関連 issue や失敗した CI run の URL があれば貼る。 -->

## 変更ファイル

<!-- 主要なファイルと変更点を箇条書き。新規アプリ追加なら apps/ + workflow の choice options + README の 3 箇所セットで。 -->
- 

## 動作確認

<!--
手元で実行した検証と、CI に期待する確認項目。該当しない行は削除して構わない。
ローカルで lint を回す場合 (pwsh が入っている環境):
  pwsh -File scripts/check-syntax.ps1
  pwsh -File scripts/check-apps-schema.ps1
  pwsh -File scripts/check-choice-list.ps1
macOS 等で pwsh が無い場合は docker mcr.microsoft.com/powershell:lts-debian-12 でも代用可。
-->

- [ ] `scripts/check-apps-schema.ps1` が PASS (apps/*.yml を編集した場合)
- [ ] `scripts/check-choice-list.ps1` が PASS (apps/*.yml を追加・削除した場合)
- [ ] `scripts/check-syntax.ps1` が PASS (scripts/*.ps1 を編集した場合)
- [ ] actionlint が PASS (.github/workflows/*.yml を編集した場合)
- [ ] CI 上の `lint.yml` ジョブがすべて成功
- [ ] auto-chain で対象アプリの verify が **OverallResult: PASS** まで完走 (apps/*.yml もしくは scripts/apps/<name>/** を変更した場合、PR push でも走る)

## 関連 / メモ (任意)

<!--
- 関連 PR や過去の learnings、注意点
- yml に書ききれない調査メモ (例: ベンダー側の挙動、CI 上の flaky に対する対処、実機検証で判明した path 等)
-->
