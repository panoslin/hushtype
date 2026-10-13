import AppKit
import HushtypeCore

/// Runs one dictation: hotkey → record → recognize → rewrite → insert → history.
@MainActor
final class DictationController {
    private let app: AppModel
    private let hud = HUDController()
    private let recorder = AudioRecorder()
    private let muter = OutputMuter()
    let hotkey = HotkeyMonitor()

    private enum State { case idle, recording(Session), processing }
    private struct Session {
        var command = false
        /// QA only (locked screen with --test-audio): run the whole pipeline, never insert.
        var dryRun = false
        let started: Date
        var context: DictationContext?
        let bundleID: String?
        let appName: String?
    }
    private var state: State = .idle {
        didSet {
            switch state {
            case .idle: onActivity?(.idle)
            case .recording: onActivity?(.recording)
            case .processing: onActivity?(.processing)
            }
        }
    }
    enum Activity { case idle, recording, processing }
    /// Lets the menu bar icon mirror what Hushtype is doing.
    var onActivity: ((Activity) -> Void)?
    /// Screen frame of the menu bar icon (target of the "no text field" flight).
    var statusItemFrame: (() -> NSRect?)?
    /// Called when text lands in the menu bar (the icon plays its catch animation).
    var onParked: (() -> Void)?
    private var processingTask: Task<Void, Never>?

    /// Recordings shorter than this are treated as accidental taps.
    static let minimumSeconds = 0.35

    init(app: AppModel) {
        self.app = app
        recorder.onLevel = { [weak self] l in self?.hud.model.push(level: l) }
        hud.onCancel = { [weak self] in self?.cancel() }
        hotkey.onEvent = { [weak self] e in self?.handle(e) }
        hotkey.onTriggerState = { [weak app] down in
            app?.triggerDown = down
            if down { app?.triggerSeen = true }
        }
        applySettings()
    }

    func applySettings() {
        hotkey.hotkey = app.settings.hotkey
        hotkey.doubleTapHandsFree = app.settings.doubleTapHandsFree
        hotkey.tapToToggle = app.settings.tapToToggle
    }

    func startMonitoring() -> Bool { hotkey.start() }

    private func handle(_ e: HotkeyMonitor.Event) {
        switch e {
        case .begin: begin()
        case .finish: finish()
        case .cancel: cancel()
        case .handsFree:
            if case .recording = state { hud.show(.listening(handsFree: true)) }
        case .command:
            if case .recording(var session) = state {
                session.command = true
                // Commands need the selection even when context sharing is off (never from password managers).
                if session.context?.selectedText == nil, !HushtypeSettings.neverReadContext.contains(session.bundleID ?? "") {
                    var c = session.context ?? DictationContext(appName: session.appName, bundleID: session.bundleID)
                    c.selectedText = FocusedElement.context().selectedText
                    session.context = c
                }
                state = .recording(session)
                hud.show(.command)
                Log.info("command mode")
            }
        }
    }

    /// Menu bar / test entry point: toggles a hands-free dictation.
    func toggleFromMenu() {
        if case .recording = state { finish() } else { begin(handsFree: true) }
    }

