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
    /// かな/英数キー注入から前面アプリの IME が切り替わるまでの待ち時間。
    /// 実測: 0.15s では不達、0.3s で安定。マージン込みで 0.4s
    private let imeSettleDelay = 0.4

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
    // 先に IME を切り替えてから BS を撃つ（BS 時間が切替の追随待ちを兼ねる）。
    //
    // 注入は区間ごとに行う:
    // - 日本語区間: keyCode 注入で Kotoeri に変換させる
    // - 英語区間:   ユニコード literal 注入で Kotoeri を素通しさせる
    // - 日本語区間の直後に英語区間が来る場合は Return で合成を確定する。
    //   確定しないと、literal が未確定合成と衝突する上、
    //   ライブ変換の「解析不能なら全体を生 ASCII に戻す」挙動に巻き込まれる。
    // - 末尾の日本語区間は確定しない（ユーザーが変換を続けられるように）
    private func rescueToJapanese(_ saved: [(keyCode: CGKeyCode, char: String)]) {
        let segs = Self.segment(saved.map { $0.char })
        let desc = segs.map { seg -> String in
            let t = saved[seg.range].map { $0.char }.joined()
            return seg.isEnglish ? "[EN:\(t)]" : "[JA:\(t)]"
        }.joined()
        itsLog.error("区間分割: \(desc, privacy: .public)")

        switchIME(toJapanese: true) { [weak self] in
            guard let self = self else { return }
            self.postBackspaces(saved.count) {
                self.injectSegments(saved, segs, 0)
            }
        }
    }

    private func injectSegments(_ saved: [(keyCode: CGKeyCode, char: String)],
                                _ segs: [Segment], _ idx: Int) {
        guard idx < segs.count else {
            endRescue()
            return
        }
        let seg = segs[idx]
        let keys = Array(saved[seg.range])
        let interval = seg.isEnglish ? injectIntervalASCII : injectInterval
        injectKeys(keys, index: 0, interval: interval, asLiteral: seg.isEnglish) { [weak self] in
            guard let self = self else { return }
            let isLast = idx == segs.count - 1
            if !seg.isEnglish && !isLast {
                // 次は英語区間（統合済みなので日本語が連続することはない）
                // → Return で合成を確定してから literal を流す
                self.postSyntheticKey(self.returnKeyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.injectSegments(saved, segs, idx + 1)
                }
            } else {
                self.injectSegments(saved, segs, idx + 1)
            }
        }
    }

    // MARK: - テストフック（SelfTest から実運用フローを駆動する）

    /// ANSI 配列の keyCode（テスト用）
    static let asciiKeyMap: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "-": 27,
    ]

    /// 文字列から buffer 相当を組み立てて E→J 救済を実行する。
    /// 前面アプリに対して BS→区間注入まで本番と同じ経路を通る
    func testRescueToJapanese(_ text: String) {
        let saved = text.compactMap { ch -> (keyCode: CGKeyCode, char: String)? in
            guard let kc = Self.asciiKeyMap[ch] else { return nil }
            return (keyCode: kc, char: String(ch))
        }
        beginRescue()
        itsLog.error("testRescue E→J '\(text, privacy: .public)' \(saved.count)文字")
        rescueToJapanese(saved)
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

    /// IME を切り替えてから続きを実行する。
    ///
    /// TISSelectInputSource は使わない。あれが返す/切り替えるのは
    /// 「呼び出したプロセスの入力コンテキスト」で、バックグラウンドの
    /// 本アプリから呼んでも前面アプリの IME は切り替わらない
    /// （自己テストで実証: TIS方式は前面アプリで ASCII のまま、
    /// かなキー注入方式は正しく変換された）。
    /// かな(104)/英数(102)キーの注入なら通常のキー経路を通り、前面アプリに効く。
    private func switchIME(toJapanese: Bool, then: @escaping () -> Void) {
        let keyCode: CGKeyCode = toJapanese ? 104 : 102  // かな / 英数
        postSyntheticKey(keyCode)
        itsLog.error("IME切替: \(toJapanese ? "かな" : "英数", privacy: .public)キー(\(keyCode))を注入")
        // かなキー投函から前面アプリの IME が実際に切り替わるまで:
        // 0.15s では不達、0.3s で安定（実測）。マージンを取って imeSettleDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + imeSettleDelay, execute: then)
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

    // MARK: - 区間分割（日本語 / 英語）
    //
    // 実測で判明した Kotoeri ライブ変換の挙動:
    // 合成に「日本語として解析できない列」(check の ck 等) が混ざると、
    // 合成全体または以降を生 ASCII に戻してしまう。
    // → IME に投げる前に自前で日本語/英語の区間に割り、
    //   日本語区間だけを Kotoeri に食わせる必要がある。

    struct Segment {
        let range: Range<Int>
        let isEnglish: Bool
    }

    /// モーラ分解に失敗した位置を英語のアンカーとし、アンカーを含む
    /// 最長の既知英単語まで区間を広げる（"check" の che が チェ に
    /// 食われた後で ck が余る、を防ぐ）。辞書に無ければ失敗クラスタのみ。
    /// 迷ったらローマ字（日本語）に倒す: 分解できる列は辞書を引かない。
    /// そのため name/made 等の「ローマ字としても読める英単語」は日本語になる。
    static func segment(_ text: [String]) -> [Segment] {
        let chars = text.map { Character($0.lowercased()) }
        let n = chars.count
        var result: [Segment] = []
        var jaStart = 0
        var i = 0

        while i < n {
            if let len = moraLength(chars, i) {
                i += len
                continue
            }
            // 分解失敗 → 英語区間を決める
            var engRange: Range<Int>
            if let word = longestDictionaryWord(chars, containing: i, notBefore: jaStart) {
                engRange = word
            } else {
                // 辞書に無い: 連続する分解不能文字のみを英語扱い
                var end = i + 1
                while end < n, chars[end].isLetter, moraLength(chars, end) == nil {
                    end += 1
                }
                engRange = i..<end
            }
            if engRange.lowerBound > jaStart {
                result.append(Segment(range: jaStart..<engRange.lowerBound, isEnglish: false))
            }
            result.append(Segment(range: engRange, isEnglish: true))
            i = engRange.upperBound
            jaStart = engRange.upperBound
        }
        if jaStart < n {
            result.append(Segment(range: jaStart..<n, isEnglish: false))
        }
        // 隣接する英語区間を統合
        var merged: [Segment] = []
        for seg in result {
            if let last = merged.last, last.isEnglish == seg.isEnglish,
               last.range.upperBound == seg.range.lowerBound {
                merged[merged.count - 1] = Segment(range: last.range.lowerBound..<seg.range.upperBound,
                                                   isEnglish: seg.isEnglish)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// 位置 pos のモーラ長を返す。分解できなければ nil
    private static func moraLength(_ s: [Character], _ pos: Int) -> Int? {
        let c = s[pos]
        if c == "-" { return 1 }                     // 長音 ー
        if "aeiou".contains(c) { return 1 }          // 母音単独
        guard c.isLetter else { return nil }
        // 促音: 同じ子音の連続（n と母音を除く）→ っ が1単位
        if pos + 1 < s.count, s[pos] == s[pos + 1], !"aeioun".contains(c) {
            return 1
        }
        // ん の処理
        if c == "n" {
            if pos + 1 >= s.count { return 1 }
            let nc = s[pos + 1]
            if nc == "n" { return 2 }                // nn = ん
            if !"aeiouy".contains(nc) { return 1 }   // 子音前の ん
            // na ni nu ... はテーブルへ
        }
        if pos + 2 < s.count, moraTable3.contains(String(s[pos...pos+2])) { return 3 }
        if pos + 1 < s.count, moraTable2.contains(String(s[pos...pos+1])) { return 2 }
        return nil
    }

    /// 失敗位置 pos を含む最長の辞書語を探す
    private static func longestDictionaryWord(_ chars: [Character], containing pos: Int, notBefore lo: Int) -> Range<Int>? {
        let n = chars.count
        var best: Range<Int>?
        let aMin = max(lo, pos - 11)
        for a in aMin...pos {
            let bMax = min(n, a + 12)
            guard bMax > pos else { continue }
            for b in stride(from: bMax, to: pos, by: -1) {
                guard b - a >= 2 else { continue }
                if let cur = best, (b - a) <= cur.count { continue }
                let w = String(chars[a..<b])
                guard w.allSatisfy({ $0.isLetter }) else { continue }
                if englishWords.contains(w) {
                    best = a..<b
                }
            }
        }
        return best
    }

    // Kotoeri が認識するローマ字→かな パターン
    private static let moraTable3: Set<String> = [
        "sha", "shi", "shu", "she", "sho",
        "chi", "cha", "chu", "che", "cho",
        "tsu", "thi", "tha", "thu", "tho",
        "kya", "kyi", "kyu", "kye", "kyo",
        "nya", "nyi", "nyu", "nye", "nyo",
        "mya", "myi", "myu", "mye", "myo",
        "rya", "ryi", "ryu", "rye", "ryo",
        "hya", "hyi", "hyu", "hye", "hyo",
        "bya", "byi", "byu", "bye", "byo",
        "pya", "pyi", "pyu", "pye", "pyo",
        "gya", "gyi", "gyu", "gye", "gyo",
        "dya", "dyi", "dyu", "dye", "dyo",
        "zya", "zyi", "zyu", "zye", "zyo",
        "sya", "syi", "syu", "sye", "syo",
        "tya", "tyi", "tyu", "tye", "tyo",
        "whi", "whe", "who", "dhi", "dhu",
        "xtu", "ltu", "xya", "xyu", "xyo", "lya", "lyu", "lyo",
    ]

    private static let moraTable2: Set<String> = [
        "ka", "ki", "ku", "ke", "ko",
        "sa", "si", "su", "se", "so",
        "ta", "ti", "tu", "te", "to",
        "na", "ni", "nu", "ne", "no",
        "ha", "hi", "hu", "he", "ho",
        "ma", "mi", "mu", "me", "mo",
        "ya", "yu", "yo",
        "ra", "ri", "ru", "re", "ro",
        "wa", "wi", "we", "wo",
        "ga", "gi", "gu", "ge", "go",
        "za", "zi", "zu", "ze", "zo",
        "da", "di", "du", "de", "do",
        "ba", "bi", "bu", "be", "bo",
        "pa", "pi", "pu", "pe", "po",
        "fa", "fi", "fu", "fe", "fo",
        "ja", "ji", "ju", "je", "jo",
        "xa", "xi", "xu", "xe", "xo",
        "la", "li", "lu", "le", "lo",
        "va", "vi", "vu", "ve", "vo",
    ]

    /// 英語区間の境界決定に使う語彙。
    /// モーラ分解に失敗した位置でしか引かないので、
    /// ローマ字として読める語 (made, name 等) が混ざっていても
    /// 日本語判定を侵食しない（それらは分解に成功し辞書まで来ない）。
    private static let englishWords: Set<String> = [
        // ウェブ / 開発
        "api", "app", "array", "async", "auth", "await", "backend", "bash", "bool",
        "boolean", "branch", "browser", "buffer", "bug", "build", "button", "cache",
        "callback", "check", "checkbox", "class", "cli", "click", "client", "clone",
        "code", "column", "commit", "config", "console", "const", "cookie", "css",
        "csv", "data", "database", "debug", "default", "delete", "deploy", "dev",
        "dict", "diff", "div", "docker", "dom", "email", "endpoint", "enum", "env",
        "error", "event", "export", "false", "fetch", "field", "file", "filter",
        "fix", "flag", "flex", "float", "folder", "font", "form", "frontend", "func",
        "function", "git", "github", "grid", "handler", "hash", "header", "height",
        "host", "hover", "html", "http", "https", "icon", "image", "img", "import",
        "index", "input", "install", "int", "ios", "java", "javascript", "join",
        "jpg", "js", "json", "key", "label", "layout", "lib", "library", "lint",
        "linux", "list", "local", "log", "login", "logout", "loop", "macos", "main",
        "map", "margin", "markdown", "menu", "merge", "method", "mock", "mode",
        "model", "module", "mouse", "node", "npm", "null", "object", "offset",
        "onclick", "option", "output", "padding", "page", "param", "parse",
        "password", "patch", "path", "pdf", "php", "pixel", "png", "port", "post",
        "print", "prod", "promise", "prop", "pull", "push", "python", "query",
        "queue", "react", "readme", "regex", "release", "remote", "render", "repo",
        "request", "reset", "response", "rest", "return", "root", "route", "router",
        "row", "ruby", "run", "rust", "save", "schema", "scope", "screen", "script",
        "scroll", "select", "self", "server", "session", "shell", "shift", "size",
        "slack", "sort", "source", "span", "sql", "src", "ssh", "ssl", "stack",
        "staging", "state", "static", "status", "stdout", "string", "struct",
        "style", "submit", "svg", "swift", "switch", "sync", "tab", "table", "tag",
        "task", "template", "terminal", "test", "text", "theme", "thread", "throw",
        "timeout", "tmp", "todo", "token", "tool", "top", "true", "try", "txt",
        "type", "typescript", "ubuntu", "ui", "undefined", "undo", "unit", "unix",
        "update", "upload", "url", "user", "utf", "util", "ux", "value", "var",
        "version", "video", "view", "void", "vue", "web", "webpack", "width",
        "window", "word", "wrap", "xcode", "xml", "yaml", "zip", "zoom", "zsh",
        // 一般英語（クラスタを含みやすい語を中心に）
        "about", "after", "all", "also", "and", "answer", "any", "ask", "back",
        "because", "been", "before", "best", "better", "between", "big", "both",
        "but", "can", "change", "close", "come", "could", "day", "did", "does",
        "down", "each", "end", "even", "every", "fast", "few", "find", "first",
        "for", "from", "get", "give", "good", "great", "had", "has", "have",
        "help", "her", "here", "him", "his", "how", "into", "its", "just", "keep",
        "know", "last", "left", "less", "let", "like", "line", "link", "long",
        "look", "make", "many", "may", "more", "most", "much", "must", "need",
        "never", "new", "next", "not", "now", "off", "old", "once", "one", "only",
        "open", "other", "our", "out", "over", "own", "part", "people", "place",
        "point", "put", "right", "said", "same", "say", "see", "set", "she",
        "should", "show", "side", "since", "small", "some", "start", "still",
        "stop", "such", "take", "tell", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "thing", "think", "this", "those",
        "three", "through", "time", "today", "together", "too", "turn", "two",
        "under", "until", "upon", "use", "very", "want", "was", "way", "well",
        "went", "were", "what", "when", "where", "which", "while", "who", "why",
        "will", "with", "work", "world", "would", "year", "yes", "you", "your",
    ]

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
