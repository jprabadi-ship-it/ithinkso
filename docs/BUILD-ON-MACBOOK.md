# MacBook でのビルド・提出手順

このマシン（開発機）の Xcode ではアーカイブ／提出が通らないため、
ビルドと App Store へのアップロードは MacBook 側で行う。

## 0. 前提

- 外部依存パッケージは無い（AppKit / SwiftUI / StoreKit 不使用の素の構成）
- 必要環境: macOS 13 以降をターゲットにビルドできる Xcode
- Team ID: `3HCG7Y94FX`（gigowat）
- Bundle ID: `com.rabadi.ithinkso`

## 1. プロジェクトをローカルにコピーする（重要）

**Google Drive 配下のままビルドしてはいけない。**
file-provider が拡張属性を付け直すため `codesign` が
`resource fork, Finder information, or similar detritus not allowed`
で失敗し続ける。必ずローカルディスクへコピーしてから作業する。

```sh
# 転送した zip を展開する場合
unzip ~/Downloads/IThinkSo-src.zip -d ~/Developer/
cd ~/Developer/IThinkSo

# Google Drive 同期で受け取った場合も、必ずコピーしてから
cp -R "~/Library/CloudStorage/GoogleDrive-*/マイドライブ/開発/IThinkSo" ~/Developer/IThinkSo
cd ~/Developer/IThinkSo
xattr -cr .
```

## 2. Xcode に Developer アカウントをサインイン

Xcode → Settings → Accounts → `+` → Apple ID。
`gigowat (3HCG7Y94FX)` が表示されることを確認する。

証明書（Apple Distribution / Mac Installer Distribution）と
プロビジョニングプロファイルは、次の手順の
`-allowProvisioningUpdates` が自動で作る。

## 3. App Store Connect にアプリを登録

先に登録しておかないとビルドの受け入れ先が無い。

- appstoreconnect.apple.com → My Apps → `+` → New App
- プラットフォーム: **macOS**
- Bundle ID: **com.rabadi.ithinkso**
- SKU: 任意（例 `ITHINKSO001`）

## 4. アーカイブとエクスポート

```sh
scripts/release.sh 3HCG7Y94FX
```

このスクリプトは以下を行う:
1. Release 構成でアーカイブ
2. **出荷ビルドに開発用コードが混入していないか検査**
   （SelfTest / ITSLicenseOverride 等が見つかったら中止する）
3. `app-store-connect` 方式でエクスポート → `/tmp/ithinkso-release/export/` に `.pkg`

Xcode GUI からやる場合は Product → Archive → Distribute App →
App Store Connect でも同じ。

## 5. アップロード

Xcode の Organizer（Window → Organizer）か Transporter.app に
`.pkg` を渡す。

## 6. App Store Connect で提出情報を入力

| 項目 | 内容 |
|---|---|
| 説明文・キーワード | `docs/appstore-description-ja.md` |
| 審査員向けノート | `docs/appstore-review-notes.md` を **App Review Information の Notes に貼る** |
| プライバシーポリシー URL | https://jprabadi-ship-it.github.io/ithinkso-privacy/ |
| 価格 | 無料（後日 ¥500 に変更予定） |
| カテゴリ | ユーティリティ |

審査員向けノートは Guideline 2.4.5（アクセシビリティ機能の目的外利用）への
先回りの説明なので、**必ず貼ること**。入力監視とイベント送出が
なぜ必要か、どう再現するかを英語で書いてある。

スクリーンショット（1280×800 以上）が最低1枚必要。

## 7. 動作確認をする場合

Bundle ID を変更したので、MacBook でもこのアプリを動かすには
「入力監視」と「アクセシビリティ」の許可を新規に与える必要がある。
許可後はアプリの再起動が必要（付与しただけでは反映されない）。

動作テスト:
1. 英語モードのまま `sonocheckma-kuhadokomadegahannidesuka` と打つ
2. **かなキーを素早く2回**
3. 「そのcheckマークはどこまでが範囲ですか」になれば成功
