import Cocoa
import Carbon

class KeyMonitor {
    private let rescueThreshold = 1
    var rescueThresholdPublic: Int { rescueThreshold }
    private let capsLockKeyCode: CGKeyCode = 57  // 標準キーボード（flagsChanged）
    private let eisuKeyCode: CGKeyCode = 102      // JIS 英数キー
    private let f18KeyCode: CGKeyCode = 79        // F18（Caps Lock→VIAリマップ）→ スマート救済
    private let backspaceKeyCode: CGKeyCode = 51
    private var buffer: [(keyCode: CGKeyCode, char: String)] = []
    private var isRescuing = false
    private var hyperWasActive = false
    // 自分が注入した合成イベントを識別するタグ ("ITS" in hex)
    private let syntheticUserData: Int64 = 0x49545300
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                   | (1 << CGEventType.keyUp.rawValue)
                                   | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
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
            print("[ITS] FAILED to create event tap")
            Unmanaged<KeyMonitor>.fromOpaque(selfPtr).release()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[ITS] event tap created and enabled ✓")
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
        buffer.removeAll()
        isRescuing = false
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 自分が注入した合成イベントはタグで識別してそのまま通す（バッファリングしない）
        if event.getIntegerValueField(.eventSourceUserData) == syntheticUserData {
            return Unmanaged.passRetained(event)
        }
        guard !isRescuing else { return Unmanaged.passRetained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            let flags = event.flags
            let isHyper = flags.contains(.maskShift)
                       && flags.contains(.maskCommand)
                       && flags.contains(.maskControl)
                       && flags.contains(.maskAlternate)

            if isHyper {
                // 4つ全部押せた状態を記憶
                hyperWasActive = true
            } else if hyperWasActive {
                // 4つ全部押していた→離した瞬間に発火（より確実）
                hyperWasActive = false
                let saved = buffer
                let text = saved.map { $0.char }.joined()
                buffer.removeAll()
                if saved.count >= rescueThreshold && looksLikeRomaji(text) {
                    triggerRescue(saved: saved, toJapanese: false)
                }
            }

            // Caps Lock（US標準キーボード）→ 日本語に打ち直し
            if keyCode == capsLockKeyCode {
                let saved = buffer
                let text = saved.map { $0.char }.joined()
                if saved.count >= rescueThreshold && looksLikeRomaji(text) {
                    triggerRescue(saved: saved)
                    return nil
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // F18（Caps Lock）→ スマート救済（今のIMEと逆方向）
        if keyCode == f18KeyCode {
            let saved = buffer
            let text = saved.map { $0.char }.joined()
            buffer.removeAll()
            if saved.count >= rescueThreshold && looksLikeRomaji(text) {
                let toJapanese = !isCurrentlyJapaneseIME()
                triggerRescue(saved: saved, toJapanese: toJapanese)
            }
            return Unmanaged.passRetained(event)
        }

        // 英数キー → バッファリセットのみ（通常の英語モード切り替えを邪魔しない）
        if keyCode == eisuKeyCode {
            buffer.removeAll()
            return Unmanaged.passRetained(event)
        }

        // Backspace
        if keyCode == backspaceKeyCode {
            if !buffer.isEmpty { buffer.removeLast() }
            return Unmanaged.passRetained(event)
        }

        // Space / Enter / Escape → バッファリセット
        if keyCode == 49 || keyCode == 36 || keyCode == 53 {
            buffer.removeAll()
            return Unmanaged.passRetained(event)
        }

        // 修飾キーコンボ → バッファリセット
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.removeAll()
            return Unmanaged.passRetained(event)
        }

        // 通常文字
        if let chars = unicodeChar(from: event), !chars.isEmpty,
           chars.unicodeScalars.first?.properties.isAlphabetic == true {
            buffer.append((keyCode: keyCode, char: chars))
        } else if keyCode != capsLockKeyCode && keyCode != eisuKeyCode && keyCode != f18KeyCode {
            buffer.removeAll()
        }

        return Unmanaged.passRetained(event)
    }

    private func triggerRescue(saved: [(keyCode: CGKeyCode, char: String)], toJapanese: Bool = true) {
        isRescuing = true
        buffer.removeAll()

        if toJapanese {
            // ── 英語→日本語 ──
            // ZMKマクロ方式: 1文字ずつ30msウェイトで cgSessionEventTap に注入
            // → Kotoeriを通る → 未確定かな（確定前）として入力される
            let romaji = saved.map { $0.char }.joined()

            // ASCII 1文字 = BS 1回で削除
            for _ in saved {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true)
                let up   = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false)
                down?.post(tap: .cgAnnotatedSessionEventTap)
                up?.post(tap: .cgAnnotatedSessionEventTap)
            }
            print("[ITS] E→J: '\(romaji)' \(saved.count) chars deleted, switching IME...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                var done = false
                var obs: Any?

                obs = DistributedNotificationCenter.default().addObserver(
                    forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                    object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self = self, !done else { return }
                    done = true
                    if let o = obs { DistributedNotificationCenter.default().removeObserver(o) }
                    // IME切り替え通知後 200ms 待ってから注入開始
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                        guard let self = self else { return }
                        print("[ITS] E→J: IME switched (isJapanese=\(self.isCurrentlyJapaneseIME())) → slow inject start")
                        self.injectSlowKeys(saved, index: 0)
                    }
                }

                // タイムアウト 800ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, !done else { return }
                    done = true
                    if let o = obs { DistributedNotificationCenter.default().removeObserver(o) }
                    print("[ITS] E→J: timeout → slow inject start")
                    self.injectSlowKeys(saved, index: 0)
                }

