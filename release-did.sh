#!/bin/zsh
# Developer ID 版のビルド → 公証 → DMG 作成まで一括
#
# 前提: ~/.appstore_env (ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH)
# Google Drive 配下では署名が壊れるため、必ずローカルにコピーして作業する
set -e
source ~/.appstore_env

VER=${1:?使い方: ./release-did.sh <バージョン> <ビルド番号>  例: ./release-did.sh 1.0.1 8}
BUILD=${2:?ビルド番号がありません}
SRC="${0:a:h}"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "▶ ローカルへコピー"
rsync -a --exclude .git --exclude docs "$SRC"/ "$W"/
xattr -cr "$W"

echo "▶ ビルド (sandbox なし / hardened runtime あり / Developer ID)"
cd "$W"
xcodebuild -project IThinkSo.xcodeproj -scheme IThinkSo -configuration Release \
  -derivedDataPath "$W/dd" \
  ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_ENTITLEMENTS="IThinkSo/IThinkSo-DID.entitlements" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: gigowat (3HCG7Y94FX)" \
  DEVELOPMENT_TEAM=3HCG7Y94FX \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$BUILD" \
  clean build | tail -2

APP="$W/dd/Build/Products/Release/IThinkSo.app"

echo "▶ アプリを公証"
ditto -c -k --keepParent "$APP" "$W/IThinkSo.zip"
xcrun notarytool submit "$W/IThinkSo.zip" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"

echo "▶ DMG 作成・署名・公証"
STAGE="$W/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$HOME/Desktop/IThinkSo-$VER.dmg"; rm -f "$DMG"
hdiutil create -volname "I think so" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "Developer ID Application: gigowat (3HCG7Y94FX)" --timestamp "$DMG"
xcrun notarytool submit "$DMG" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"

echo "▶ 検証"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "🎉 完成: $DMG"
