#!/bin/zsh
# 画面収録用にアプリをビルドして /Applications に入れる
#
#   ./record.sh
#
# App Review から求められている「アプリの動作を示す画面収録」を
# 撮るための準備をします。アップロードはしません。
set -e
cd "${0:a:h}"

echo "▶ macOS の確認"
BUILD=$(sw_vers -buildVersion)
if [[ "$BUILD" =~ [a-z]$ ]]; then
  echo "⚠️  このMacはベータ版macOS($BUILD)です。"
  echo "    審査では「最新のOS上での録画」が求められているので、"
  echo "    可能なら正式版のMacで録画してください。"
else
  echo "✅ 正式版macOSです($BUILD)"
fi

xattr -cr . 2>/dev/null || true

echo "▶ ビルド中..."
xcodebuild -project IThinkSo.xcodeproj -scheme IThinkSo -configuration Release \
  -derivedDataPath build/demo -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" || true

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

────────────────────────────────────────────
【録画の前に】
  1. メニューバーの吹き出しアイコンから権限をリクエスト
  2. システム設定で「入力監視」と「アクセシビリティ」を許可
  3. ★アプリを再起動する（許可しただけでは反映されません）

【録画する内容】⌘⇧5 で画面収録
  ・★先に TextEdit のフォントを 24〜36pt に大きくしておく
    （縮小しても文字が読めるように。審査員が読めないと意味がない）
  ・アプリの起動から始めること（審査の要求事項）
  ・メニューバーのアイコンとメニューを見せる
  ・E→J: TextEdit で英語モードのまま次を入力し、右⌘を素早く2回:
      sonocheckma-kuhadokomadegahannidesuka
    → 「そのcheckマークはどこまでが範囲ですか」になる
  ・J→E: 日本語モードにして gitcommit と入力（かなで表示される）、
    続けて左⌘を素早く2回
    → 英字 gitcommit に戻り、入力ソースが ABC に切り替わる
  ・権限ダイアログが出る場面があれば含める

  1〜2分で十分です。

【録画後】FHD に変換（Retina のままだと数百MBになり添付で詰まる）
  ffmpeg -i 録画.mov -vf scale=1920:-2 -c:v libx264 -crf 23 \
    -preset medium -pix_fmt yuv420p -an ithinkso-demo.mp4

  ※ 1920:-2 は比率を保つ指定。1920x1080 に決め打ちすると
     16:10 の MacBook 画面は縦が潰れる

  App Store Connect → 左サイドバー「App Review」
  →「App Reviewに返信」
  動画を添付し、docs/review-reply-2.1.md の
  英文（返信本文）を貼って送信してください。
  返信文の項目2「macOS 26」は、この Mac の実際のバージョンに直すこと。
────────────────────────────────────────────

NOTE
