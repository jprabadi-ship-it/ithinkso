#!/bin/zsh
# App Store 提出用のアーカイブ〜エクスポート
#
# 使い方:  scripts/release.sh <TEAM_ID>
#   例:    scripts/release.sh ABCDE12345
#
# 前提:
#   - Xcode に Developer Program のアカウントがサインイン済み
#   - Apple Distribution 証明書が発行済み（Xcode が自動生成できる）
#   - Bundle ID (com.ithinkso.app) が Developer ポータルに登録済み
#
# 出力: build/export/IThinkSo.pkg （App Store Connect にアップロードする成果物）
#
# 注意: Google Drive 配下では拡張属性が付き直して署名が壊れるため、
#       ビルドと署名は /tmp 配下で行い、成果物だけを持ち帰る。

set -e

TEAM_ID="${1:?TEAM_ID を引数で指定してください（Xcode > Settings > Accounts で確認）}"
PROJECT_DIR="${0:A:h:h}"
WORK="/tmp/ithinkso-release"
ARCHIVE="$WORK/IThinkSo.xcarchive"
EXPORT_DIR="$WORK/export"

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$WORK/ExportOptions.plist" <<EOF
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
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF

echo "▶ アーカイブ作成中..."
xcodebuild -project "$PROJECT_DIR/IThinkSo.xcodeproj" \
  -scheme IThinkSo \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  archive

echo "▶ 出荷ビルドに開発用コードが混入していないか検査..."
BIN="$ARCHIVE/Products/Applications/IThinkSo.app/Contents/MacOS/IThinkSo"
for needle in ITS_SELFTEST ITSLicenseOverride ITS_SET_DEV SelfTest; do
  if grep -qa "$needle" "$BIN"; then
    echo "✗ 出荷ビルドに '$needle' が含まれています。中止します。"
    exit 1
  fi
done
echo "  開発用コードなし ✓"

echo "▶ エクスポート中..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

echo ""
echo "完了: $EXPORT_DIR"
ls -la "$EXPORT_DIR"
echo ""
echo "次: Xcode の Organizer（Window > Organizer）からアップロードするか、"
echo "    Transporter.app に上記 .pkg をドラッグしてアップロードしてください。"
