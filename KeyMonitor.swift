import Cocoa
import Carbon
import os

/// GUI アプリの print は unified log に乗らないため、追跡は os_log で行う。
/// 読むとき: /usr/bin/log show --predicate 'subsystem == "com.ithinkso.app"' --last 2m
let itsLog = Logger(subsystem: "com.ithinkso.app", category: "keymonitor")

class KeyMonitor {

    // MARK: - 調整点

    /// 何文字以上で救出対象にするか。1 = 「a」→「あ」も救う
    private let rescueThreshold = 1
    /// これを超えたら救済しない。中途半端に一部だけ打ち直すと事故になるため
    private let maxBufferCount = 100
    /// BS 連打の間隔。0 だと取りこぼすアプリがある
    private let backspaceInterval = 0.008
    /// Kotoeri に流し込む間隔。IME の変換処理を待つ必要がある
    private let injectInterval = 0.030
    /// IME を通さない注入の間隔。変換待ちが不要なので詰められる
    private let injectIntervalASCII = 0.005
    /// 救済が固まったときに強制解除するまでの時間
    private let rescueTimeout = 6.0
    /// IME 切替がアプリ側の入力コンテキストに追随するまでの最低待ち時間。
    /// 短いバッファだと BS の所要時間が足りないため下限として必要
    private let imeSettleDelay = 0.25

    // MARK: - キーコード

    private let capsLockKeyCode: CGKeyCode = 57   // 標準キーボード（flagsChanged で来る）
    private let eisuKeyCode: CGKeyCode = 102      // JIS 英数キー
    private let f18KeyCode: CGKeyCode = 79        // F18（Caps Lock を Karabiner でリマップ）
    private let backspaceKeyCode: CGKeyCode = 51
    private let escapeKeyCode: CGKeyCode = 53
    private let spaceKeyCode: CGKeyCode = 49
    private let returnKeyCode: CGKeyCode = 36

    // MARK: - 入力ソース

