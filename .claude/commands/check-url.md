---
description: URL の安定性 (A/B/C 級) とバイナリ実体性を curl HEAD で検証して採用可否を判定する
argument-hint: <url>
---

`$1` を Intune Win32App 候補として採用可能か、curl HEAD で実検証する。

## 実行手順

1. まず `curl -sIL "$1" | head -40` を Bash で実行する
2. 出力からリダイレクトチェーン、最終 HTTP ステータス、最終 `Content-Type`、`Content-Length` を抽出する
3. 必要なら `curl -sI -H "Range: bytes=0-0" "$1"` でバイナリ実体を Range GET 1 byte で確認 (HEAD が 405 や HTML を返す場合)

## 出力フォーマット (5-8 行に収める)

```
URL: <input>
最終応答: <status code>
リダイレクト先: <final URL>
Content-Type: <type>
Content-Length: <bytes / MB 換算>
判定: A / B / C
理由: <1 文>
```

## 判定基準

- **A 級**: 最終応答 200、Content-Type が binary (`application/x-msi`、`application/octet-stream`、`binary/octet-stream` 等)、URL にバージョン番号が含まれない、または latest 固定エンドポイント (`aka.ms/...`、`*-latest-*`、`?product=...-latest-ssl` 等)
- **B 級**: GitHub Releases の `releases/latest/download/<asset-with-version>` パターン (アセット名にはバージョンが入るが latest API で常に最新を取れる)
- **C 級**: バージョン番号が URL に含まれていて、latest 固定エンドポイントが存在しない

## 罠の検出

以下のいずれかに該当する場合、A 級判定にしてはいけない:

- Content-Type が `text/html` (= バイナリでなく HTML が返っている)
  - SourceForge backed の URL (`prdownloads.sourceforge.net/.../*-Latest-*`) で頻発
  - 真のバイナリ URL を別途探す or 諦めて C 級扱いで script_based 化
- 最終 URL がエラーページ (`/error`、`/404` 等)
- 最終応答が 4xx / 5xx
- リダイレクトループ (Location が同じ URL に戻る)

## 採用可否の最終アドバイス (1 行)

判定が出たら次の方針を示す:

- **A 級**: 通常版 yml (`apps/<name>.yml`) で採用可
- **B 級**: script_based 版 (`apps/<name>_script_based.yml`) で採用、`scripts/generic-install.ps1` 経由
- **C 級**: 基本不採用。やむを得ない場合は scripts/apps/<name>/install.ps1 でクローラ実装が必要

## 例

```
$ /check-url https://awscli.amazonaws.com/AWSCLIV2.msi
URL: https://awscli.amazonaws.com/AWSCLIV2.msi
最終応答: 200
リダイレクト先: (なし、直接配信)
Content-Type: binary/octet-stream
Content-Length: 47,841,280 (~46 MB)
判定: A 級
理由: latest 固定 URL、バイナリ直接配信、リダイレクトなし
推奨: 通常版 apps/awscli_v2.yml で採用可
```
