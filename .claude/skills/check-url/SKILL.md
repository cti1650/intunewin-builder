---
name: check-url
description: Microsoft Intune Win32App 候補のダウンロード URL を curl HEAD で検証し、A/B/C 級判定と推奨採用方式 (通常版 / script_based / 不採用) を返す。SourceForge backed の HTML mirror page 罠 (例: WinSCP-Latest-Setup.exe) を検出する。トリガー: 「<URL> の Intune 採用可否を見て」「URL を A/B/C で判定して」「/check-url <url>」「このアプリのダウンロードURLを検証して」など、apps/*.yml に追加する前の URL 単発検証。
---

# check-url

apps/*.yml 候補 URL を curl HEAD で実検証して採用可否を即判定する。

## 実行手順

1. ユーザーから渡された URL に対して `curl -sIL "<url>"` を Bash で実行する
2. 出力からリダイレクトチェーン、最終 HTTP ステータス、最終 `Content-Type`、`Content-Length` を抽出する
3. HEAD が 405 / 411 / HTML を返す場合は `curl -sI -H "Range: bytes=0-0" "<url>"` でバイナリ実体を Range GET 1 byte で確認する

## 出力フォーマット (5-8 行に収める)

```
URL: <input>
最終応答: <status code>
リダイレクト先: <final URL or なし>
Content-Type: <type>
Content-Length: <bytes / MB 換算>
判定: A / B / C
理由: <1 文>
推奨: <通常版 / script_based / 不採用>
```

## 判定基準

- **A 級**: 最終応答 200、Content-Type が binary (`application/x-msi`、`application/octet-stream`、`binary/octet-stream` 等)、URL にバージョン番号が含まれない、または latest 固定エンドポイント (`aka.ms/...`、`*-latest-*`、`?product=...-latest-ssl` 等)
- **B 級**: GitHub Releases の `releases/latest/download/<asset-with-version>` パターン (アセット名にバージョン入りだが latest API で常に最新を取れる)
- **C 級**: バージョン番号が URL に含まれていて、latest 固定エンドポイントが存在しない

## 罠の検出 (A 級判定にしてはいけないケース)

- Content-Type が `text/html` (= バイナリでなく HTML が返っている)
  - SourceForge backed の URL (`prdownloads.sourceforge.net/.../*-Latest-*`) で頻発。WinSCP がこのパターン
- 最終 URL がエラーページ (`/error`、`/404` 等)
- 最終応答が 4xx / 5xx
- リダイレクトループ (Location が同じ URL に戻る)

## 採用可否の最終アドバイス (推奨欄)

- **A 級** → 通常版 yml (`apps/<name>.yml`) で採用可
- **B 級** → script_based 版 (`apps/<name>_script_based.yml`) で採用、`scripts/generic-install.ps1` 経由
- **C 級** → 基本不採用。やむを得ない場合は scripts/apps/<name>/install.ps1 でクローラ実装が必要

## 例

```
URL: https://awscli.amazonaws.com/AWSCLIV2.msi
最終応答: 200
リダイレクト先: なし
Content-Type: binary/octet-stream
Content-Length: 47,841,280 (~46 MB)
判定: A 級
理由: latest 固定 URL、バイナリ直接配信、リダイレクトなし
推奨: 通常版 apps/awscli_v2.yml で採用可
```

## 参考リソース

apps/*.yml 追加まで進めるなら [add-intune-app](../add-intune-app/SKILL.md) skill に引き継ぐ。詳細リサーチが必要なら [intune-app-researcher](../../agents/intune-app-researcher.md) agent を呼ぶ。
