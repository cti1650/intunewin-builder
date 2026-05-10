---
name: debug-build-failure
description: build-and-verify-intunewin / build-and-verify-intunewin-apps の失敗を切り分けて修正する。失敗段階 (Download / Build / Install / Detect / VersionCheck / Uninstall / CleanUp) ごとの対処手順、よくある exit code、apps/*.yml の修正パターンを提供する。トリガー: 「ビルドが失敗した」「<アプリ名> のインストールが落ちる」「Intune の検出ルールが効かない」「アンインストールが残留する」等の依頼。
---

# Debug Build Failure

build-and-verify 系の失敗を「失敗段階の特定 → 根本原因切り分け → 修正 → 再実行」のサイクルで解決する。

## 前提

- 失敗した workflow run の URL または run ID をユーザーに確認する
- ログ取得・分析は [intune-build-log-analyzer](../../agents/intune-build-log-analyzer.md) サブエージェントに任せる方が深く追える
- 修正は `apps/<name>.yml` の編集が中心。スキーマ allowlist は [../../CLAUDE.md](../../CLAUDE.md) を参照

## 失敗段階別の対処

### Download 失敗

```
Invoke-WebRequest: Response status code does not indicate success: 404 Not Found
WARNING: File does not appear to be a valid MSI
```

**根本原因の候補**:

- URL がバージョン入り (C 級) で配布元が古いバージョンを削除した
- SourceForge backed URL で HEAD/GET が HTML mirror page を返している (WinSCP 系)
- 認証必須 URL に YOUR_ORGANIZATION 等の placeholder が残っている

**対処**:

1. `curl -sIL <url>` で HEAD を確認、Content-Type が binary でなければ A 級判定が誤り
2. A 級 URL に変える、または script_based + クローラに移行 ([../../skills/add-intune-app/SKILL.md](../add-intune-app/SKILL.md) 参照)
3. テナント依存 URL なら `okta_verify` 同様の placeholder + organization input パターンに揃える

### Build (IntuneWinAppUtil) 失敗

```
IntuneWinAppUtil.exe ... exit code <non-zero>
```

**根本原因の候補**:

- `app/` ディレクトリが空 (Download が静かに失敗していた)
- インストーラファイル名が `download.file` と不一致

**対処**:

1. Download 段階のログを再確認
2. `download.file` がレスポンスの実ファイル名と一致するか確認 (Content-Disposition や URL 末尾)

### Install 失敗 (exit code)

| Code | 意味 | 主な対処 |
|---|---|---|
| **0** | 成功 | (失敗扱いなら build-intunewin 側のロジック確認) |
| **1602** | ユーザーキャンセル相当 | サイレント引数の typo を疑う (`/qn` → `/q`、`/VERYSILENT` → `/silent` 等) |
| **1603** | 包括的な fatal error | `%TEMP%\MSI*.log` を artifact から探す。既存インストール残留、権限不足、カスタムアクション失敗 |
| **1605** | 該当製品が未インストール | uninstall 経路で出ることが多い (= 検出が誤って install 済と判定) |
| **3010** | 成功 + reboot 要求 | `/norestart` 指定済か確認。build-intunewin はこのコードを成功扱いすべき (要確認) |
| **1641** | 成功 + 自動 reboot 開始 | 同上 |

EXE は engine ごとにコード体系が違う。Inno Setup なら `/LOG` を付けて `%TEMP%\Setup Log*.txt` を出す手もある。

### Detect 失敗

```
DetectionStatus: Failed
```

**根本原因の候補**:

| サブ症状 | 原因 |
|---|---|
| `detect.file` が見つからない | パスが Program Files vs Program Files (x86) で誤り、または `install_behavior: user` のアプリで `%LocalAppData%` プレースホルダ未指定 |
| `registry_display_name` が見つからない | DisplayName のベース名指定が違う、または EXE インストーラなのに MSI 検出経路を期待 |
| 検出条件は通るが Version check で落ちる | `detect.version` の pin が**実機 install 結果より高い** (consumer release notes をそのまま信じて pin した、または配布元の latest が前バージョンに後退した) |

**対処**:

1. ログの「インストール後スナップショット」差分から実際にインストールされたパスを確認
2. `detect.file` と `detect.registry_display_name` を実値に揃える
3. バージョンを固定したくないなら `detect.version` を空 or 削除
4. **VersionCheck Failed の場合は verify サマリの `InstalledVersion` が正解値**。yml の `detect.version` をその値に合わせる。consumer release notes / blog 記事の版数は **信用しない** — Chrome 等は consumer stable と Enterprise MSI で別系統で 1〜2 マイナー遅延する

### Uninstall 失敗

```
UninstallStatus: Failed
```

**根本原因の候補**:

- `uninstall.type: msi` だが ProductCode が registry に無い (= MSI 経由でなく EXE インストーラだった)
- `uninstall.path` の絶対パスが `Program Files` / `Program Files (x86)` の片側にしか合っていない
- WiX Bootstrapper で UninstallString が `MsiExec.exe /X{...}` 形式 → `registry_string` 型を使うべき (okta_verify 参照)

**対処**:

1. `uninstall.type` をインストーラ engine に合わせる (MSI → msi、Inno → exe + unins000.exe、Bootstrapper → registry_string)
2. okta_verify 方式の registry_string + process_name の運用が必要なら [scripts/verify-installer.ps1](../../../scripts/verify-installer.ps1) を参照

### CleanUp 失敗

```
CleanUpStatus: Failed
```

アンインストール後も検出条件が通ってしまう状況。アンインストーラがファイルを残している、レジストリエントリが消えていない 等。多くの場合 install 自体は成功しているので、検出条件を厳しくする (file + registry の AND) か、強制クリーンアップを script_based で書くか。

## よくある修正パターン

### パターン 1: 通常版を script_based に逃がす

URL がバージョン入りに変わった、初回起動 wizard が出る、複数 MSI が必要 等で通常版が安定しない場合、`*_script_based.yml` を整備して `apps/<name>.yml` を削除し、build-and-verify.yml の choice options からも外す。

### パターン 2: detect 条件を厳しくする

ファイル + バージョン + レジストリ全部で AND を取ると検出ミスを減らせるが、片方の条件を落とすと壊れやすくなる。基本は `detect.file` + `detect.registry_display_name` の組み合わせを推奨。

### パターン 3: ARM64 だけ失敗するケース

matrix から arm64 を外すか、x64 と arm64 で yml を分ける。現状 `_core-build.yml` は両方走るので、ARM 非対応アプリは matrix override が要る。

## 修正後の検証

1. `pwsh -File scripts/check-apps-schema.ps1` でスキーマ違反していないか
2. `pwsh -File scripts/check-choice-list.ps1` で choice options 整合性
3. ローカル lint 通ったら PR 作成、build-and-verify-intunewin を該当アプリで手動実行して green 確認
4. matrix の両軸 (windows-latest / windows-11-arm) で通ること

## 参考

- [intune-build-log-analyzer agent](../../agents/intune-build-log-analyzer.md) — 深いログ解析が必要な時
- [add-intune-app skill](../add-intune-app/SKILL.md) — script_based 移行など根本対処時
- [scripts/verify-installer.ps1](../../../scripts/verify-installer.ps1) — 検出/アンインストールロジックの正本
