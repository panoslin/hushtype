import Foundation
import HushtypeCore

// hushtype-engine: the speech-recognition helper process started by Hushtype.app (see RemoteEngine).
// Reads requests on stdin and writes responses on stdout using EngineIPC framing. Exits when stdin
// closes or on {"op":"quit"}; the app ends it after a period of inactivity to free all model memory.

setvbuf(stdout, nil, _IONBF, 0)
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let host = EngineHost(models: ModelManager())

func reply(_ obj: [String: Any]) {
    try? EngineIPC.writeFrame(EngineIPC.json(obj), to: output)
}

/// Runs an async operation to completion from the synchronous read loop.
func blocking<T>(_ op: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { box.deallocate() }
    Task.detached(priority: .userInitiated) {
        box.initialize(to: await op())
        sem.signal()
    }
    sem.wait()
    return box.move()
}

while let frame = try? EngineIPC.readFrame(from: input) {
    let req = EngineIPC.object(frame)
    switch req["op"] as? String {
    case "load":
        let w = req["whisper"] as? Bool ?? false
        blocking { await host.warmUp(whisper: w) }
        reply(["ok": true])
    case "wait":
        let w = req["whisper"] as? Bool ?? false
        let timeout = req["timeout"] as? Double ?? 600
        let (a, b) = blocking { await host.recognizers(whisper: w, whisperGrace: timeout) }
        reply(["sense": a != nil, "whisper": b != nil])
    case "status":
        let r = blocking { await host.readiness() }
        reply(["sense": r.sense, "whisper": r.whisper])
    case "transcribe":
        guard let data = try? EngineIPC.readFrame(from: input) else { exit(0) }
        let samples = EngineIPC.samples(data)
        let w = req["whisper"] as? Bool ?? false
        let grace = req["grace"] as? Double ?? 1.0
        let (a, b) = blocking { await host.recognizers(whisper: w, whisperGrace: grace) }
        guard let a else { reply(["error": "语音模型加载失败"]); continue }
        let results: (Transcript, Transcript?) = blocking {
            async let ta: Transcript = Task.detached(priority: .userInitiated) {
                (try? a.transcribe(samples, sampleRate: 16000)) ?? Transcript(text: "", engine: a.engine)
            }.value
            async let tb: Transcript? = b == nil ? nil : (try? await b!.transcribe(samples))
            return await (ta, tb)
        }
        reply(["a": EngineIPC.encode(results.0), "b": EngineIPC.encode(results.1)])
    case "quit":
        exit(0)
    default:
        reply(["error": "unknown op"])
    }
}
exit(0)
