import SwiftUI

@main
struct IThinkSoApp: App {

    @StateObject private var appState = AppState()

    init() {
        // gigowat.com の台帳で新しい版を確かめ、あれば入れ替えるかを聞く（App Store 版では何もしない）
        GigowatUpdater.shared.checkOnLaunch(slug: "ithinkso")
    }

    var body: some Scene {
        // macOS 13+ MenuBarExtra — Dock アイコンなしでメニューバーに常駐
        MenuBarExtra {
            MenuView()
                .environmentObject(appState)
        } label: {
            // 有効時は塗りつぶし、無効時は線だけ
            Label(
                "I think so",
                systemImage: appState.isEnabled ? "text.bubble.fill" : "text.bubble"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
