import Cocoa
import Carbon
import os
#if ITS_SELECTION
import ApplicationServices
#endif

/// GUI アプリの print は unified log に乗らないため、追跡は os_log で行う。
/// 読むとき: /usr/bin/log show --predicate 'subsystem == "com.rabadi.ithinkso"' --last 2m
let itsLog = Logger(subsystem: "com.rabadi.ithinkso", category: "keymonitor")

class KeyMonitor {

    // MARK: - 調整点

    /// 何文字以上で救出対象にするか。1 = 「a」→「あ」も救う
    private let rescueThreshold = 1
    /// これを超えたら救済しない。中途半端に一部だけ打ち直すと事故になるため
    private let maxBufferCount = 3000
    /// BS 連打の間隔。0 だと取りこぼすアプリがある
    // 削除は英数モードで行うので IME に飲まれない。12ms でも取りこぼさない
    // （実測: 日本語IMEのまま撃つと 30ms でも不定に3〜5個消えた）
    private let backspaceInterval = 0.012
    /// Kotoeri に流し込む間隔。IME の変換処理を待つ必要がある
    private let injectInterval = 0.030
    /// IME を通さない注入の間隔。変換待ちが不要なので詰められる
    private let injectIntervalASCII = 0.005
    /// 救済が固まったときに強制解除するまでの時間
    /// 救済の見張り時間の下限。実際は文字数ぶん延ばす（rescueBudget 参照）
    private let rescueTimeout = 6.0
    /// かな/英数キー注入から前面アプリの IME が切り替わるまでの待ち時間。
    /// 実測: 0.15s では不達、0.3s で安定。マージン込みで 0.4s
    private let imeSettleDelay = 0.4

    // MARK: - キーコード

    private let eisuKeyCode: CGKeyCode = 102      // JIS 英数キー
    private let kanaKeyCode: CGKeyCode = 104      // JIS かなキー
    private let leftCommandKeyCode: CGKeyCode = 55   // 左⌘
    private let rightCommandKeyCode: CGKeyCode = 54  // 右⌘
    private let leftOptionKeyCode: CGKeyCode = 58    // 左⌥（QMK系で親指キーが⌥+英数の構成がある）
    private let f10KeyCode: CGKeyCode = 109       // F10（Kotoeri: 合成を半角英字に変換）
    private let backspaceKeyCode: CGKeyCode = 51
    private let escapeKeyCode: CGKeyCode = 53
    private let spaceKeyCode: CGKeyCode = 49
    private let returnKeyCode: CGKeyCode = 36

    /// 2度押し判定の窓
    private let doubleTapWindow: TimeInterval = 0.35

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
    private var watchdog: DispatchWorkItem?
    /// 自タップが「自分の注入イベント」として認識した数。タグが機能しているかの確認用
    private var syntheticSeen = 0
    /// 救済の世代。中断すると進み、予約済みの継続を無効化する
    private var rescueGen = 0
    #if ITS_SELECTION
    /// 選択範囲の打ち直しを使うか。メニューでオプトインする（既定 false）
    var selectionRescueEnabled = false
    #endif

    // かな2度押しの状態（J→E）
    private var kanaFirstTapTime: TimeInterval = 0
    private var kanaTapSnapshot: [(keyCode: CGKeyCode, char: String)] = []
    private var kanaTapOverflowed = false
    // 英数2度押しの状態（E→J）
    private var eisuFirstTapTime: TimeInterval = 0
    private var eisuTapSnapshot: [(keyCode: CGKeyCode, char: String)] = []
    private var eisuTapOverflowed = false

    // 英数キーの保留再生。
    // 新トリガー体系では 英数×2 = J→E。1度目を素通しすると未確定合成が
    // 確定してしまい F10 が効かなくなるため、1度目は飲み込んで保留し、
    // 2度目が来なければ後から注入し直す（単発押しの意図を壊さない）。
    // かな/英数のどちらか1つを保留する（同時に2つは持たない。次が来たら先に流す）
    private var pendingHold: (keyCode: CGKeyCode, event: CGEvent)?
    private var holdGen = 0
    private let holdReplayDelay = 0.5   // doubleTapWindow より長く
    private let holdFlushSettle = 0.12  // 保留キーを流してから文字を流すまでの待ち
    // ⌘単押しタップの状態（左⌘=E→J / 右⌘=J→E）
    private var lcmdDownTime: TimeInterval = 0
    private var rcmdDownTime: TimeInterval = 0
    /// ⌘を押している間に他のキーが押されたか（⌘C などの修飾キー使用）
    private var cmdUsedAsModifier = false
    private var lcmdLastTapTime: TimeInterval = 0
    private var rcmdLastTapTime: TimeInterval = 0
    /// 修飾キーを「単押し」とみなす最大押下時間
    private let modifierTapMaxDuration: TimeInterval = 0.3

    /// 自分が注入した合成イベントを識別するタグ ("ITS" in hex)
    private let syntheticUserData: Int64 = 0x49545300
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var rescueThresholdPublic: Int { rescueThreshold }

    // MARK: - 開始 / 停止

