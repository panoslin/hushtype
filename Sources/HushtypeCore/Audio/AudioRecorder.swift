import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone as 16 kHz mono Float32. The engine is created on `start()` and torn
/// down on `stop()`, so the mic indicator is only on while the user is actually dictating.
public final class AudioRecorder: @unchecked Sendable {
    /// Called on the main queue ~30 times a second with an RMS level in 0...1, for the HUD meter.
    public var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var sourceMono: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                       interleaved: false)!
    /// Int16 keeps a long dictation at half the memory of Float (1 hour ≈ 115 MB).
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var lastLevel = Date.distantPast

    /// Memory guard only — dictation length is meant to be unlimited in practice: 2 hours.
    public static let maxSeconds = 7200

    public init() {}

    public var isRecording: Bool { engine?.isRunning == true }

    /// - Parameter deviceUID: CoreAudio UID of the input device; nil uses the system default.
    /// - Parameter echoCancel: macOS voice processing (acoustic echo cancellation): removes what the
    ///   speakers play — the other side of a call — from the microphone signal, without ducking it.
    public func start(deviceUID: String? = nil, echoCancel: Bool = false) throws {
        stopEngine()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let id = AudioDevices.deviceID(forUID: uid), var dev = Optional(id) {
            if let unit = input.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }
        if echoCancel {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Keep the call at full volume (voice processing ducks other audio by default).
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                Log.info("voice processing unavailable: \(error)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        Log.info("mic format \(format.channelCount)ch \(Int(format.sampleRate)) Hz, aec \(echoCancel)")
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        // Voice processing delivers several channels (9 on Apple silicon Macs); the voice is on every
        // one of them, and a multi-channel → mono conversion yields silence, so take channel 0.
        let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        sourceMono = format.channelCount > 1 ? monoIn : nil
        converter = AVAudioConverter(from: format.channelCount > 1 ? monoIn : format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.consume(buf)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    public func stop() -> [Float] {
        stopEngine()
        lock.lock(); defer { lock.unlock() }
        let out = samples.map { Float($0) / 32767 }
        samples.removeAll()
        return out
    }

    private func stopEngine() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }

    private func consume(_ inBuf: AVAudioPCMBuffer) {
        guard let converter else { return }
        var buf = inBuf
        if let mono = sourceMono, let src = inBuf.floatChannelData,
           let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: inBuf.frameLength), let dst = m.floatChannelData {
            m.frameLength = inBuf.frameLength
            dst[0].update(from: src[0], count: Int(inBuf.frameLength))
            buf = m
        }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch[0], count: n)
        lock.lock()
        if samples.count < Self.maxSeconds * 16000 {
            samples.append(contentsOf: chunk.map { Int16(max(-1, min(1, $0)) * 32767) })
        }
        lock.unlock()

        let now = Date()
        if now.timeIntervalSince(lastLevel) > 0.033, let cb = onLevel {
            lastLevel = now
            var sum: Float = 0
            for v in chunk { sum += v * v }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            // Map roughly -50 dB...-10 dB to 0...1.
            let db = 20 * log10(max(rms, 1e-6))
            let level = min(1, max(0, (db + 50) / 40))
            DispatchQueue.main.async { cb(level) }
        }
    }
}

public enum RecorderError: Error, LocalizedError {
    case noInput
    public var errorDescription: String? { String(localized: "没有找到可用的麦克风") }
}

/// Lists CoreAudio input devices.
public enum AudioDevices {
    public struct Device: Identifiable, Hashable, Sendable {
        public var id: String { uid }
        public let uid: String
        public let name: String
    }

    public static func inputs() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    /// True when another app (a call or meeting) is already using the input device.
    public static func inputInUseElsewhere(uid: String?) -> Bool {
        var dev: AudioDeviceID
        if let uid, let d = deviceID(forUID: uid) { dev = d } else {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            dev = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