                self.switchToJapaneseIME()
                print("[ITS] E→J: switchToJapaneseIME() called")
            }

        } else {
            // ── 日本語→英語 ──
            let romaji = saved.map { $0.char }.joined()
            let kanaBsCount = romajiToMoraCount(romaji)

            for _ in 0..<kanaBsCount {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true)
                let up   = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false)
                down?.post(tap: .cgAnnotatedSessionEventTap)
                up?.post(tap: .cgAnnotatedSessionEventTap)
            }

            // クリップボードにローマ字をセット → Cmd+V でIMEを完全バイパスしてペースト
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(romaji, forType: .string)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.switchToEnglishIME()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self = self else { return }
                let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
                let vUp   = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
                vDown?.flags = .maskCommand
                vUp?.flags   = .maskCommand
                vDown?.post(tap: .cgAnnotatedSessionEventTap)
                vUp?.post(tap: .cgAnnotatedSessionEventTap)
                self.isRescuing = false
            }
        }
    }

    // ── ZMKマクロ方式: 1文字ずつ 30ms 間隔で cgSessionEventTap に注入 ──────────
    // privateState ソース + syntheticUserData タグ → 自タップで再処理しない
    // flags=0 で修飾キーなし → システムショートカット誤発火を防ぐ
    private func injectSlowKeys(_ keys: [(keyCode: CGKeyCode, char: String)], index: Int) {
        guard index < keys.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isRescuing = false
                print("[ITS] E→J: slow inject complete ✓")
            }
            return
        }
        let entry = keys[index]
        let src = CGEventSource(stateID: .privateState)
        src?.userData = syntheticUserData

        let down = CGEvent(keyboardEventSource: src, virtualKey: entry.keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: entry.keyCode, keyDown: false)
        // 修飾キーなし: システムショートカット誤発火を防ぐ
        down?.flags = CGEventFlags(rawValue: 0)
        up?.flags   = CGEventFlags(rawValue: 0)
        // ※ keyboardSetUnicodeString は呼ばない
        //   unicode文字列を事前セットするとKotoeriが「変換済み」と判断してスキップする
        //   キーコードのみを渡してKotoeriに変換させる

        // cgSessionEventTap = Kotoeri処理「前」→ ローマ字がKotoeriを通って未確定かなになる
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        print("[ITS] E→J: [\(entry.char)] keyCode=\(entry.keyCode) posted (\(index+1)/\(keys.count))")

        // ZMK 標準の 30ms ウェイト
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [weak self] in
            self?.injectSlowKeys(keys, index: index + 1)
        }
    }

    // ── Kotoeri composition の表示単位数を数える（= 必要な BS 回数）──────────────
    // 完全なかな列（sha→しゃ、kya→きゃ 等）は 1 単位
    // 未完了のローマ字文字（末尾の f, t 等）は 1 文字ずつ 1 単位
    // 例: "shift" → し(1) + f(1) + t(1) = 3
    //     "sha"   → しゃ(1) = 1
    //     "kannpekidesune" → か+ん+ぺ+き+で+す+ね = 7
    private func romajiToMoraCount(_ romaji: String) -> Int {
        let s = romaji.lowercased()
        var count = 0
        var i = s.startIndex

        while i < s.endIndex {
            let next = s.index(after: i)

            // 促音: 同じ子音が連続（n・母音除外）
            if next < s.endIndex,
               s[i] == s[next],
               !"aeiouy".contains(s[i]),
               s[i] != "n" {
                count += 1  // っ = 1 単位
                i = next
                continue
            }

            // 'n' 処理
            if s[i] == "n" {
                if next == s.endIndex { count += 1; i = next; continue }
                let nc = s[next]
                if nc == "n" { count += 1; i = s.index(after: next); continue }
                if !"aeiouy".contains(nc) { count += 1; i = next; continue }
                // na ni nu ne no nyu 等 → テーブルへ
            }

            let rem = String(s[i...])
            // 3文字テーブル（sha, chi, kya 等）→ 1 単位
            if rem.count >= 3 && moraTable3.contains(String(rem.prefix(3))) {
                count += 1
                i = s.index(i, offsetBy: 3)
                continue
            }
            // 2文字テーブル（ka, si 等）→ 1 単位
            if rem.count >= 2 && moraTable2.contains(String(rem.prefix(2))) {
                count += 1
                i = s.index(i, offsetBy: 2)
                continue
            }
            // 母音単独 → 1 単位
            if "aeiou".contains(s[i]) {
                count += 1
                i = next
                continue
            }
            // 未完了文字（末尾の子音など）→ 1 単位ずつ
            count += 1
            i = next
        }
        return max(count, 1)
    }

    // Kotoeri が認識するローマ字→かな の入力パターン（値不要、キーのみ）
    private let moraTable3: Set<String> = [
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
    ]

    private let moraTable2: Set<String> = [
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
    ]

    private func isCurrentlyJapaneseIME() -> Bool {
        // kTISCategoryKeyboardInputSource でキーボード系のみに絞る（PressAndHold等を除外）
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelected) else { continue }
            let isSelected = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
            guard CFBooleanGetValue(isSelected) else { continue }
            guard let id = inputSourceID(source) else { continue }
            if id.contains("Japanese") || id.contains("Kotoeri") {
                return true
            }
        }
        return false
    }

    private func switchToJapaneseIME() {
        let inputSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        for source in inputSources {
            if let id = inputSourceID(source), id.contains("Hiragana") || id.contains("Japanese") {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private func switchToEnglishIME() {
        let inputSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        for source in inputSources {
            if let id = inputSourceID(source),
               id.contains("ABC") || id == "com.apple.keylayout.US" {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private func inputSourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func unicodeChar(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var units = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &units)
        let s = String(utf16CodeUnits: units, count: length)
        return s.isEmpty ? nil : s
    }

    private func looksLikeRomaji(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        let hasVowel = lower.contains(where: { "aeiou".contains($0) })
        let allAlpha = lower.allSatisfy({ $0.isLetter })
        let noDigits = !lower.contains(where: { $0.isNumber })
        return hasVowel && allAlpha && noDigits
    }
}