    func begin(handsFree: Bool = false) {
        Log.info("begin (handsFree: \(handsFree))")
        if case .processing = state { return }
        if case .recording = state {
            // Second press of a double-tap: keep the running recording, switch HUD to hands-free.
            hud.show(.listening(handsFree: true))
            return
        }
        guard app.isReady else {
            Log.info("begin refused: engine not ready (\(app.engineStatusMessage))")
            hud.show(.error(app.engineStatusMessage), autoHide: 2.5)
            return
        }
        guard app.permissions.microphone == .authorized else {
            Log.info("begin refused: microphone not authorized")
            hud.show(.error(String(localized: "需要麦克风权限：在设置里打开")), autoHide: 3)
            return
        }
        let qaDryRun = Self.testAudio != nil && FocusedElement.isSecureContext
        if FocusedElement.isSecureContext && !qaDryRun {
            Log.info("begin refused: secure context (locked screen, login window or password field)")
            hud.show(.error(String(localized: "当前是密码输入或锁屏状态，Hushtype 不会录音")), autoHide: 2)
            return
        }
        // Show the pill before anything slow (reading context, starting the microphone — up to 0.6 s
        // with echo cancellation), so the key press gets instant feedback.
        let t0 = Date()
        hud.model.recordingStarted = Date()
        hud.model.inCall = false
        hud.show(.listening(handsFree: handsFree))
        CATransaction.flush()
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        let ctx = !qaDryRun && app.settings.allowsContext(for: bundleID) && FocusedElement.isTrusted
            ? FocusedElement.context() : nil
        // Checked before we open the mic ourselves: someone else using it means a call or meeting.
        let inCall = AudioDevices.inputInUseElsewhere(uid: app.settings.microphoneUID)
        hud.model.inCall = inCall
        do {
            try recorder.start(deviceUID: app.settings.microphoneUID, echoCancel: inCall)
        } catch {
            Log.info("recorder failed: \(error)")
            hud.hide()
            hud.show(.error((error as? LocalizedError)?.errorDescription ?? String(localized: "无法开始录音")), autoHide: 3)
            return
        }
        app.warmUpForDictation()
        state = .recording(Session(dryRun: qaDryRun, started: Date(), context: ctx, bundleID: bundleID,
                                   appName: front?.localizedName))
        hotkey.isDictating = true
        if app.settings.playSounds { Sounds.play(.start, theme: .droplet) }
        if inCall { Log.info("microphone already in use by another app (call/meeting)") }
        // In a call, muting would also silence the other people; leave audio alone.
        if app.settings.muteWhileDictating && !inCall {
            // Let the start sound finish before going quiet.
            DispatchQueue.main.asyncAfter(deadline: .now() + (app.settings.playSounds ? 0.3 : 0)) { [weak self] in
                guard let self, case .recording = self.state else { return }
                self.muter.mute()
            }
        }
        Log.info(String(format: "recording started %.0f ms after the key", Date().timeIntervalSince(t0) * 1000))
        // Write the prompt cache while the user talks, so the rewrite after release is fast.
        if app.settings.provider != .offline, app.rewriter.backend != nil {
            let system = app.engine.systemPrompt(app.engineOptions(), twoHypotheses: app.wantsWhisper)
            Task.detached(priority: .utility) { [rewriter = app.rewriter] in await rewriter.prewarm(system: system) }
        }
    }

    /// The last recording that did not make it into a text field (cancelled, failed, or nowhere to
    /// insert). Long dictations are never lost silently; the menu offers to recover this one.
    private(set) var recoverable: (samples: [Float], context: DictationContext?, command: Bool)?
    static let keepAfterSeconds = 2.0

    func cancel() {
        Log.info("cancel")
        if case .recording = state, app.settings.playSounds { Sounds.play(.cancel, theme: .droplet) }
        hotkey.isDictating = false
        hotkey.reset()
        switch state {
        case .recording(let session):
            let samples = recorder.stop()
            muter.restore()
            state = .idle
            if Double(samples.count) / 16000 >= Self.keepAfterSeconds {
                recoverable = (samples, session.context, session.command)
                saveCancelled(samples, session: session)
            } else {
                hud.hide()
            }
        case .processing:
            processingTask?.cancel()
            state = .idle
            hud.hide()
        case .idle:
            break
        }
    }