    func start() {
        guard eventTap == nil else { return }

        // マウス押下も見る。クリックでキャレットが動くと、打鍵バッファと
        // 画面上の文字列の対応が切れる。それに気づかず救済すると、打っていない
        // 場所の文字を消してしまう
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                   | (1 << CGEventType.keyUp.rawValue)
                                   | (1 << CGEventType.flagsChanged.rawValue)
                                   | (1 << CGEventType.leftMouseDown.rawValue)
                                   | (1 << CGEventType.rightMouseDown.rawValue)
                                   | (1 << CGEventType.otherMouseDown.rawValue)

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
        observeAppSwitch()
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

    // トリガー体系: かな×2 (350ms以内) の一本のみ。方向は自動判定。
    //   1度目は素通し（通常の切替として働く）、2度目を飲んで救済。
    //   英数 / Caps Lock / F18 / Hyper はすべて通常機能のまま
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // OS がタップを止めたら必ず再有効化する。
        // コールバックが遅れたとき（.tapDisabledByTimeout）やスリープ復帰などで
        // macOS はタップを一方的に無効化する。ここで戻さないとアプリは
        // 生きたまま無反応になり、再起動するまで気づけない。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                itsLog.error("event tap が OS に無効化されたため再有効化した (type=\(type.rawValue))")
            }
            return Unmanaged.passRetained(event)
        }

        // 自分が注入した合成イベントはタグで識別してそのまま通す
        if event.getIntegerValueField(.eventSourceUserData) == syntheticUserData {
            syntheticSeen += 1
            return Unmanaged.passRetained(event)
        }

        // マウス押下: キャレットが移動しうるのでバッファを無効化する。
        // 救済中ならそこで中断する。注入先が変わった状態で撃ち続けるほうが危険
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // メニューバーのクリックはキャレットを動かさない。ここで捨てると
            // メニューの「直前の入力を打ち直す」が常に空振りする
            if !isClickInMenuBar(event) {
                if isRescuing {
                    itsLog.error("救済中にクリック → 中断")
                    abortRescue()
                }
                resetBuffer()
            }
            return Unmanaged.passRetained(event)
        }

        // 救済中に打たれた実キーは捨てる。
        // 素通しすると、注入中のキー列に実キーが割り込んで文字列が壊れる。
        guard !isRescuing else { return nil }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // ── ⌘の2度タップ（US 配列でも押せる主トリガー） ──
        //   右⌘×2 → E→J（日本語にしたい） / 左⌘×2 → J→E（英語にしたい）
        // JIS の物理配置（左=英数、右=かな）と意味を揃えてある。
        // MacBook では Karabiner で 左⌘タップ=英数 / 右⌘タップ=かな にして
        // いても、raw の⌘イベント自体は届くのでそのまま動く。
        // Karabiner が付加した英数/かなイベントで下の英数/かなトリガーも
        // 発火しうるが、先に始まった救済の isRescuing ガードが後続を飲む。
        if type == .flagsChanged {
            let now = ProcessInfo.processInfo.systemUptime
            if keyCode == leftCommandKeyCode || keyCode == rightCommandKeyCode
               || keyCode == leftOptionKeyCode {
                let isLeft = (keyCode != rightCommandKeyCode)
                let mask: CGEventFlags = (keyCode == leftOptionKeyCode) ? .maskAlternate : .maskCommand
                if event.flags.contains(mask) {
                    if isLeft { lcmdDownTime = now } else { rcmdDownTime = now }
                    cmdUsedAsModifier = false
                } else {
                    let downTime = isLeft ? lcmdDownTime : rcmdDownTime
                    if isLeft { lcmdDownTime = 0 } else { rcmdDownTime = 0 }
                    let wasTap = downTime > 0 && !cmdUsedAsModifier
                                 && (now - downTime) < modifierTapMaxDuration
                    if wasTap {
                        let last = isLeft ? lcmdLastTapTime : rcmdLastTapTime
                        if now - last < doubleTapWindow {
                            if isLeft {
                                lcmdLastTapTime = 0
                                fireJtoE(reason: keyCode == leftOptionKeyCode ? "左⌥×2" : "左⌘×2")
                            } else {
                                rcmdLastTapTime = 0
                                fireEtoJ(reason: "右⌘×2")
                            }
                        } else {
                            if isLeft { lcmdLastTapTime = now } else { rcmdLastTapTime = now }
                        }
                    }
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // ⌘を押している最中のキー押下 = ⌘C などの修飾キー使用。タップ扱いにしない
        if lcmdDownTime > 0 || rcmdDownTime > 0 { cmdUsedAsModifier = true }

        // かな/英数を保留したまま普通のキーが来た → 保留分を先に注入してから
        // このキーを注入し直す（順序を保つ）。修飾キー付きは触らず、
        // 保留分はタイマーに任せる。かな・英数自身は下の各ブランチで扱う
        if pendingHold != nil, keyCode != eisuKeyCode, keyCode != kanaKeyCode,
           !event.flags.contains(.maskCommand),
           !event.flags.contains(.maskControl),
           !event.flags.contains(.maskAlternate) {
            flushPendingKey()
            // 打たれた文字はバッファにも反映しておく（注入コピーは
            // synthetic タグ付きでこのタップを素通りするため）
            if let chars = unicodeChar(from: event), isBufferable(chars),
               buffer.count < maxBufferCount {
                buffer.append((keyCode: keyCode, char: chars))
            }
            // 英数の直後に文字を撃つと入力ソースの切替が間に合わず、
            // 日本語モードのまま入ってしまう（あbc になる）。間を置く
            if let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
                DispatchQueue.main.asyncAfter(deadline: .now() + holdFlushSettle) {
                    copy.post(tap: .cgAnnotatedSessionEventTap)
                }
            }
            return nil
        }

        // ── トリガー体系 ──────────────────────────────────
        //
        // 方向はジェスチャで明示する。入力ソースの自動判定はしない
        // （バックグラウンドから前面アプリの入力ソースを知る手段が無く、
        //   実測で毎回誤判定したため）。
        //
        //   かな×2 → E→J: 「日本語にしたい」。1度目のかな素通しは
        //     日本語への切替になるだけで救済処理と衝突しない
        //   英数×2 → J→E: 「英語にしたい」。ただし1度目の英数を素通しすると
        //     未確定合成がその場で確定し F10 が死ぬため、1度目は保留する
        //     （2度目が来なければ後から注入して単発押しとして成立させる）
        //
        // MacBook では Karabiner で 左⌘タップ=英数 / 右⌘タップ=かな に
        // している想定。⌘の2度タップがそのままトリガーになる。

        // 英数×2 → J→E（英語にしたい）
        if keyCode == eisuKeyCode {
            let now = ProcessInfo.processInfo.systemUptime
            if now - eisuFirstTapTime < doubleTapWindow {
                eisuFirstTapTime = 0
                let snapshot = eisuTapSnapshot
                eisuTapSnapshot = []
                fireJtoE(reason: "英数×2", snapshot: snapshot)
                return nil
            }
            // 窓の外の連打や、かなを保留中に英数が来た場合: 前の保留分を先に流す
            flushPendingKey()
            eisuFirstTapTime = now
            eisuTapSnapshot = buffer
            eisuTapOverflowed = bufferOverflowed
            let hadInput = !buffer.isEmpty
            resetBuffer()
            // 直前に何も打っていなければ救済の対象が無い。保留せず素通しして
            // 普通のモード切替として即座に効かせる（0.5秒待たせない）
            guard hadInput else { return Unmanaged.passRetained(event) }
            // 1度目: 素通しせず保留（未確定合成を確定させないため）
            holdKey(event, keyCode: eisuKeyCode)
            return nil
        }

        // かな×2 → E→J（日本語にしたい）
        if keyCode == kanaKeyCode {
            let now = ProcessInfo.processInfo.systemUptime
            if now - kanaFirstTapTime < doubleTapWindow {
                kanaFirstTapTime = 0
                let snapshot = kanaTapSnapshot
                kanaTapSnapshot = []
                fireEtoJ(reason: "かな×2", snapshot: snapshot, overflowed: kanaTapOverflowed)
                return nil
            }
            // 窓の外の連打や、英数を保留中にかなが来た場合: 前の保留分を先に流す
            flushPendingKey()
            kanaFirstTapTime = now
            kanaTapSnapshot = buffer
            kanaTapOverflowed = bufferOverflowed
            let hadInput = !buffer.isEmpty
            resetBuffer()
            #if ITS_SELECTION
            // バッファが空 = 選択を対象にしうる場面。ここでかなを素通しすると、
            // ことえりが「選択中の文字列を再変換」してしまい（実測）、アプリが
            // 読む前に選択を奪われる。選択対応をオンにしている人に限り保留する
            if !hadInput && selectionRescueEnabled {
                holdKey(event, keyCode: kanaKeyCode)
                return nil
            }
            #endif
            // 1度目: 素通し。打鍵直後なら日本語モードへの切替になるだけで、
            // 後続の救済（削除→打ち直し）とは衝突しない
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
        } else {
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

    // MARK: - かな/英数キーの保留再生

    private func holdKey(_ event: CGEvent, keyCode: CGKeyCode) {
        flushPendingKey()   // 別のキーを保留中なら先に流し、常に1つだけ持つ
        guard let copy = event.copy() else { return }
        pendingHold = (keyCode: keyCode, event: copy)
        holdGen += 1
        let gen = holdGen
        DispatchQueue.main.asyncAfter(deadline: .now() + holdReplayDelay) { [weak self] in
            guard let self, self.holdGen == gen else { return }
            self.flushPendingKey()
        }
    }

    /// 保留中のキーを今すぐ注入する（単発押しの成立）
    private func flushPendingKey() {
        guard let held = pendingHold else { return }
        pendingHold = nil
        holdGen += 1
        held.event.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
        held.event.post(tap: .cgSessionEventTap)
        if let src = CGEventSource(stateID: .hidSystemState),
           let up = CGEvent(keyboardEventSource: src, virtualKey: held.keyCode, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// 保留中のキーを捨てる（2度押しが成立して救済が始まったとき）。
    /// 破棄しないと、救済の最中や直後に synthetic タグ付きのキーが
    /// タイマーから注入され、モードを壊したり選択を再変換したりする
    private func discardPendingKey() {
        pendingHold = nil
        holdGen += 1
    }

    // MARK: - 救済

    /// 注入にかかる時間の見積り。固定6秒だと120文字あたりで注入の途中に
    /// watchdog が落ち、isRescuing が下りて残りが実キー扱いになり文字列が壊れる。
    /// 切替2回 + 削除 + 注入 に余裕を足して見積もる
    private func rescueBudget(forCharacters n: Int) -> TimeInterval {
        let switching = imeSettleDelay * 2 + 0.5
        let deleting  = Double(n) * backspaceInterval
        let injecting = Double(n) * max(injectInterval, injectIntervalASCII)
        return max(rescueTimeout, switching + deleting + injecting + 2.0)
    }

    private func beginRescue(budget: TimeInterval? = nil) {
        isRescuing = true
        rescueGen += 1
        syntheticSeen = 0
        watchdog?.cancel()
        // 非同期チェーンが途中で切れると isRescuing が true のまま固まり、
        // 全キー入力が捨てられ続けてアプリが無言で死ぬ。必ず強制解除する。
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRescuing else { return }
            itsLog.error("watchdog 発火 → 救済が固まったので強制解除")
            self.endRescue()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (budget ?? rescueTimeout), execute: work)
    }

    /// 進行中の救済を打ち切る。世代を進めるので、予約済みの継続は
    /// aliveRescue() で弾かれ、以後は何も注入しない
    private func abortRescue() {
        rescueGen += 1
        endRescue()
    }

    /// クリック位置がメニューバーの帯の中か。画面座標は左上原点で来る
    private func isClickInMenuBar(_ event: CGEvent) -> Bool {
        let p = event.location
        guard let screen = NSScreen.screens.first(where: { s in
            let f = s.frame
            let flippedY = (NSScreen.screens.first?.frame.maxY ?? f.maxY) - p.y
            return f.minX <= p.x && p.x <= f.maxX && f.minY <= flippedY && flippedY <= f.maxY
        }) ?? NSScreen.main else { return false }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return p.y <= max(barHeight, 24)
    }

    /// 前面アプリの切り替えを監視してバッファを捨てる。
    /// 別アプリに移ってから救済すると、移動先の文字を消してしまう
    private func observeAppSwitch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                // 自分がアクティブになっただけ（メニューを開いた）なら、
                // キャレットは元の場所のままなのでバッファを保つ
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier == getpid() { return }
                if self.isRescuing {
                    itsLog.error("救済中にアプリ切替 → 中断")
                    self.abortRescue()
                }
                self.resetBuffer()
        }
    }

    /// この世代の救済がまだ生きているか。非同期の継続点で必ず確認する
    private func aliveRescue(_ gen: Int) -> Bool {
        return isRescuing && rescueGen == gen
    }

    private func endRescue() {
        if isRescuing {
            itsLog.error("救済終了 自タップが認識した合成イベント数=\(self.syntheticSeen)")
        }
        isRescuing = false
        watchdog?.cancel()
        watchdog = nil
    }

    /// スナップショットが救済に値するか検証する
    private func validateRescuable(_ saved: [(keyCode: CGKeyCode, char: String)],
                                   overflowed: Bool) -> [(keyCode: CGKeyCode, char: String)]? {
        if overflowed {
            itsLog.error("バッファ上限超過 (>\(self.maxBufferCount)) → 救済しない")
            return nil
        }
        guard saved.count >= rescueThreshold else { return nil }
        let text = saved.map { $0.char }.joined()
        guard looksLikeRomaji(text) else {
            itsLog.error("ローマ字と判定されず救済しない (\(text.count)文字)")
            return nil
        }
        return saved
    }

    /// E→J を発火する。snapshot 省略時は現在のバッファを使う（⌘/⌥タップ経由）。
    ///
    /// ⌥/⌘タップに英数が載っている環境では、1度目のタップに付随する英数が
    /// 先にバッファを英数側スナップショットへ退避してしまう（イベント順:
    /// ⌥↓↑→英数↓→⌥↓↑）。そのため発火時にバッファが空なら、直近の
    /// 英数スナップショットから拾う。
    private func fireEtoJ(reason: String,
                          snapshot: [(keyCode: CGKeyCode, char: String)]? = nil,
                          overflowed: Bool? = nil) {
        discardPendingKey()
        var saved = snapshot ?? buffer
        var over = overflowed ?? bufferOverflowed
        if snapshot == nil {
            // ⌘タップにかなが載っている環境では、⌘1度目に付随するかなが
            // 先にバッファを退避してしまう。その退避分から回収する
            let now = ProcessInfo.processInfo.systemUptime
            if saved.isEmpty, !kanaTapSnapshot.isEmpty, now - kanaFirstTapTime < 1.0 {
                saved = kanaTapSnapshot
                over = kanaTapOverflowed
                kanaTapSnapshot = []
                kanaFirstTapTime = 0
            }
            resetBuffer()
        }
        itsLog.error("\(reason, privacy: .public) 検出 (buffer=\(saved.count)文字) → E→J")
        if let ok = validateRescuable(saved, overflowed: over) {
            triggerRescueToJapanese(ok, skipSwitch: false)
        } else if saved.isEmpty {
            // 打鍵の記憶が無い（時間が経った／クリックした／アプリを移った）
            // ときだけ、選択範囲を対象にする。バッファ優先・選択はフォールバック
            trySelectionRescue(reason: reason)
        }
    }

    /// J→E を発火する（F10 方式）。buffer は「最近打鍵があったか」の確認にだけ使う。
    /// ⌘タップにかなが載っている環境向けに、E→J と同じスナップショット救済を行う
    private func fireJtoE(reason: String,
                          snapshot: [(keyCode: CGKeyCode, char: String)]? = nil) {
        discardPendingKey()
        var saved = snapshot ?? buffer
        if snapshot == nil {
            // ⌘タップに英数が載っている環境では、⌘1度目に付随する英数が
            // 先にバッファを退避してしまう。その退避分から回収する
            let now = ProcessInfo.processInfo.systemUptime
            if saved.isEmpty, !eisuTapSnapshot.isEmpty, now - eisuFirstTapTime < 1.0 {
                saved = eisuTapSnapshot
                eisuTapSnapshot = []
                eisuFirstTapTime = 0
            }
            resetBuffer()
        }
        if saved.isEmpty {
            itsLog.error("\(reason, privacy: .public) 検出 (buffer空) → 救済対象なし")
        } else {
            itsLog.error("\(reason, privacy: .public) 検出 (buffer=\(saved.count)文字) → J→E (F10)")
            rescueToEnglishViaF10()
        }
    }

    /// メニューから起動する E→J（キーボードにトリガーキーが無い環境向け。
    /// App Review の審査員は US 配列で英数/かなキーが無いため、これが再現手段になる）。
    /// メニューを閉じてフォーカスが戻るのを待ってから実行する
    func rescueNowToJapanese() {
        let snapshot = buffer
        let overflowed = bufferOverflowed
        resetBuffer()
        itsLog.error("メニューから実行 (buffer=\(snapshot.count)文字) → E→J")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if let saved = self.validateRescuable(snapshot, overflowed: overflowed) {
                self.triggerRescueToJapanese(saved, skipSwitch: false)
            } else if snapshot.isEmpty {
                self.trySelectionRescue(reason: "メニュー")
            }
        }
    }

    // MARK: - 選択範囲の打ち直し（オプトイン・Developer ID 版のみ）
    //
    // 打鍵バッファが空のときに限り、前面アプリで選択中の文字列を対象にする。
    // 読むのはアクセシビリティ API、書くのは既存の打鍵注入。AX で直接置換すると
    // IME を通らず変換されないので、AX は読み取りにしか使わない。
    private func trySelectionRescue(reason: String) {
        #if ITS_SELECTION
        guard selectionRescueEnabled else { return }
        guard SelectionReader.isTrusted else {
            itsLog.error("選択救済: アクセシビリティ未許可のため実行しない")
            return
        }
        guard !isRescuing else { return }
        discardPendingKey()
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // AX の往復中にクリックやアプリ切替が起きても aliveRescue で弾けるよう、
        // 読む前に救済を立てておく。棄却する経路では必ず endRescue すること
        beginRescue(budget: 3.0)
        let gen = rescueGen
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hit = SelectionReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.aliveRescue(gen) else { return }
                guard let hit else {
                    self.endRescue()
                    itsLog.error("\(reason, privacy: .public): 選択なし → 救済対象なし")
                    return
                }
                guard hit.pid == targetPid,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else {
                    self.endRescue()
                    itsLog.error("選択救済: 前面アプリが変わったため中止")
                    return
                }
                guard let accepted = Self.selectionKeys(hit.text) else {
                    self.endRescue()
                    itsLog.error("選択救済: 受理せず (\(hit.text.count)文字)")
                    return
                }
                itsLog.error("\(reason, privacy: .public) 検出 (選択=\(accepted.keys.count)文字) → E→J")
                // 選択があれば BS 1回で全部消える（実測）。文字数ぶん撃たない
                self.triggerRescueToJapanese(accepted.keys, skipSwitch: false,
                                             deleteCount: 1, segments: accepted.segments)
            }
        }
        #endif
    }

    static let maxSelectionCount = 3000

    /// 選択テキストを受理するか。
    /// 打鍵バッファ用の segment() は1編集修復と曖昧辞書で綴りを書き換える
    /// （market→make、monitor→monito など。実測で英単語49語中22語が化けた）。
    /// 打ちたてのローマ字が相手なら正しい振る舞いだが、選択テキストは英単語
    /// そのものかもしれない。一切の書き換えが起きなかった場合だけ通す
    static func selectionKeys(_ text: String)
        -> (keys: [(keyCode: CGKeyCode, char: String)], segments: [Segment])? {
        let cs = Array(text)
        guard cs.count >= 2, cs.count <= maxSelectionCount else { return nil }
        // 小文字と長音の '-' だけ。大文字・数字・記号・空白・日本語は対象外
        guard cs.allSatisfy({ ($0 >= "a" && $0 <= "z") || $0 == "-" }) else { return nil }
        let segs = segment(cs.map { String($0) })
        guard segs.allSatisfy({ !$0.corrected }) else { return nil }          // 修復が走った
        guard segs.map({ $0.text }).joined() == text else { return nil }       // 文字が増減した
        for seg in segs where seg.isEnglish {
            guard englishWords.contains(seg.text) else { return nil }          // 未知クラスタ扱いされた
        }
        let keys = cs.compactMap { c -> (keyCode: CGKeyCode, char: String)? in
            guard let kc = asciiKeyMap[c] else { return nil }
            return (keyCode: kc, char: String(c))
        }
        guard keys.count == cs.count else { return nil }
        return (keys, segs)
    }

    private func triggerRescueToJapanese(_ saved: [(keyCode: CGKeyCode, char: String)],
                                         skipSwitch: Bool = false,
                                         deleteCount: Int? = nil,
                                         segments: [Segment]? = nil) {
        beginRescue(budget: rescueBudget(forCharacters: saved.count))
        itsLog.error("救済開始 E→J \(saved.count)文字")
        rescueToJapanese(saved, skipSwitch: skipSwitch, deleteCount: deleteCount, segments: segments)
    }

    // ── 日本語 → 英語（F10 方式） ──────────────────────────────────
    // Kotoeri は未確定合成中に F10 を押すと「打った生のローマ字」に変換する。
    // これを使えば、ライブ変換で表示が何文字になっていようと
    // 削除数の計算なしで確実に英語へ戻せる。
    //   F10（英字に変換）→ Return（確定）→ 英数（以降の入力を英語に）
    // 前提: 未確定合成が開いていること。英数1度目を保留しているのはこのため
    // （英数を素通しすると合成が確定されて F10 が効かなくなる）。
    private func rescueToEnglishViaF10() {
        beginRescue()
        itsLog.error("救済開始 J→E (F10方式)")
        postSyntheticKey(f10KeyCode)
        // 実運用の合成は履歴が長く F10 の再表示に時間がかかることがある。
        // Return が早すぎると変換途中で確定して部分英字化する
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.postSyntheticKey(self.returnKeyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.postSyntheticKey(self.eisuKeyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.endRescue()
                }
            }
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
    /// skipSwitch: 呼び出し側で既に英数モードにしてある場合に true。
    /// 削除は英数モードで行い、そのあと日本語へ切り替えて打ち直す。
    /// deleteCount: 削除する回数。省略時は文字数ぶん。選択範囲が相手なら 1 で足りる
    /// segments:    区間分割の結果を呼び出し側が持っているときに渡す（再計算しない）
    private func rescueToJapanese(_ saved: [(keyCode: CGKeyCode, char: String)],
                                  skipSwitch: Bool = false,
                                  deleteCount: Int? = nil,
                                  segments: [Segment]? = nil) {
        let segs = segments ?? Self.segment(saved.map { $0.char })
        // 区間の中身はユーザーの文章そのものなのでログに残さない。
        // 構成（日本語/英語の並びと文字数）だけを出す
        let shape = segs.map { ($0.isEnglish ? "EN" : "JA") + "\($0.text.count)" }.joined(separator: "+")
        itsLog.error("区間分割: \(shape, privacy: .public) skipSwitch=\(skipSwitch)")

        // 削除は必ず英数モードで行う。
        // 日本語IMEが有効なまま BS を撃つと、ことえりが不定個数を飲む
        // （実測: 12回撃って3〜5回届かない。間隔を12ms→30msにしても再現）。
        // 英数モードなら BS は IME を通らず直接テキストに届く。
        //   英数へ切替 → 全削除 → かなへ切替 → 打ち直し
        // skipSwitch は「呼び出し側で既に英数にした」という意味で使う。
        let toEisu: (@escaping () -> Void) -> Void = { [weak self] then in
            guard let self else { return }
            if skipSwitch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: then)
            } else {
                self.switchIME(toJapanese: false, then: then)
            }
        }
        toEisu { [weak self] in
            guard let self = self else { return }
            self.postBackspaces(deleteCount ?? saved.count) {
                // 消し終えてから日本語へ。ここで初めて IME が要る
                self.switchIME(toJapanese: true) {
                    self.injectSegments(saved, segs, 0)
                }
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
        // 修復で内容が元のバッファと変わりうるので、区間のテキストから
        // keyCode を引き直す（a-z と '-' はすべて asciiKeyMap にある）
        let keys: [(keyCode: CGKeyCode, char: String)] = seg.text.compactMap { ch in
            guard let kc = Self.asciiKeyMap[Character(ch.lowercased())] else { return nil }
            return (keyCode: kc, char: String(ch))
        }
        let interval = seg.isEnglish ? injectIntervalASCII : injectInterval
        let gen = rescueGen
        injectKeys(keys, index: 0, interval: interval, asLiteral: seg.isEnglish) { [weak self] in
            guard let self = self, self.aliveRescue(gen) else { return }
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

    #if ITS_DEVTOOLS
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

    /// J→E 救済をテスト駆動する。ITS_JE でバリアント切替:
    ///   plain = F10 のみ / esc = Esc で読みに戻してから F10 / f10x3 = F10 を3連打
    func testRescueToEnglish() {
        let variant = ProcessInfo.processInfo.environment["ITS_JE"] ?? "plain"
        beginRescue()
        itsLog.error("J→E テスト variant=\(variant, privacy: .public)")
        let f10Chain: () -> Void = { [weak self] in
            guard let self else { return }
            self.postSyntheticKey(self.f10KeyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.postSyntheticKey(self.returnKeyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.postSyntheticKey(self.eisuKeyCode)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.endRescue() }
                }
            }
        }
        switch variant {
        case "esc":
            postSyntheticKey(escapeKeyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: f10Chain)
        case "f10x3":
            postSyntheticKey(f10KeyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.postSyntheticKey(self!.f10KeyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: f10Chain)
            }
        default:
            f10Chain()
        }
    }
    #endif

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
        let gen = rescueGen
        postSyntheticKey(backspaceKeyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + backspaceInterval) { [weak self] in
            // 中断されていたら残りの BS は撃たない。撃つと移動先の文字が消える
            guard let self, self.aliveRescue(gen) else { return }
            self.postBackspaces(count - 1, done: done)
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
            itsLog.error("注入開始 \(keys.count)文字 literal=\(asLiteral) 現IME=\(self.currentSourceID(), privacy: .public) 自動付与ユニコード=\(carriedBefore == "(なし)" ? "なし" : "あり", privacy: .public) → 消去後=\(carriedAfter == "(なし)" ? "なし" : "あり", privacy: .public)")
        }

        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)

        let gen = rescueGen
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.aliveRescue(gen) else { return }
            self.injectKeys(keys, index: index + 1, interval: interval, asLiteral: asLiteral, done: done)
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
        let gen = rescueGen
        DispatchQueue.main.asyncAfter(deadline: .now() + imeSettleDelay) { [weak self] in
            guard let self, self.aliveRescue(gen) else { return }
            then()
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

    // MARK: - 区間分割（日本語 / 英語）
    //
    // 実測で判明した Kotoeri ライブ変換の挙動:
    // 合成に「日本語として解析できない列」(check の ck 等) が混ざると、
    // 合成全体または以降を生 ASCII に戻してしまう。
    // → IME に投げる前に自前で日本語/英語の区間に割り、
    //   日本語区間だけを Kotoeri に食わせる必要がある。

    /// 分割結果。text は修復適用後の内容（元のバッファと異なりうる）
    struct Segment {
        let text: String
        let isEnglish: Bool
        let corrected: Bool
    }

    /// 区間分割 + タイポ修復。
    ///
    /// モーラ分解に失敗した位置ごとに、優先順で:
    ///  1. 辞書の完全一致語（check, div 等）→ 英語区間
    ///  2. 辞書の曖昧一致語（Damerau-Levenshtein 距離1、語長4以上）
    ///     → 修正した語で英語区間（checj → check）
    ///  3. ローマ字の1編集修復（転置 > 削除 > 隣接キー置換）
    ///     → 修復して日本語として再解釈（tuski → tsuki → つき）
    ///  4. どれも成立しない → 失敗クラスタをそのまま英語区間
    ///
    /// 迷ったらローマ字原則は維持: 分解できる列には一切手を付けない。
    /// 修復は1回の救済で最大3箇所（それ以上は打ち直しでなくゴミの可能性が高い）
    static func segment(_ text: [String]) -> [Segment] {
        var chars = text.map { Character($0.lowercased()) }
        var result: [Segment] = []
        var jaStart = 0
        var i = 0
        var repairsLeft = 3

        while i < chars.count {
            if let len = moraLength(chars, i) {
                i += len
                continue
            }
            // 1) 辞書の完全一致（check, div 等の正しく打てた英単語）
            if let (range, word) = dictionaryAnchor(chars, containing: i, notBefore: jaStart, fuzzy: false) {
                if range.lowerBound > jaStart {
                    result.append(Segment(text: String(chars[jaStart..<range.lowerBound]),
                                          isEnglish: false, corrected: false))
                }
                result.append(Segment(text: word, isEnglish: true, corrected: false))
                i = range.upperBound
                jaStart = i
                continue
            }
            // 2) ローマ字修復（tuski → tsuki）。
            //    曖昧辞書より先に試す: 日本語として1編集で直るなら日本語とみなす
            //    （tuski が tusk→task に食われる誤修正の防止）。
            //    修復後も分解できない列（checj 等）はここを素通りして 3) に届く
            if repairsLeft > 0, let (fixed, _) = repaired(chars, failAt: i, from: jaStart) {
                repairsLeft -= 1
                itsLog.error("タイポ修復あり")
                chars = fixed
                i = jaStart   // 修復で前のモーラ境界が変わりうるので走査し直す
                continue
            }
            // 3) 辞書の曖昧一致（checj → check）
            if let (range, word) = dictionaryAnchor(chars, containing: i, notBefore: jaStart, fuzzy: true) {
                if range.lowerBound > jaStart {
                    result.append(Segment(text: String(chars[jaStart..<range.lowerBound]),
                                          isEnglish: false, corrected: false))
                }
                let original = String(chars[range])
                result.append(Segment(text: word, isEnglish: true, corrected: word != original))
                i = range.upperBound
                jaStart = i
                continue
            }
            // 4) 未知の英語クラスタ
            var clusterEnd = i + 1
            while clusterEnd < chars.count, chars[clusterEnd].isLetter,
                  moraLength(chars, clusterEnd) == nil {
                clusterEnd += 1
            }
            if i > jaStart {
                result.append(Segment(text: String(chars[jaStart..<i]), isEnglish: false, corrected: false))
            }
            result.append(Segment(text: String(chars[i..<clusterEnd]), isEnglish: true, corrected: false))
            i = clusterEnd
            jaStart = clusterEnd
        }
        if jaStart < chars.count {
            result.append(Segment(text: String(chars[jaStart...]), isEnglish: false, corrected: false))
        }
        // 隣接する同種区間を統合
        var merged: [Segment] = []
        for seg in result {
            if let last = merged.last, last.isEnglish == seg.isEnglish {
                merged[merged.count - 1] = Segment(text: last.text + seg.text,
                                                   isEnglish: seg.isEnglish,
                                                   corrected: last.corrected || seg.corrected)
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

    /// 失敗位置を含む辞書語を探す。
    /// fuzzy=false: 完全一致（最長・語長2以上）
    /// fuzzy=true:  Damerau-Levenshtein 距離1（最長・語長4以上）。
    ///              同長の別候補が競合したら誤修正を避けて適用しない
    private static func dictionaryAnchor(_ chars: [Character], containing pos: Int,
                                         notBefore lo: Int, fuzzy: Bool) -> (Range<Int>, String)? {
        let n = chars.count
        let aMin = max(lo, pos - 11)

        if !fuzzy {
            var exact: (Range<Int>, String)?
            for a in aMin...pos {
                let bMax = min(n, a + 12)
                guard bMax > pos else { continue }
                for b in stride(from: bMax, to: pos, by: -1) {
                    guard b - a >= 2 else { continue }
                    if let cur = exact, (b - a) <= cur.0.count { continue }
                    let w = String(chars[a..<b])
                    guard w.allSatisfy({ $0.isLetter }) else { continue }
                    if englishWords.contains(w) { exact = (a..<b, w) }
                }
            }
            return exact
        }

        var best: (Range<Int>, String)?
        var bestLen = 0
        var ambiguous = false
        for a in aMin...pos {
            let bMax = min(n, a + 12)
            guard bMax > pos else { continue }
            for b in stride(from: bMax, to: pos, by: -1) {
                guard b - a >= 4 else { continue }
                let sub = String(chars[a..<b])
                guard sub.allSatisfy({ $0.isLetter }) else { continue }
                for word in englishWords where abs(word.count - sub.count) <= 1 && word.count >= 4 {
                    guard withinOneEdit(sub, word) else { continue }
                    if word.count > bestLen {
                        best = (a..<b, word); bestLen = word.count; ambiguous = false
                    } else if word.count == bestLen, best?.1 != word {
                        ambiguous = true
                    }
                }
            }
        }
        if ambiguous { return nil }
        return best
    }

    /// Damerau-Levenshtein 距離がちょうど1か（置換 / 隣接転置 / 挿入 / 削除）
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        let x = Array(a), y = Array(b)
        if x.count == y.count {
            var diffs: [Int] = []
            for k in 0..<x.count where x[k] != y[k] {
                diffs.append(k)
                if diffs.count > 2 { return false }
            }
            if diffs.count == 1 { return true }
            if diffs.count == 2, diffs[1] == diffs[0] + 1,
               x[diffs[0]] == y[diffs[1]], x[diffs[1]] == y[diffs[0]] { return true }
            return false
        }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        guard long.count - short.count == 1 else { return false }
        var si = 0, li = 0, skipped = false
        while si < short.count && li < long.count {
            if short[si] == long[li] { si += 1; li += 1 }
            else if !skipped { skipped = true; li += 1 }
            else { return false }
        }
        return true
    }

    /// ローマ字の1編集修復。失敗位置 i の周辺に 転置 > 削除 > 隣接キー置換 を
    /// 優先順で試し、jaStart から i+5 文字目あたりまで分解が通る修復を採用する
    private static func repaired(_ chars: [Character], failAt i: Int,
                                 from start: Int) -> ([Character], String)? {
        func localOK(_ cs: [Character]) -> Bool {
            var q = start
            let goal = min(cs.count, i + 5)
            while q < cs.count {
                if q >= goal { return true }
                guard let l = moraLength(cs, q) else { return false }
                q += l
            }
            return true
        }
        // 転置（tuski → tsuki）
        for j in [i - 1, i] where j >= start && j + 1 < chars.count && chars[j] != chars[j + 1] {
            var c = chars
            c.swapAt(j, j + 1)
            if localOK(c) {
                return (c, "転置 '\(chars[j])\(chars[j+1])'→'\(c[j])\(c[j+1])'")
            }
        }
        // 削除（余計な子音の混入）
        if i < chars.count {
            var c = chars
            let removed = c.remove(at: i)
            if localOK(c) { return (c, "削除 '\(removed)'") }
        }
        // 隣接キー置換（QWERTY で隣のキーを押した）
        if i < chars.count, let neighbors = qwertyNeighbors[chars[i]] {
            for r in neighbors {
                var c = chars
                c[i] = r
                if localOK(c) { return (c, "置換 '\(chars[i])'→'\(r)'") }
            }
        }
        return nil
    }

    /// QWERTY の物理隣接キー（タイポ置換の探索範囲）
    private static let qwertyNeighbors: [Character: [Character]] = [
        "q": ["w","a"], "w": ["q","e","s"], "e": ["w","r","d"], "r": ["e","t","f"],
        "t": ["r","y","g"], "y": ["t","u","h"], "u": ["y","i","j"], "i": ["u","o","k"],
        "o": ["i","p","l"], "p": ["o","l"],
        "a": ["q","s","z"], "s": ["a","d","w","x"], "d": ["s","f","e","c"],
        "f": ["d","g","r","v"], "g": ["f","h","t","b"], "h": ["g","j","y","n"],
        "j": ["h","k","u","m"], "k": ["j","l","i"], "l": ["k","o","p"],
        "z": ["a","x"], "x": ["z","c","s"], "c": ["x","v","d"], "v": ["c","b","f"],
        "b": ["v","n","g"], "n": ["b","m","h"], "m": ["n","j"],
    ]

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

#if ITS_SELECTION
/// 前面アプリで選択中の文字列をアクセシビリティ API で読む。読むだけで、書かない。
enum SelectionReader {
    struct Hit {
        let text: String
        let pid: pid_t
    }

    /// kTCCServiceAccessibility が許可されているか。プロンプトは出さない
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 未許可なら OS 標準のダイアログを出す。「システム設定を開く」ボタンが
    /// 正しいペインへ直接飛ぶので、項目名の改称（macOS 26 で「アクセシビリティ」
    /// →「デバイスの制御とデータへのアクセス」）に左右されない
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 必ずバックグラウンドから呼ぶこと。
    /// イベントタップはメインランループで動いているので、メインで AX の同期 IPC を
    /// すると応答しない相手で既定6秒止まり、.tapDisabledByTimeout でタップごと止まる
    static func read(timeout: Float = 0.25) -> Hit? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, timeout)

        // 編集できる場所だけを相手にする。Safari の本文や Mail の受信文、
        // ターミナルのスクロールバックは選択を読めても書けない。ここで確実に落とす
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
              let r = role as? String, r == kAXTextAreaRole || r == kAXTextFieldRole else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return Hit(text: text, pid: pid)
    }
}
#endif
