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

            Divider()

            Button(action: { appState.launchAtLogin.toggle() }) {
                HStack {
                    Image(systemName: appState.launchAtLogin ? "checkmark" : "")
                        .frame(width: 16)
                    Text("ログイン時に自動起動")
                }
            }

            Divider()

            // 許可が欠けているときは目立たせる。どこが欠けているかは画面で見せる
            Button(appState.hasInputPermission && appState.tapActive
                   ? "許可の状態…"
                   : "⚠️ 許可が足りません — 状態を見る…") {
                appState.showPermissionWindow()
            }

            Button("アップデートを確認…") {
                GigowatUpdater.shared.checkNow(slug: "ithinkso")
            }

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 許可の状態の画面
//
// I think so に要る許可はシステム設定の2か所に分かれている。
//   1. 入力監視（ListenEvent）… 打った文字と 2度押しを見る
//   2. アクセシビリティ（PostEvent）… 打ち直しのキーを送る
// 2 はアクセシビリティの一覧に一緒に出るので、画面ではオンに見えても
// 裏で「拒否」のまま残っていることがある。ここではアプリから見えている実際の状態を出す。
struct PermissionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("I think so を動かすには、システム設定の2か所で許可が必要です。")
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                number: "1",
                title: "入力監視",
                detail: "打った文字と、⌘ / かな・英数キーの2度押しを見るため",
                granted: appState.listenGranted,
                open: { appState.openPane(.inputMonitoring) })

            PermissionRow(
                number: "2",
                title: "アクセシビリティ",
                detail: "打ち直しのキーを送るため（設定では「アクセシビリティ」の一覧にあります）",
                granted: appState.postGranted,
                open: { appState.openPane(.accessibility) })

            Divider()

            statusLine

            HStack {
                if !appState.hasInputPermission {
                    Button("許可を求める") { appState.requestInputPermission() }
                }
                Button("I think so を再起動") { appState.relaunch() }
                Spacer()
                if appState.canResetPermissions {
                    Button("許可をリセットしてやり直す") { appState.resetPermissions() }
                        .help("設定ではオンなのに ✗ のままのときに使います。I think so の許可だけを消し、起動し直して求め直します")
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var statusLine: some View {
        if !appState.isEnabled {
            Label("いまは「無効」にしています（メニューから有効にできます）", systemImage: "pause.circle")
                .foregroundColor(.secondary)
        } else if appState.tapActive {
            Label("動いています", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else if appState.hasInputPermission {
            Label("許可はそろっていますが、まだ反映されていません。「I think so を再起動」を押してください", systemImage: "arrow.clockwise.circle.fill")
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("✗ の項目をオンにしてください。オンにしたら「I think so を再起動」を押します", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("設定ではオンになっているのに ✗ のままなら、「許可をリセットしてやり直す」を押してください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let number: String
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)　\(granted ? "許可されています" : "許可されていません")")
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("設定を開く", action: open)
        }
    }
}