    /// A cancelled dictation is still recognized and cleaned up in the background — just not inserted —
    /// and saved to History, so an accidental cancel never loses what the user said.
    private func saveCancelled(_ samples: [Float], session: Session) {
        hud.show(.processing)
        var options = app.engineOptions()
        options.command = false
        let wantWhisper = app.wantsWhisper
        let seconds = Double(samples.count) / 16000
        Task { [weak self] in
            guard let self else { return }
            guard let (a, b) = try? await self.app.engines.transcribe(samples, whisper: wantWhisper) else {
                self.hud.show(.error(String(localized: "已取消 · 录音已保存，可在菜单栏「恢复上一段录音」")), autoHide: 4)
                return
            }
            let out = await self.app.engine.finish(primary: a, secondary: b, context: session.context, options: options)
            guard !out.text.isEmpty else { self.hud.hide(); return }
            let item = HistoryItem(text: out.text, rawText: a.text, appName: session.appName, bundleID: session.bundleID,
                                   durationSeconds: seconds, latencySeconds: 0, outcome: "cancelled")
            self.app.history.add(item)
            self.app.lastResult = item
            Log.info(String(format: "cancelled dictation saved to history (%.1fs audio)", seconds))
            // Only show the HUD if nothing new started meanwhile.
            if case .idle = self.state {
                self.hud.model.copyText = out.text
                self.hud.show(.saved(String(localized: "已取消 · 文字已存到历史")), autoHide: 6)
            }
        }
    }

    /// Re-runs the saved recording through recognition and rewrite and inserts it at the caret.
    func recoverLast() {
        guard let r = recoverable, case .idle = state else { return }
        Log.info("recovering last recording (\(r.samples.count / 16000)s)")
        let front = NSWorkspace.shared.frontmostApplication
        var session = Session(started: Date(), context: r.context, bundleID: front?.bundleIdentifier,
                              appName: front?.localizedName)
        session.command = r.command
        state = .recording(session)
        injected = r.samples
        finish()
    }

