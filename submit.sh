#!/bin/zsh
# I think so — App Store 提出用スクリプト
#
#   ./submit.sh archive   … アーカイブ作成(署名済み .xcarchive)
#   ./submit.sh export    … App Store用 .pkg を書き出し
#   ./submit.sh upload    … App Store Connect へアップロード
#
# export / upload には App Store Connect APIキーが必要です。
# クラちゃんの setup.sh を実行済みなら ~/.appstore_env にもう入っています。
# 無い場合は以下を設定してください:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH(.p8ファイルのパス)
set -e
cd "${0:a:h}"

[[ -f ~/.appstore_env ]] && source ~/.appstore_env

PROJECT="IThinkSo.xcodeproj"
SCHEME="IThinkSo"
ARCHIVE="build/IThinkSo.xcarchive"
EXPORT_DIR="build/export"
TEAM_ID="3HCG7Y94FX"

auth_args() {
  if [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -n "$ASC_KEY_PATH" ]]; then
    echo "-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
  else
    echo "-allowProvisioningUpdates"
  fi
}

case "$1" in
archive)
  eval xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" archive $(auth_args)

  # 出荷ビルドに開発用コードが混入していないか検査する。
  # SelfTest(キーストローク注入の自己テスト装置)が残っていると
  # 審査ガイドライン 2.3.1(隠し機能) / 2.4.5 の指摘対象になりうる。
  BIN="$ARCHIVE/Products/Applications/IThinkSo.app/Contents/MacOS/IThinkSo"
  for needle in ITS_SELFTEST ITSLicenseOverride ITS_SET_DEV SelfTest; do
    if grep -qa "$needle" "$BIN"; then
      echo "❌ 出荷ビルドに '$needle' が含まれています。中止します。"
      exit 1
    fi
  done
  echo "✅ 開発用コードの混入なし"

  # 選択範囲の読み取り（AX API）は Developer ID 版限定。App Store 版に載ると
  # 2.4.5 の指摘に直結する。文字列 grep では捕まらないのでシンボルで検査する
  if nm -u "$BIN" | grep -qE "_AXUIElement|_AXIsProcessTrusted"; then
    echo "❌ 出荷ビルドに AX シンボルが含まれています。中止します。"
    exit 1
  fi
  echo "✅ AX シンボルの混入なし"

  # Xcode Organizer にも表示されるようコピー
  ARCHDIR=~/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)
  mkdir -p "$ARCHDIR"
  rm -rf "$ARCHDIR/IThinkSo.xcarchive"
  cp -R "$ARCHIVE" "$ARCHDIR/IThinkSo.xcarchive"
  echo "✅ アーカイブ完了: $ARCHIVE"
  echo "   (Xcode > Window > Organizer にも表示されます)"
  ;;
export)
  mkdir -p build
  cat > build/ExportOptions.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
  rm -rf "$EXPORT_DIR"
  eval xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist build/ExportOptions.plist -exportPath "$EXPORT_DIR" $(auth_args)
  echo "✅ 書き出し完了: $EXPORT_DIR"
  ;;
upload)
  PKG=$(ls "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1)
  [[ -z "$PKG" ]] && { echo "❌ pkgが見つかりません。先に export を実行してください"; exit 1; }
  if [[ -n "$ASC_KEY_ID" ]]; then
    xcrun altool --upload-app -f "$PKG" -t macos \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  else
    xcrun altool --upload-app -f "$PKG" -t macos \
      --apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD"
  fi
  echo "✅ アップロード完了"
  ;;
*)
  echo "使い方: ./submit.sh {archive|export|upload}"
  ;;
esac
