import Foundation

/// Wire format between the app and the `hushtype-engine` helper process: length-prefixed frames
/// (UInt32 little-endian byte count, then payload) over the helper's stdin/stdout. A request is a JSON
/// header frame, optionally followed by one binary frame of Float32 samples; every request gets one
/// JSON response frame.
public enum EngineIPC {
    public static func writeFrame(_ data: Data, to fh: FileHandle) throws {
        var len = UInt32(data.count).littleEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(data)
        try fh.write(contentsOf: frame)
    }

    /// Blocks until a whole frame arrives. Returns nil on EOF.
    public static func readFrame(from fh: FileHandle) throws -> Data? {
        guard let head = try readExactly(4, from: fh) else { return nil }
        let len = head.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard len <= 64 << 20 else { throw IPCError.frameTooLarge }
        return try readExactly(Int(len), from: fh)
    }

    static func readExactly(_ n: Int, from fh: FileHandle) throws -> Data? {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            guard let chunk = try fh.read(upToCount: n - out.count), !chunk.isEmpty else { return nil }
            out.append(chunk)
        }
        return out
    }

    public static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    public static func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    public static func samplesData(_ s: [Float]) -> Data {
        s.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func samples(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public static func encode(_ t: Transcript?) -> Any {
        guard let t else { return NSNull() }
        return ["text": t.text, "lang": t.language ?? "", "engine": t.engine, "sec": t.seconds]
    }

    public static func decode(_ any: Any?) -> Transcript? {
        guard let d = any as? [String: Any], let text = d["text"] as? String else { return nil }
        let lang = d["lang"] as? String
        return Transcript(text: text, language: (lang ?? "").isEmpty ? nil : lang,
                          engine: d["engine"] as? String ?? "?", seconds: d["sec"] as? Double ?? 0)
    }

    public enum IPCError: Error { case frameTooLarge, helperUnavailable, helperFailed(String) }
}

/// Speech recognition in a separate `hushtype-engine` process.
///
/// Why a process: model runtimes (ONNX Runtime, Core ML) keep hundreds of MB in allocator caches even
/// after their models are freed. Ending the helper when idle returns all of it to the system, and a
/// crash in a model runtime cannot take the app down — the next dictation just starts a new helper.
public final class RemoteEngine: @unchecked Sendable {
    private let executable: URL
    /// Serializes request/response exchanges (they block on pipe I/O).
    private let queue = DispatchQueue(label: "hushtype.remote-engine")
    /// Guards the process handles. Never held across I/O, so status checks and `stop()` from the main
    /// thread return immediately even while a long request (e.g. a first Whisper load) is in flight.
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var lastUse = Date()

    public init(executable: URL) {
        self.executable = executable
    }

    /// Path of the helper next to the app's executable.
    public static var bundled: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("hushtype-engine")
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// Starts the helper (if needed) and asks it to begin loading models. Returns immediately.
    public func warmUp(whisper: Bool) {
        touch()
        queue.async { _ = try? self.request(["op": "load", "whisper": whisper], payload: nil) }
    }

    /// Waits for the helper to finish loading (used at install time; Whisper's first load compiles
    /// the model for the Neural Engine and can take minutes). Polls with short status requests so
    /// dictations are never queued behind the wait.
    public func waitLoaded(whisper: Bool, timeout: TimeInterval) async -> (sense: Bool, whisper: Bool) {
        warmUp(whisper: whisper)
        let deadline = Date().addingTimeInterval(timeout)
        var last = (sense: false, whisper: false)
        while Date() < deadline {
            last = await withCheckedContinuation { cont in
                queue.async {
                    let r = (try? self.request(["op": "status"], payload: nil)) ?? [:]
                    cont.resume(returning: (r["sense"] as? Bool ?? false, r["whisper"] as? Bool ?? false))
                }
            }
            if last.sense && (!whisper || last.whisper) { return last }
            if !isRunning { warmUp(whisper: whisper) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return last
    }

    /// Recognizes `samples`. Whisper is used only if it is ready within `whisperGrace` seconds.
    public func transcribe(_ samples: [Float], whisper: Bool, whisperGrace: TimeInterval = 1.0) async throws
        -> (Transcript, Transcript?) {
        touch()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let header: [String: Any] = ["op": "transcribe", "whisper": whisper, "grace": whisperGrace]
                do {
                    let r = try self.request(header, payload: EngineIPC.samplesData(samples))
                    if let err = r["error"] as? String { throw EngineIPC.IPCError.helperFailed(err) }
                    guard let a = EngineIPC.decode(r["a"]) else { throw EngineIPC.IPCError.helperFailed("no result") }
                    cont.resume(returning: (a, EngineIPC.decode(r["b"])))
                } catch {
                    cont.resume(throwing: error)
                }
                self.touch()
            }
        }
    }

    private func touch() { lock.lock(); lastUse = Date(); lock.unlock() }

    /// Ends the helper if unused for `idle` seconds. Returns true if it was running.
    @discardableResult
    public func stopIfIdle(_ idle: TimeInterval) -> Bool {
        lock.lock()
        let idleEnough = process != nil && Date().timeIntervalSince(lastUse) >= idle
        lock.unlock()
        return idleEnough ? stop() : false
    }

    /// Ends the helper now. Any in-flight request fails (and the next one starts a fresh helper).
    @discardableResult
    public func stop() -> Bool {
        lock.lock()
        let p = process, i = input
        process = nil
        input = nil
        output = nil
        lock.unlock()
        guard let p else { return false }
        if let i { try? EngineIPC.writeFrame(EngineIPC.json(["op": "quit"]), to: i); try? i.close() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
        Log.info("engine helper stopped (pid \(p.processIdentifier))")
        return true
    }

    // MARK: request queue only

    private func start() throws -> (FileHandle, FileHandle) {
        let p = Process()
        p.executableURL = executable
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        try p.run()
        lock.lock()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        lock.unlock()
        Log.info("engine helper started (pid \(p.processIdentifier))")
        return (inPipe.fileHandleForWriting, outPipe.fileHandleForReading)
    }

    private func handles() -> (FileHandle, FileHandle)? {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning == true, let i = input, let o = output else { return nil }
        return (i, o)
    }

    /// One request/response. Restarts the helper once if it has died.
    private func request(_ header: [String: Any], payload: Data?) throws -> [String: Any] {
        for attempt in 0..<2 {
            do {
                let (i, o) = try handles() ?? { _ = stop(); return try start() }()
                try EngineIPC.writeFrame(EngineIPC.json(header), to: i)
                if let payload { try EngineIPC.writeFrame(payload, to: i) }
                guard let resp = try EngineIPC.readFrame(from: o) else { throw EngineIPC.IPCError.helperUnavailable }
                return EngineIPC.object(resp)
            } catch {
                Log.info("engine helper request failed (attempt \(attempt + 1)): \(error)")
                _ = stop()
                if attempt == 1 { throw error }
            }
        }
        throw EngineIPC.IPCError.helperUnavailable
    }
}