    /// 完全一致で、この優先順に選ぶ。
    /// 部分一致にすると "com.google.inputmethod.Japanese.Roman"（英数）まで
    /// 当たってしまい、日本語のつもりで英数に切り替わる事故が起きる。
    private let japaneseSourceIDs = [
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
        "com.google.inputmethod.Japanese.base",
    ]
    private let englishSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
    ]

    // MARK: - 状態

    private var buffer: [(keyCode: CGKeyCode, char: String)] = []
    /// 上限を超えた記録。超えた回は救済を諦める
    private var bufferOverflowed = false
    private var isRescuing = false
    private var hyperWasActive = false
    private var watchdog: DispatchWorkItem?
    /// 自タップが「自分の注入イベント」として認識した数。タグが機能しているかの確認用
    private var syntheticSeen = 0

    /// 自分が注入した合成イベントを識別するタグ ("ITS" in hex)
    private let syntheticUserData: Int64 = 0x49545300
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var rescueThresholdPublic: Int { rescueThreshold }

    // MARK: - 開始 / 停止

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                   | (1 << CGEventType.keyUp.rawValue)
                                   | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        // options: .defaultTap は抑止・改変が可能なモード。
        // sandbox 下では ListenEvent だけでは作れず、PostEvent の許可も必要（実測）。
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            itsLog.error("event tap の作成に失敗。ListenEvent と PostEvent の両方が許可されているか確認")
            Unmanaged<KeyMonitor>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        itsLog.error("event tap 作成・有効化 OK")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        resetBuffer()
        endRescue()
    }

    // MARK: - イベント処理

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 自分が注入した合成イベントはタグで識別してそのまま通す
        if event.getIntegerValueField(.eventSourceUserData) == syntheticUserData {
            syntheticSeen += 1
            return Unmanaged.passRetained(event)
        }

        // 救済中に打たれた実キーは捨てる。
        // 素通しすると、注入中のキー列に実キーが割り込んで文字列が壊れる。
        // 50文字の救済は最悪2秒以上かかるので、素通しでは確実に混入する。
        guard !isRescuing else { return nil }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            let flags = event.flags
            let isHyper = flags.contains(.maskShift)
                       && flags.contains(.maskCommand)
                       && flags.contains(.maskControl)
                       && flags.contains(.maskAlternate)

            if isHyper {
                hyperWasActive = true
            } else if hyperWasActive {
                // 4つ全部押していた→離した瞬間に発火
                hyperWasActive = false
                if let saved = takeRescuableBuffer() {
                    triggerRescue(saved: saved, toJapanese: false)
                }
            }

            // Caps Lock は常に飲み込む（大文字ロック機能を犠牲にする）。
            // 救済が成立した時だけ飲み込む作りにすると、条件を満たさなかった回だけ
            // ロックが切り替わり、同じキーを押しているのに挙動が変わって混乱する。
            if keyCode == capsLockKeyCode {
                if let saved = takeRescuableBuffer() {
                    triggerRescue(saved: saved, toJapanese: !isCurrentlyJapaneseIME())
                }
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // F18（Caps Lock を Karabiner でリマップ）→ 今の IME と逆方向へ
        if keyCode == f18KeyCode {
            if let saved = takeRescuableBuffer() {
                triggerRescue(saved: saved, toJapanese: !isCurrentlyJapaneseIME())
            }
            return Unmanaged.passRetained(event)
        }

        // 英数キー → バッファリセットのみ（通常の切り替えを邪魔しない）
        if keyCode == eisuKeyCode {
            resetBuffer()
            return Unmanaged.passRetained(event)
        }

        if keyCode == backspaceKeyCode {
            if !buffer.isEmpty { buffer.removeLast() }
            return Unmanaged.passRetained(event)
        }

        // Space / Return / Escape → 確定または取消なのでバッファを切る
        if keyCode == spaceKeyCode || keyCode == returnKeyCode || keyCode == escapeKeyCode {
            resetBuffer()
            return Unmanaged.passRetained(event)
        }

        // 修飾キーコンボ → バッファリセット
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetBuffer()
            return Unmanaged.passRetained(event)
        }

        // 通常文字
        if let chars = unicodeChar(from: event), isBufferable(chars) {
            if buffer.count >= maxBufferCount {
                // 溢れた。以降このバッファでは救済しない
                bufferOverflowed = true
            } else {
                buffer.append((keyCode: keyCode, char: chars))
            }
        } else if keyCode != capsLockKeyCode && keyCode != eisuKeyCode && keyCode != f18KeyCode {
            resetBuffer()
        }

        return Unmanaged.passRetained(event)
    }

    /// バッファに溜めてよい文字か。
    /// アルファベットに加えて "-" を通す。日本語の長音「ー」は "-" で入力するため、
    /// これを境界扱いにすると「ma-ku（マーク）」のような実文が丸ごと救済できなくなる。
    private func isBufferable(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return false }
        if first.properties.isAlphabetic { return true }
        if s == "-" { return true }
        return false
    }

    private func resetBuffer() {
        buffer.removeAll()
        bufferOverflowed = false
    }

    /// 救済対象として取り出す。条件を満たさなければ nil を返しバッファは捨てる。
    private func takeRescuableBuffer() -> [(keyCode: CGKeyCode, char: String)]? {
        let saved = buffer
        let overflowed = bufferOverflowed
        resetBuffer()

        if overflowed {
            itsLog.error("バッファ上限超過 (>\(self.maxBufferCount)) → 救済しない")
            return nil
        }
        guard saved.count >= rescueThreshold else { return nil }
        let text = saved.map { $0.char }.joined()
        guard looksLikeRomaji(text) else {
            itsLog.error("ローマ字と判定されず救済しない: \(text, privacy: .public)")
            return nil
        }
        return saved
    }

    // MARK: - 救済

    private func beginRescue() {
        isRescuing = true
        syntheticSeen = 0
        watchdog?.cancel()
        // 非同期チェーンが途中で切れると isRescuing が true のまま固まり、
        // 全キー入力が捨てられ続けてアプリが無言で死ぬ。必ず強制解除する。
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRescuing else { return }
            print("[ITS] watchdog fired → 救済が固まったので強制解除")
            self.endRescue()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rescueTimeout, execute: work)
    }

    private func endRescue() {
        if isRescuing {
            itsLog.error("救済終了 自タップが認識した合成イベント数=\(self.syntheticSeen)")
        }
        isRescuing = false
        watchdog?.cancel()
        watchdog = nil
    }

    private func triggerRescue(saved: [(keyCode: CGKeyCode, char: String)], toJapanese: Bool) {
        beginRescue()
        let romaji = saved.map { $0.char }.joined()
        let dir = toJapanese ? "E→J" : "J→E"
        itsLog.error("救済開始 \(dir, privacy: .public) '\(romaji, privacy: .public)' \(saved.count)文字 現IME=\(self.currentSourceID(), privacy: .public)")

        if toJapanese {
            rescueToJapanese(saved)
        } else {
            rescueToEnglish(saved)
        }
    }

    // ── 英語 → 日本語 ────────────────────────────────────────────────
    // 画面には確定済みの ASCII が入っているので、文字数ぶん BS で消すしかない。
    //
    // 順序が重要: 先に IME を切り替えてから BS を撃つ。
    // TISCopyCurrentKeyboardInputSource() が返すのはシステム全体の入力ソースで、
    // 実際に文字を受け取るアプリ側の入力コンテキストはそれに遅れて追随する。
    // 切替直後に注入すると、システム上は日本語なのにアプリはまだ英語で、
    // ローマ字が ASCII のまま入ってしまう。
    // BS の所要時間（37文字で約470ms）がそのまま追随待ちになるので、
    // この順序なら待ち時間を足さずに済む。
    private func rescueToJapanese(_ saved: [(keyCode: CGKeyCode, char: String)]) {
        switchIME(toJapanese: true) { [weak self] in
            guard let self = self else { return }
            self.postBackspaces(saved.count) {
                // keyCode のみ送って Kotoeri に変換させる。
                // keyboardSetUnicodeString を呼ぶと「変換済み」と判断されて素通しになる。
                self.injectKeys(saved, index: 0, interval: self.injectInterval, asLiteral: false) {
                    self.endRescue()
                }
            }
        }
    }

    // ── 日本語 → 英語 ────────────────────────────────────────────────
    // ライブ変換が有効だと画面上は漢字かな交じりになっており、
    // 何文字消せばよいかをローマ字から計算することが原理的にできない。
    // Esc で未確定合成を丸ごと破棄すれば、数を数えずに済む。
    private func rescueToEnglish(_ saved: [(keyCode: CGKeyCode, char: String)]) {
        postSyntheticKey(escapeKeyCode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.switchIME(toJapanese: false) { [weak self] in
                guard let self = self else { return }
                // 英語レイアウトなので keyCode だけでも正しい ASCII になるが、
                // ユニコード文字列も併せてセットして、どちらを見るアプリでも合うようにする。
                self.injectKeys(saved, index: 0, interval: self.injectIntervalASCII, asLiteral: true) {
                    self.endRescue()
                }
            }
        }
    }

    // MARK: - イベント注入

    /// 注入イベントのソース状態。
    /// 元の実装（変換に成功していた）が .privateState だったので、これに合わせる
    private let injectSourceState: CGEventSourceStateID = .privateState

    private func syntheticSource() -> CGEventSource? {
        let src = CGEventSource(stateID: injectSourceState)
        src?.userData = syntheticUserData
        return src
    }

    private func postSyntheticKey(_ keyCode: CGKeyCode) {
        let src = syntheticSource()
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = CGEventFlags(rawValue: 0)
        up?.flags   = CGEventFlags(rawValue: 0)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// BS を間隔をあけて連打する。まとめて撃つと取りこぼすアプリがある。
    private func postBackspaces(_ count: Int, done: @escaping () -> Void) {
        guard count > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: done)
            return
        }
        postSyntheticKey(backspaceKeyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + backspaceInterval) { [weak self] in
            self?.postBackspaces(count - 1, done: done)
        }
    }

    private func injectKeys(_ keys: [(keyCode: CGKeyCode, char: String)],
                            index: Int,
                            interval: TimeInterval,
                            asLiteral: Bool,
                            done: @escaping () -> Void) {
        guard index < keys.count else {
            itsLog.error("注入完了 \(keys.count)文字 現IME=\(self.currentSourceID(), privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: done)
            return
        }
        let entry = keys[index]
        let src = syntheticSource()
        let down = CGEvent(keyboardEventSource: src, virtualKey: entry.keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: entry.keyCode, keyDown: false)
        // 修飾キーなし。システムショートカットの誤発火を防ぐ
        down?.flags = CGEventFlags(rawValue: 0)
        up?.flags   = CGEventFlags(rawValue: 0)

        let carriedBefore = down.flatMap { unicodeChar(from: $0) } ?? "(なし)"

        if asLiteral {
            // J→E: IME を通さず文字をそのまま入れたいので、明示的にセットする
            var units = Array(entry.char.utf16)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        } else {
            // E→J: Kotoeri にローマ字として解釈させたい。
            // CGEvent はキーコードから現在のレイアウトでユニコード文字列を
            // 自動で埋めてしまい、それが入っていると Kotoeri は
            // 「変換済み」と判断して素通しする（= ASCII のまま出る）。
            // 長さ0を渡して明示的に空にする。
            down?.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            up?.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
        }

        if index == 0 {
            let carriedAfter = down.flatMap { unicodeChar(from: $0) } ?? "(なし)"
            itsLog.error("注入開始 \(keys.count)文字 literal=\(asLiteral) 現IME=\(self.currentSourceID(), privacy: .public) 抱えていた文字=\(carriedBefore, privacy: .public) → 消去後=\(carriedAfter, privacy: .public)")
        }

        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.injectKeys(keys, index: index + 1, interval: interval, asLiteral: asLiteral, done: done)
        }
    }

    // MARK: - 入力ソース

    private func keyboardSources() -> [TISInputSource] {
        // キーボード系だけに絞る。絞らないと PressAndHold 等が混ざる
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    /// IME を切り替え、「実際に切り替わったこと」を確認してから続きを実行する。
    /// 固定時間待ちだと切替前に注入が始まり、ローマ字がそのまま ASCII で出てしまう。
    private func switchIME(toJapanese: Bool, then: @escaping () -> Void) {
        let ids = toJapanese ? japaneseSourceIDs : englishSourceIDs
        let sources = keyboardSources()

        var selected: String?
        for id in ids {
            if let source = sources.first(where: { inputSourceID($0) == id }) {
                let status = TISSelectInputSource(source)
                itsLog.error("IME切替要求 → \(id, privacy: .public) OSStatus=\(status)")
                selected = id
                break
            }
        }
        guard selected != nil else {
            itsLog.error("切替先の入力ソースが見つからない: \(ids, privacy: .public)")
            then()
            return
        }

        waitUntilIME(japanese: toJapanese, attempts: 20, then: then)
    }

    /// 50ms 間隔で最大 attempts 回、目的の IME になるまで待つ
    private func waitUntilIME(japanese: Bool, attempts: Int, then: @escaping () -> Void) {
        if isCurrentlyJapaneseIME() == japanese {
            // 切替が反映された後、IME が入力を受け付けるまでにさらに間がある
            DispatchQueue.main.asyncAfter(deadline: .now() + imeSettleDelay) { [weak self] in
                itsLog.error("IME切替確認OK 現IME=\(self?.currentSourceID() ?? "?", privacy: .public)")
                then()
            }
            return
        }
        guard attempts > 0 else {
            itsLog.error("IME切替が確認できないまま続行 現IME=\(self.currentSourceID(), privacy: .public)")
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilIME(japanese: japanese, attempts: attempts - 1, then: then)
        }
    }

    private func currentSourceID() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = inputSourceID(src) else { return "(取得不可)" }
        return id
    }

    private func isCurrentlyJapaneseIME() -> Bool {
        for source in keyboardSources() {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelected) else { continue }
            let isSelected = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
            guard CFBooleanGetValue(isSelected) else { continue }
            guard let id = inputSourceID(source) else { continue }
            if id.contains("Japanese") || id.contains("Kotoeri") { return true }
        }
        return false
    }

    private func inputSourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    // MARK: - 判定

    private func unicodeChar(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var units = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &units)
        let s = String(utf16CodeUnits: units, count: length)
        return s.isEmpty ? nil : s
    }

    /// ローマ字らしいか。"-"（長音）を許容するため isLetter だけでは判定できない。
    private func looksLikeRomaji(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        let hasVowel = lower.contains(where: { "aeiou".contains($0) })
        let allValid = lower.allSatisfy { $0.isLetter || $0 == "-" }
        return hasVowel && allValid
    }
}
