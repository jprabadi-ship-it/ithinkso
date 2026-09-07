import Foundation
import AppKit
import CoreGraphics
import Carbon
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
                itsLog.error("SMAppService error: \(error)")
                // 失敗時は状態をロールバック（再帰防止）
                isUpdatingLaunchAtLogin = true
                launchAtLogin = oldValue
                isUpdatingLaunchAtLogin = false
            }
        }
    }

    let keyMonitor = KeyMonitor()
    private var permissionTimer: Timer?

    #if ITS_SELECTION
    /// 選択範囲の打ち直しに使うアクセシビリティ権限（kTCCServiceAccessibility）が
    /// あるか。hasInputPermission（ListenEvent + PostEvent）とは別の権限で、
    /// システム設定では同じペインに畳まれて表示される
    @Published var hasAXPermission: Bool = false

    /// 選択範囲の打ち直し。既定オフのオプトイン。
    /// 「既定では他アプリの画面内容を読まない」という公開済みの約束を守るため、
    /// 利用者が自分で有効にした場合に限って読み取りが起きる
    @Published var selectionRescueEnabled: Bool = UserDefaults.standard.bool(forKey: "ITSSelectionRescue") {
        didSet {
            UserDefaults.standard.set(selectionRescueEnabled, forKey: "ITSSelectionRescue")
            keyMonitor.selectionRescueEnabled = selectionRescueEnabled
            if selectionRescueEnabled { requestAXPermission() }
        }
    }
    private var axTimer: Timer?

    func refreshAXStatus() {
        hasAXPermission = SelectionReader.isTrusted
    }

    /// 未許可なら OS のダイアログを出し、付与されるまで1秒ごとに見る
    func requestAXPermission() {
        refreshAXStatus()
        guard !hasAXPermission else { return }
        SelectionReader.requestTrust()
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.refreshAXStatus()
                if self.hasAXPermission {
                    timer.invalidate()
                    self.axTimer = nil
                }
            }
        }
    }
    #endif

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissionStatus()
        #if ITS_SELECTION
        keyMonitor.selectionRescueEnabled = selectionRescueEnabled
        refreshAXStatus()
        #endif

        if canRun {
            keyMonitor.start()
        }

        #if ITS_DEVTOOLS
        if SelfTest.isEnabled {
            // 自己テスト中は救済ロジック(タップ)を止めておく（注入を自分で拾わないため）
            keyMonitor.stop()
            SelfTest.shared.keyMonitor = keyMonitor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SelfTest.shared.run()
            }
        }
        #endif
    }

    // App Sandbox 下では AXIsProcessTrusted は常に false を返すため使えない。
    // CGEventTap は ListenEvent、CGEvent.post は PostEvent という別の TCC サービスで、
    // どちらも sandbox 互換。さらに抑止つきタップ（.defaultTap）には
    // ListenEvent だけでなく PostEvent も必要（実測で確認済み）。
    /// 機能を動かしてよい状態か（権限 + 有効化）
    var canRun: Bool { hasInputPermission && isEnabled }

    func refreshPermissionStatus() {
        let wasGranted = hasInputPermission
        hasInputPermission = CGPreflightListenEventAccess() && CGPreflightPostEventAccess()
        #if ITS_SELECTION
        refreshAXStatus()
        #endif
        if hasInputPermission && !wasGranted && canRun {
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

#if ITS_DEVTOOLS
// 以下は開発用の自己テスト装置。Debug ビルドにのみ含まれ、
// App Store に提出する Release ビルドには一切入らない。
// MARK: - 自己テスト
//
// 環境変数 ITS_SELFTEST=1 で起動すると、自前のテキストビューに対して
// 「IME切替 → キーコード注入 → 結果読み取り」を自動で行う。
// 注入した文字が IME で変換されるかを、人手を介さず何度でも試すための仕掛け。
// 起動: ITS_SELFTEST=1 /Applications/IThinkSo.app/Contents/MacOS/IThinkSo
@MainActor
final class SelfTest: NSObject {

    private var window: NSWindow?
    private var textView: NSTextView?
    weak var keyMonitor: KeyMonitor?

    static let shared = SelfTest()

    /// 1 = 自前のテキストビューへ注入 / 2 = 前面の別アプリへ注入
    static var mode: Int {
        Int(ProcessInfo.processInfo.environment["ITS_SELFTEST"] ?? "0") ?? 0
    }
    static var isEnabled: Bool { mode > 0 }

    /// 注入するローマ字。keyCode に変換して送る
    private var sample: String {
        ProcessInfo.processInfo.environment["ITS_TEXT"] ?? "sono"
    }

    /// 検証用に条件を環境変数で差し替える
    private static var postTap: CGEventTapLocation {
        switch ProcessInfo.processInfo.environment["ITS_TAP"] ?? "session" {
        case "hid":       return .cghidEventTap
        case "annotated": return .cgAnnotatedSessionEventTap
        default:          return .cgSessionEventTap
        }
    }
    private static var switchDelay: Double {
        Double(ProcessInfo.processInfo.environment["ITS_DELAY"] ?? "0.6") ?? 0.6
    }
    private static var sourceState: CGEventSourceStateID {
        switch ProcessInfo.processInfo.environment["ITS_SRC"] ?? "private" {
        case "hidsys":   return .hidSystemState
        case "combined": return .combinedSessionState
        default:         return .privateState
        }
    }

    func run() {
        let sbx = NSHomeDirectory().contains("/Library/Containers/") ? "有効" : "無効"
        itsLog.error("=== 自己テスト開始 mode=\(Self.mode) sandbox=\(sbx, privacy: .public) ===")

        if Self.mode == 2 {
            // 前面の別アプリへ注入する。自分はウィンドウを出さない（フォーカスを奪わない）
            itsLog.error("自己テスト: 前面アプリ=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
            step1SwitchIME()
            return
        }

        if Self.mode == 3 {
            // 実運用フロー（区間分割つき E→J 救済）を前面アプリに対して実行
            itsLog.error("自己テスト: mode3 実救済 前面=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
            keyMonitor?.testRescueToJapanese(sample)
            // 救済完了(注入+確定)を見込んで待ち、末尾合成を確定して保存させる
            let wait = 3.0 + Double(sample.count) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.postKey(36, flags: [])                      // 末尾合成を確定
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.postKey(1, flags: .maskCommand)         // Cmd+S
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.finish()
                    }
                }
            }
            return
        }

        if Self.mode == 5 {
            // J→E 検証: かなキーで日本語化 → ローマ字注入で合成を作る
            // → F10+Return+英数 チェーンで英語に戻す
            itsLog.error("自己テスト: mode5 J→E(F10) 前面=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
            postKey(104, flags: [])                 // かな
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.inject(Array(self.sample), index: 0)   // 合成を作る（step3Read には進まず途中で止まる想定はないので流用しない）
            }
            // inject 完了後 step3Read が走るのを避けるため、mode5 では
            // inject のコールバックに頼らず時間で JtoE を起動する
            let wait = 1.2 + Double(sample.count) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.keyMonitor?.testRescueToEnglish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.finish()
                }
            }
            return
        }

        if Self.mode == 4 {
            // 区間分割ロジックの単体確認（注入なし）
            let segs = KeyMonitor.segment(sample.map { String($0) })
            let desc = segs.map { seg -> String in
                let mark = seg.corrected ? "✱" : ""
                return seg.isEnglish ? "[EN:\(seg.text)\(mark)]" : "[JA:\(seg.text)\(mark)]"
            }.joined()
            itsLog.error("分割テスト '\(self.sample, privacy: .public)' → \(desc, privacy: .public)")
            finish()
            return
        }

        let rect = NSRect(x: 200, y: 200, width: 480, height: 120)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "IThinkSo self test"
        let tv = NSTextView(frame: rect)
        tv.isEditable = true
        tv.isRichText = false
        w.contentView = tv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(tv)
        window = w
        textView = tv

        // ウィンドウが前面に出てフォーカスが確定するのを待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.step1SwitchIME()
        }
    }

    private func step1SwitchIME() {
        let jp = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
        let sources = (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard let src = sources.first(where: {
            guard let p = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
            return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String) == jp
        }) else {
            itsLog.error("自己テスト: Kotoeri が見つからない")
            finish()
            return
        }
        let how = ProcessInfo.processInfo.environment["ITS_SWITCH"] ?? "tis"
        if how == "key" {
            // かなキー(keyCode 104)を注入して切り替える。
            // 通常のキー経路を通るので、前面アプリの入力コンテキストに効くはず
            postKey(104, flags: [])
            itsLog.error("自己テスト: IME切替=かなキー注入(104)")
        } else if how == "both" {
            _ = TISSelectInputSource(src)
            postKey(104, flags: [])
            itsLog.error("自己テスト: IME切替=TIS+かなキー")
        } else {
            let st = TISSelectInputSource(src)
            itsLog.error("自己テスト: IME切替=TIS OSStatus=\(st)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchDelay) { [weak self] in
            self?.step2Inject()
        }
    }

    private func step2Inject() {
        itsLog.error("自己テスト: 注入開始 '\(self.sample, privacy: .public)' 現IME=\(Self.currentIME(), privacy: .public) firstResponder=\(String(describing: self.window?.firstResponder), privacy: .public)")
        inject(Array(sample), index: 0)
    }

    private func inject(_ chars: [Character], index: Int) {
        guard index < chars.count else {
            if Self.mode == 5 { return }  // mode5 は run() 側のタイマーで続きを駆動する
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.step3Read()
            }
            return
        }
        let keyCode = Self.keyCode(for: chars[index])
        let src = CGEventSource(stateID: Self.sourceState)
        src?.userData = 0x49545300
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = CGEventFlags(rawValue: 0)
        up?.flags   = CGEventFlags(rawValue: 0)
        down?.post(tap: Self.postTap)
        up?.post(tap: Self.postTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.inject(chars, index: index + 1)
        }
    }

    private func step3Read() {
        if Self.mode == 2 {
            // 別アプリの中身は読めないので、確定(Return)して保存(Cmd+S)させ、
            // ファイルの中身を外側から読んでもらう
            postKey(36, flags: [])                       // Return で確定
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.postKey(1, flags: .maskCommand)    // Cmd+S
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    itsLog.error("自己テスト: 保存まで実行した。ファイルを確認のこと")
                    self?.finish()
                }
            }
            return
        }
        let got = textView?.string ?? "(取得不可)"
        let isASCII = got.allSatisfy { $0.isASCII }
        itsLog.error("自己テスト結果: 入力='\(self.sample, privacy: .public)' → 画面='\(got, privacy: .public)' 判定=\(isASCII ? "ASCIIのまま（変換されず）" : "変換された", privacy: .public)")
        finish()
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: Self.sourceState)
        src?.userData = 0x49545300
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags   = flags
        down?.post(tap: Self.postTap)
        up?.post(tap: Self.postTap)
    }

    private func finish() {
        itsLog.error("=== 自己テスト終了 ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private static func currentIME() -> String {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// ANSI 配列のキーコード（テストに使う文字のみ）
    private static func keyCode(for c: Character) -> CGKeyCode {
        let map: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
            "j": 38, "k": 40, "n": 45, "m": 46, "-": 27,
        ]
        return map[c] ?? 0
    }
}
#endif
