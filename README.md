# intunewin-builder

GitHub Actions 上で最新版の Windows アプリを取得し、
`.intunewin` を生成するための自分用リポジトリ。

## できること
- workflow_dispatch でアプリを選ぶ
- 公式配布元から最新版をダウンロード
- intunewin に変換
- artifact として取得

## やらないこと
- Intune への自動登録
- 自動配布
- バージョン管理

## 対応アプリ
- Google Chrome (exe)
- Slack (exe)
- Cloudflare WARP (msi)

## 使い方
1. GitHub Actions → `build-intunewin`
2. `app` を選択して Run
3. Artifact から `.intunewin` を取得