    /// Self-test: runs the exact post-recording pipeline on a file instead of the microphone.
    /// `Hushtype --selftest <audio>` (used for automated end-to-end checks).
    func selfTest(samples: [Float]) {
        begin()
        guard case .recording = state else { return }
        injected = samples
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish() }
    }
    private var injected: [Float]?

    /// QA hook: `--test-audio <file>` replaces microphone input with the file for every dictation,
    /// so the real hotkey → HUD → context → insert path can be tested unattended.
    /// Several files can be given separated by ":"; each dictation uses the next one.
    static let testAudio: [[Float]]? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--test-audio"), i + 1 < a.count else { return nil }
        let clips = a[i + 1].split(separator: ":").compactMap { try? AudioFile.read16kMono(URL(fileURLWithPath: String($0))) }
        return clips.isEmpty ? nil : clips
    }()
    private var testIndex = 0

    func finish() {
        guard case .recording(let session) = state else { return }
        hotkey.isDictating = false
        // Finishing from the menu / panel must also clear the key's hands-free state, or the next
        // tap would only "end" a dictation that is already over.
        hotkey.reset()
        var samples = recorder.stop()
        muter.restore()
        if let inj = injected { samples = inj; injected = nil }
        if let t = Self.testAudio { samples = t[testIndex % t.count]; testIndex += 1 }
        let seconds = Double(samples.count) / 16000
        guard seconds >= Self.minimumSeconds else {
            Log.info(String(format: "recording too short (%.2fs), discarded", seconds))
            state = .idle
            hud.show(.error(String(localized: "录音太短，没有收到声音")), autoHide: 1.5)
            return
        }
        if app.settings.playSounds { Sounds.play(.stop, theme: .droplet) }
        state = .processing
        hud.show(.processing)
        var options = app.engineOptions()
        options.command = session.command
        // No network: don't wait for a request to time out — use the local transcript straight away.
        let offlineFallback = !app.isOnline && options.rewriteEnabled && !session.command
        if offlineFallback { options.rewriteEnabled = false }
        if session.command && (app.settings.provider == .offline || !app.isOnline) {
            state = .idle
            hud.show(.error(app.isOnline ? String(localized: "指令模式需要整理服务（离线模式不可用）") : String(localized: "没有网络，指令模式暂时不可用")), autoHide: 3)
            return
        }
        let keepAudio = app.settings.keepAudio
        // Whisper only helps short dictations: long ones are cleaned up in chunks from SenseVoice alone,
        // so don't spend minutes of compute on a second transcript nobody will read.
        let wantWhisper = app.wantsWhisper && seconds < 8 * 60
        let released = Date()
        processingTask = Task { [weak self] in
            guard let self else { return }
            let transcripts: (Transcript, Transcript?)
            do {
                transcripts = try await self.app.engines.transcribe(samples, whisper: wantWhisper)
            } catch {
                Log.info("recognition failed: \(error)")
                self.recoverable = (samples, session.context, session.command)
                self.state = .idle
                self.hud.show(.error(String(localized: "语音识别失败 · 录音已保存，可在菜单栏重试")), autoHide: 4)
                return
            }
            var out = await self.app.engine.finish(primary: transcripts.0, secondary: transcripts.1,
                                                   context: session.context, options: options)
            if Task.isCancelled { return }
            if offlineFallback { out.rewriteError = "offline" }
            await self.deliver(out, session: session, samples: samples, seconds: seconds, keepAudio: keepAudio,
                               released: released)
        }
    }

    private func deliver(_ out: DictationOutput, session: Session, samples: [Float], seconds: Double, keepAudio: Bool,
                         released: Date) async {
        defer { state = .idle }
        let text = out.text
        guard !text.isEmpty else {
            if seconds >= Self.keepAfterSeconds { recoverable = (samples, session.context, session.command) }
            hud.show(.error(String(localized: "没有听到内容")), autoHide: 1.5)
            return
        }
        recoverable = nil
        if session.dryRun {
            Log.info(String(format: "dictation (dry run, not inserted) %.1fs audio, latency %.2fs (asr %.2f/%.2f, rewrite %.2f)",
                            seconds, Date().timeIntervalSince(released), out.primary.seconds,
                            out.secondary?.seconds ?? -1, out.rewrite?.seconds ?? -1))
            hud.hide()
            return
        }
        // The user may have switched to a password field or locked the screen while we processed.
        if FocusedElement.isSecureContext {
            Log.info("insert refused: secure context")
            TextInserter.setPasteboard(text)
            hud.show(.error(String(localized: "当前是密码输入或锁屏状态，结果已复制到剪贴板")), autoHide: 3)
            return
        }
        // Nowhere to type (desktop, file list, Hushtype itself without a field): don't paste into the void.
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // If the user switched apps while Hushtype was working, typing into whatever is in front now
        // could put the text in the wrong chat or document: park it instead.
        let switchedApp = session.bundleID != nil && frontID != session.bundleID
        // Park the text only when the focus is known not to take typing. Apps that don't describe
        // their focus to Accessibility (Feishu, custom-toolkit and remote-desktop apps) still get a
        // paste: that is what the user expects with the caret in a box, and it's harmless otherwise.
        let focus = FocusedElement.isTrusted ? FocusedElement.focusKind : .text
        if case .unknown(let role) = focus { Log.info("focus not described by the app (role \(role)); pasting anyway") }
        var notText = false
        if case .notText = focus { notText = true }
        let noField = switchedApp || (FocusedElement.isTrusted && (notText
                                                   || (frontID == Bundle.main.bundleIdentifier && (NSApp.keyWindow == nil || focus != .text))))
        let toInsert = session.command && session.context?.selectedText != nil
            ? text : TextInserter.spaced(text, after: FocusedElement.context().textBefore)
        let method: TextInserter.Method = noField
            ? .clipboardOnly
            : await TextInserter.insert(toInsert, bundleID: frontID)
        let id = UUID().uuidString
        let item = HistoryItem(id: id, text: text, rawText: out.primary.text, appName: session.appName,
                               bundleID: session.bundleID, durationSeconds: seconds,
                               // What the user feels: key release → text inserted.
                               latencySeconds: Date().timeIntervalSince(released),
                               outcome: out.rewriteError == nil ? (out.rewrite?.outcome.rawValue ?? "raw") : "raw-error",
                               audioFile: keepAudio ? app.history.saveAudio(samples, id: id) : nil)
        app.history.add(item)
        app.lastResult = item
        if !session.command, app.settings.provider != .offline {
            if let handle = FocusedElement.currentHandle(), handle.value != nil {
                scheduleLearning(inserted: text, handle: handle, url: session.context?.url)
            } else {
                Log.info("edit learning unavailable here (field text not readable)")
            }
        }
        Log.info(String(format: "dictation %.1fs audio, latency %.2fs (asr %.2f/%.2f, rewrite %.2f), %@, inserted via %@, app %@",
                        seconds, item.latencySeconds, out.primary.seconds, out.secondary?.seconds ?? -1,
                        out.rewrite?.seconds ?? -1, item.outcome, method.rawValue, session.bundleID ?? "?"))
        // The text had nowhere to go: park it in the menu bar (and on the clipboard) and fly it there.
        if noField {
            TextInserter.setPasteboard(text)
            Log.info(switchedApp ? "front app changed during processing; parked in the menu bar"
                                 : "no focused text field; parked in the menu bar and copied to clipboard")
            hud.model.parkReason = switchedApp ? String(localized: "你切换了窗口 · 文字已收进菜单栏") : String(localized: "没找到输入框 · 已收进菜单栏")
            hud.show(.noField)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                guard let target = self.statusItemFrame?() else {
                    self.app.pendingText = text
                    self.hud.hide()
                    return
                }
                self.hud.flyText(text, to: target) { [weak self] in
                    self?.app.pendingText = text
                    self?.onParked?()
                }
            }
            return
        }
        if let err = out.rewriteError {
            Log.info("rewrite skipped/failed: \(err)")
            if err == "offline" {
                hud.show(.error(String(localized: "没有网络 · 已插入本机识别的原文（未整理）")), autoHide: 3.5)
            } else if err == RewriteError.quotaMessage {
                hud.show(.error(String(localized: "今天的整理额度用完了 · 已插入本机识别的原文，明天可在历史里重新整理")), autoHide: 4.5)
            } else if err.hasPrefix(RewriteError.networkPrefix) {
                hud.show(.error(String(localized: "网络不好 · 已插入本机识别的原文（未整理）")), autoHide: 3.5)
            } else {
                hud.show(.error(String(localized: "整理失败，已插入原文：\(err)")), autoHide: 4)
            }
        } else if out.rewrite?.outcome == .fallback {
            Log.info("rewrite discarded (didn't match what was heard); inserted the transcript")
            hud.show(.error(String(localized: "整理结果和你说的对不上 · 已插入识别原文")), autoHide: 3.5)
        } else if method == .clipboardOnly {
            hud.show(.done(String(localized: "已复制，按 ⌘V 粘贴")), autoHide: 2.5)
        } else {
            hud.model.lastLatency = item.latencySeconds
            hud.show(.done(String(localized: "已插入")), autoHide: 0.9)
        }
    }
}

