#!/bin/zsh
# 画面収録用にアプリをビルドして /Applications に入れる
#
#   ./install-for-demo.sh
#
# App Review への返信に添付する動画を撮るための準備。
# 提出用の submit.sh と違い、アップロードはしない。
set -e
cd "${0:a:h}"

echo "▶ macOS の確認"
BUILD=$(sw_vers -buildVersion)
if [[ "$BUILD" =~ [a-z]$ ]]; then
  echo "⚠️  このMacはベータ版macOS($BUILD)です。"
  echo "    審査には「最新のOS上での録画」が求められているため、"
  echo "    可能なら正式版のMacで録画してください。"
  echo ""
fi
sw_vers | sed 's/^/    /'

echo "▶ ビルド中..."
xcodebuild -project IThinkSo.xcodeproj -scheme IThinkSo -configuration Release \
  -derivedDataPath build/demo -allowProvisioningUpdates build 2>&1 | tail -3

APP="build/demo/Build/Products/Release/IThinkSo.app"
[[ -d "$APP" ]] || { echo "❌ ビルド成果物が見つかりません"; exit 1; }

echo "▶ インストール"
pkill -x IThinkSo 2>/dev/null || true
sleep 1
rm -rf /Applications/IThinkSo.app
cp -R "$APP" /Applications/IThinkSo.app
open /Applications/IThinkSo.app

cat <<'NOTE'

✅ /Applications/IThinkSo.app を起動しました。

【録画の前に】
  1. メニューバーの吹き出しアイコンから権限をリクエスト
  2. システム設定で「入力監視」と「アクセシビリティ」を許可
  3. ★アプリを再起動する（許可しただけでは反映されません）

【録画する内容】⌘⇧5 で画面収録
  ・アプリの起動から始めること（審査の要求事項）
  ・メニューバーのアイコンとメニューを見せる
  ・TextEdit で英語モードのまま次を入力し、かなキーを素早く2回:
      sonocheckma-kuhadokomadegahannidesuka
    → 「そのcheckマークはどこまでが範囲ですか」になる
  ・日本語モードで gitcommit と入力し、かなキーを素早く2回
    → 英字 gitcommit に戻る
  ・権限ダイアログが出る場面があれば含める

  1〜2分で十分です。

【録画後】
  App Store Connect → App Review → 「App Reviewに返信」
  動画を添付し、docs/review-reply-2.1.md の英文を貼って送信

NOTE
