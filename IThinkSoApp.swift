import SwiftUI

@main
struct IThinkSoApp: App {

    @StateObject private var appState = AppState()

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
