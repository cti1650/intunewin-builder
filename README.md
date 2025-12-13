# intunewin-builder

GitHub Actions 上で Windows アプリを取得し、
.intunewin を生成・事前確認するための個人用リポジトリ。

ローカル端末を使わず、
Intune に登録する「前」までの確認を CI で完結させることを目的としている。

## できること

* GitHub Actions からアプリを選択して実行
* 公式配布元からインストーラをダウンロード
* intunewin を生成して artifact として取得
* Intune を使わずにサイレントインストールと検出条件を確認

## やらないこと

* Intune への自動登録・自動配布
* IME や割り当て挙動の検証
* アプリのバージョン管理

Intune 自体はブラックボックスとして扱い、
「Intune に渡す材料の品質」だけを責任範囲とする。

## 対応アプリ

* Google Chrome
* Slack
* Cloudflare WARP

## 使い方

1. build-intunewin を実行して intunewin を作成
2. verify-installer を実行して事前検証
3. 問題なければ Intune に登録

## 補足

このリポジトリは
「Intune に入れてから失敗する」ケースを減らすための仕組み。

本番展開前の最小限の実機確認は前提とする。