extension DictationController {
    /// Re-reads the field twice (20 s and 60 s after insertion); if the user corrected a term in what
    /// Hushtype typed, the corrected spelling is added to the dictionary.
    /// Watches the field the text went into for a few minutes. If the user fixes what Hushtype typed,
    /// the last version before they move on (send the message, leave the field) is learned: the edit
    /// goes into the correction memory, and corrected names/terms into the dictionary.
    func scheduleLearning(inserted: String, handle: FocusedElement.Handle, url: String?) {
        let app = self.app
        let hud = self.hud
        let hint = handle.caret
        Log.info("watching the field for edits")
        Task { @MainActor in
            var lastEdit: String?
            var misses = 0
            var seen = false   // the inserted text showed up in the field at least once
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let value = handle.value else { break }   // field closed
                let limit = max(6, inserted.count / 2)
                let located = await Task.detached(priority: .utility) {
                    EditLearner.locate(inserted: inserted, in: value, hint: hint)
                }.value
                guard let found = located, found.cost <= limit else {
                    // Gone (sent and cleared, deleted, scrolled away). Two misses in a row: it's final.
                    misses += 1
                    if misses >= 2 { break } else { continue }
                }
                misses = 0
                seen = true
                if found.cost > 0 { lastEdit = found.text }
            }
            guard seen else {
                // e.g. Google Docs: the focused element is a hidden input, the page is drawn on a canvas.
                Log.info("edit learning unavailable here (inserted text not visible in the field)")
                // Docs exposes its text only with its screen reader support on: say so, once.
                let key = "hushtype.tip.docsLearning"
                if (url ?? "").contains("docs.google.com"), !UserDefaults.standard.bool(forKey: key), case .idle = self.state {
                    UserDefaults.standard.set(true, forKey: key)
                    hud.show(.error(String(localized: "Google 文档里学不到修改 · 需开启它的屏幕阅读器支持")), autoHide: 5)
                }
                return
            }
            guard let edited = lastEdit?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                Log.info("edit watch ended: no change")
                return
            }
            let original = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            switch EditLearner.classify(inserted: original, edited: edited) {
            case .correction: break
            case .unchanged, .layoutOnly:
                Log.info("edit watch ended: only spacing / line breaks changed")
                return
            case .tooLarge:
                Log.info("edit watch ended: change too large to be a correction (rewrite or new text)")
                return
            }
            // Learn content fixes right away; a punctuation change only once the user has made it twice.
            // Layout (indentation, line breaks) never goes into the examples.
            let split = EditLearner.split(before: original, after: edited)
            let habit = split.punctuationKey.map { app.corrections.sighting(style: $0) } ?? false
            let example = habit ? (split.content == nil ? split.punctuation : split.both) : split.content
            if let example {
                app.corrections.add(before: original, after: example)
                Log.info("remembered a correction (\(app.corrections.all.count) total\(habit ? ", incl. a repeated punctuation habit" : ""))")
            } else {
                Log.info("punctuation-only edit, first time: counted, not learned yet")
            }
            var added: [String] = [], pendingTerms: [String] = []
            if split.content != nil || split.touchesWord {
                let learner = Rewriter(backend: app.rewriter.backend, model: .haiku)
                let terms = await EditLearner.correctedTerms(inserted: inserted, edited: edited, rewriter: learner)
                for t in terms where !app.settings.dictionary.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                    // A term goes into the dictionary the second time the user fixes it.
                    if app.corrections.sighting(term: t) { added.append(t) } else { pendingTerms.append(t) }
                }
                if !added.isEmpty {
                    app.settings.dictionary.append(contentsOf: added)
                    Log.info("learned \(added.count) term(s) from a repeated edit")
                }
                if !pendingTerms.isEmpty { Log.info("\(pendingTerms.count) corrected term(s) seen once, waiting for a repeat") }
            }
            guard case .idle = self.state else { return }
            let message: String? =
                !added.isEmpty ? String(localized: "已加入词典：") + added.joined(separator: "、")
                : !pendingTerms.isEmpty ? String(localized: "已记下「\(pendingTerms.joined(separator: "、"))」· 再改一次就加入词典")
                : example != nil ? String(localized: "已记住你的修改")
                : nil
            if let message { hud.show(.done(message), autoHide: 2.5) }
        }
    }
}

extension AppModel {
    var engineStatusMessage: String {
        switch engineState {
        case .notLoaded: return String(localized: "语音模型还没准备好")
        case .loading(let m): return "\(m)…"
        case .failed(let m): return m
        case .ready: return ""
        }
    }
}

/// Hushtype's own UI sounds (synthesized by Scripts/make_sounds.py, bundled in Resources/Sounds).
@MainActor
enum Sounds {
    enum Kind: String { case start, stop, cancel }
    private static var cache: [String: NSSound] = [:]

    static func play(_ kind: Kind, theme: SoundTheme) {
        let name = "\(theme.rawValue)-\(kind.rawValue)"
        let sound: NSSound? = cache[name] ?? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
                  let s = NSSound(contentsOf: url, byReference: true) else { return nil }
            s.volume = 0.6
            cache[name] = s
            return s
        }()
        sound?.stop()
        sound?.play()
    }
}
