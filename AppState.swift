import Foundation
import AppKit
import CoreGraphics
import ServiceManagement

@MainActor
class AppState: ObservableObject {

    @Published var isEnabled: Bool = true {
        didSet {
            isEnabled ? keyMonitor.start() : keyMonitor.stop()
        }
    }

    /// 入力監視(ListenEvent) と イベント送出(PostEvent) の両方が揃っているか
    @Published var hasInputPermission: Bool = false

    private var isUpdatingLaunchAtLogin = false
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isUpdatingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("SMAppService error: \(error)")
                // 失敗時は状態をロールバック（再帰防止）
                isUpdatingLaunchAtLogin = true
                launchAtLogin = oldValue
                isUpdatingLaunchAtLogin = false
            }
        }
    }

    let keyMonitor = KeyMonitor()
    private var permissionTimer: Timer?

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissionStatus()

        if hasInputPermission && isEnabled {
            keyMonitor.start()
        }
    }

    // App Sandbox 下では AXIsProcessTrusted は常に false を返すため使えない。
    // CGEventTap は ListenEvent、CGEvent.post は PostEvent という別の TCC サービスで、
    // どちらも sandbox 互換。さらに抑止つきタップ（.defaultTap）には
    // ListenEvent だけでなく PostEvent も必要（実測で確認済み）。
    func refreshPermissionStatus() {
        let wasGranted = hasInputPermission
        hasInputPermission = CGPreflightListenEventAccess() && CGPreflightPostEventAccess()
        if hasInputPermission && !wasGranted && isEnabled {
            keyMonitor.start()
        }
    }

    func requestInputPermission() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess()   { _ = CGRequestPostEventAccess() }
        startPollingForPermission()
    }

    private func startPollingForPermission() {
        permissionTimer?.invalidate()
        // 権限は System 設定で付与されるので、こちらからは検知できない。1秒ごとに見る。
        // ただし付与してもプロセス再起動まで反映されない場合がある。
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.refreshPermissionStatus()
                if self.hasInputPermission {
                    timer.invalidate()
                    self.permissionTimer = nil
                }
            }
        }
    }

    /// 権限画面を開く。付与後に再起動が要るケースがあるため導線として用意する
    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
