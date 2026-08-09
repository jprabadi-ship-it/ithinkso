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

            Text("\(appState.keyMonitor.rescueThresholdPublic)文字以上のローマ字入力時:")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Caps Lock → 日本語 / 英語 自動判定")
                .font(.caption)
                .foregroundColor(.secondary)

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
}
