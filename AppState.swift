import Foundation
import AppKit
import ServiceManagement

@MainActor
class AppState: ObservableObject {

    @Published var isEnabled: Bool = true {
        didSet {
            isEnabled ? keyMonitor.start() : keyMonitor.stop()
        }
    }

    @Published var hasAccessibilityPermission: Bool = false

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

        // Accessibility が既に許可されていれば即スタート
        if hasAccessibilityPermission && isEnabled {
            keyMonitor.start()
        }
    }

    func refreshPermissionStatus() {
        let wasTrusted = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()
        // 権限が新たに付与されたら即スタート
        if hasAccessibilityPermission && !wasTrusted && isEnabled {
            keyMonitor.start()
        }
    }

    /// システム環境設定のアクセシビリティ画面を開いてポーリング開始
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPollingForPermission()
    }

    private func startPollingForPermission() {
        permissionTimer?.invalidate()
        // 1秒ごとに権限チェック。付与されたら自動で start() → タイマー停止
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.refreshPermissionStatus()
                if self.hasAccessibilityPermission {
                    timer.invalidate()
                    self.permissionTimer = nil
                }
            }
        }
    }
}
