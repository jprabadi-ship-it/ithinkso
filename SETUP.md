# I think so — Xcode プロジェクト設定手順

## 1. 新規プロジェクト作成

- Xcode → New Project → macOS → **App**
- Product Name: `IThinkSo`
- Interface: **SwiftUI**
- Language: **Swift**
- 生成された `ContentView.swift` は削除してOK

ソースファイルをプロジェクトに追加：
```
IThinkSoApp.swift
MenuView.swift
AppState.swift
KeyMonitor.swift
```

## 2. App Sandbox を無効化（必須）

CGEventTap はサンドボックス内では動作しません。

1. Xcode でプロジェクトを選択
2. Target → **Signing & Capabilities**
3. **App Sandbox** の行の左にある `-` ボタンで削除

## 3. Info.plist に LSUIElement を追加

Dock にアイコンを出さないためのキーです。

`Info.plist` を開いて以下を追加（または `Open As → Source Code` で直接編集）：

```xml
<key>LSUIElement</key>
<true/>
```

または Xcode の `Info` タブ → `+` → Key: `Application is agent (UIElement)` → Value: `YES`

## 4. Entitlements の確認

Sandbox を外した場合、Entitlements ファイルは空で構いません。  
Accessibility の許可はアプリ実行時に `AXIsProcessTrustedWithOptions` が行います。

## 5. ビルド・初回起動

1. ビルドして起動
2. メニューバーに `text.bubble.fill` アイコンが出れば成功
3. アクセシビリティ権限の許可ダイアログが出たら許可
4. `システム設定 → プライバシーとセキュリティ → アクセシビリティ` でも確認できます

## 動作確認

1. テキストエディタ等で英数モードのまま `nihongo` と打つ（7文字）
2. `↑` キーを押す
3. → 文字が消え、日本語IMEに切り替わり、`nihongo` が再送されてかな変換バッファに入る

## 調整ポイント（KeyMonitor.swift）

| 定数 | 意味 | デフォルト |
|------|------|-----------|
| `rescueThreshold` | 何文字以上で救出対象にするか | 5 |

## 既知の制限

- 日本語IMEが1つもインストールされていない環境では切替不可（通常は問題なし）
- 一部のアプリ（Electron系など）では `CGEventPost` の再送が届かない場合がある
