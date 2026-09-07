import SwiftUI

struct MenuView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { appState.isEnabled.toggle() }) {
                HStack {
                    Image(systemName: appState.isEnabled ? "checkmark" : "")
                        .frame(width: 16)
                    Text(appState.isEnabled ? "有効 (クリックで無効化)" : "無効 (クリックで有効化)")
                }
            }

            Divider()

            Text("右⌘×2 / かな×2 → 日本語に打ち直し")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("左⌘×2 / 英数×2 → 英語に打ち直し")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("直前の入力を日本語に打ち直す") {
                appState.keyMonitor.rescueNowToJapanese()
            }
            Text("(メニューを閉じて1秒後に実行)")
                .font(.caption)
                .foregroundColor(.secondary)

            #if ITS_SELECTION
            Divider()

            // 既存の「有効 (クリックで無効化)」と同じく、文言そのものが状態を語る形にする。
            // チェックマークだけだと、出ないときに有効か無効か判断できない
            Button(action: { appState.selectionRescueEnabled.toggle() }) {
                HStack {
                    Image(systemName: appState.selectionRescueEnabled ? "checkmark" : "")
                        .frame(width: 16)
                    Text(appState.selectionRescueEnabled
                         ? "選択したテキストも打ち直す: オン (クリックでオフ)"
                         : "選択したテキストも打ち直す: オフ (クリックでオン)")
                }
            }
            Text(selectionStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
            if appState.selectionRescueEnabled && !appState.hasAXPermission {
                Button("アクセシビリティの許可をリクエスト") {
                    appState.requestAXPermission()
                }
            }
            #endif

            Divider()

            Button(action: { appState.launchAtLogin.toggle() }) {
                HStack {
                    Image(systemName: appState.launchAtLogin ? "checkmark" : "")
                        .frame(width: 16)
                    Text("ログイン時に自動起動")
                }
            }

            Divider()

            if !appState.hasInputPermission {
                Button("入力監視・イベント送出の権限をリクエスト") {
                    appState.requestInputPermission()
                }
                Button("プライバシー設定を開く") {
                    appState.openPrivacySettings()
                }
            }

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    #if ITS_SELECTION
    /// 「システム設定ではオンなのに動かない」を切り分けられるよう、
    /// 権限の実状態を常に見せる。hasInputPermission は AX を見ていない
    private var selectionStatusText: String {
        if !appState.selectionRescueEnabled {
            return "選択範囲: 無効（既定。他アプリの画面内容は読みません）"
        }
        return appState.hasAXPermission
            ? "選択範囲: 有効。選んで右⌘×2 / かな×2 / 上のメニュー"
            : "選択範囲: アクセシビリティの許可が必要です"
    }
    #endif
}
