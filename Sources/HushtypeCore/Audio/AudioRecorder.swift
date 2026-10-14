import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone as 16 kHz mono Float32. The engine is created on `start()` and torn
/// down on `stop()`, so the mic indicator is only on while the user is actually dictating.
public final class AudioRecorder: @unchecked Sendable {
    /// Called on the main queue ~30 times a second with an RMS level in 0...1, for the HUD meter.
    public var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    /// Plain recording uses an input-only audio queue: AVAudioEngine also starts the default output
    /// device, which on Bluetooth headphones restarts the stream and swallows the start sound.
    private var queue: AudioQueueRef?
    private var queueUID: String?
    private var stoppingQueue = false
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private let micQueue = DispatchQueue(label: "hushtype.mic")
    /// Opening, reopening and closing the queue happen here, one at a time.
    private let control = DispatchQueue(label: "hushtype.mic.control")
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

    public var isRecording: Bool { engine?.isRunning == true || queue != nil }

    /// - Parameter deviceUID: CoreAudio UID of the input device; nil uses the system default.
    /// - Parameter echoCancel: macOS voice processing (acoustic echo cancellation): removes what the
    ///   speakers play — the other side of a call — from the microphone signal, without ducking it.
    /// - Parameter useEngine: testing only — record through AVAudioEngine without voice processing.
    public func start(deviceUID: String? = nil, echoCancel: Bool = false, useEngine: Bool = false) throws {
        stopEngine()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        if !echoCancel && !useEngine {
            try control.sync { try startQueue(deviceUID: deviceUID) }
            return
        }
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

    private func startQueue(deviceUID: String?) throws {
        queueUID = deviceUID
        stoppingQueue = false
        try openQueue()
        if deviceUID == nil { watchDefaultInput(true) }
    }

    /// Opens the queue at the device's own rate and feeds the same converter as the engine path, so
    /// the 16 kHz audio the recognizers get is unchanged.
    private func openQueue() throws {
        var uid = queueUID
        if let u = uid, AudioDevices.deviceID(forUID: u) == nil {
            Log.info("mic: chosen device is gone, using the system default")
            uid = nil
        }
        guard let dev = uid.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultInputID(),
              let rate = AudioDevices.sampleRate(dev), rate > 0 else { throw RecorderError.noInput }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        sourceMono = nil
        converter = AVAudioConverter(from: mono, to: target)
        var desc = mono.streamDescription.pointee
        var q: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&q, &desc, 0, micQueue) { [weak self] q, buf, _, _, _ in
            let n = AVAudioFrameCount(buf.pointee.mAudioDataByteSize / 4)
            if n > 0, let self, let pcm = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: n), let dst = pcm.floatChannelData {
                pcm.frameLength = n
                dst[0].update(from: buf.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: Int(n))
                self.consume(pcm)
            }
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }
        guard status == noErr, let q else { throw RecorderError.noInput }
        if let u = uid {
            var cf: CFString = u as CFString
            let r = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString>.size))
            if r != noErr { Log.info("mic: could not select the chosen device (\(r)), using the system default") }
        }
        let bytes = UInt32(max(1024, rate * 0.032) * 4)   // ~32 ms per buffer
        for _ in 0..<4 {
            var b: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, bytes, &b) == noErr, let b { AudioQueueEnqueueBuffer(q, b, 0, nil) }
        }
        // The device can vanish mid-dictation (headset unplugged, Bluetooth dropped): the queue stops
        // on its own; reopen on whatever input is there and keep the samples recorded so far.
        AudioQueueAddPropertyListener(q, kAudioQueueProperty_IsRunning, { ctx, q, _ in
            let me = Unmanaged<AudioRecorder>.fromOpaque(ctx!).takeUnretainedValue()
            var running: UInt32 = 0; var size = UInt32(4)
            AudioQueueGetProperty(q, kAudioQueueProperty_IsRunning, &running, &size)
            if running == 0 { me.control.async { me.reopenIfDropped(q) } }
        }, Unmanaged.passUnretained(self).toOpaque())
        let st = AudioQueueStart(q, nil)
        guard st == noErr else { AudioQueueDispose(q, true); throw RecorderError.noInput }
        queue = q
        Log.info("mic: audio queue, \(Int(rate)) Hz\(uid == nil ? "" : " (chosen device)")")
    }

    private func reopenIfDropped(_ q: AudioQueueRef) {
        guard !stoppingQueue, queue == q else { return }
        Log.info("mic: input stopped mid-recording, reopening")
        reopenQueue()
    }

    /// Closes the current queue and opens a new one on the current device; samples are kept.
    public func restartQueue() { control.sync { reopenQueue() } }

    private func reopenQueue() {
        guard let old = queue else { return }
        queue = nil
        AudioQueueStop(old, true); AudioQueueDispose(old, true)
        do { try openQueue() } catch { Log.info("mic: reopen failed: \(error)") }
    }

    private func watchDefaultInput(_ on: Bool) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if on {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stoppingQueue, self.queue != nil else { return }
                Log.info("mic: system input changed mid-recording, switching")
                self.reopenQueue()
            }
            defaultListener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
        } else if let block = defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
            defaultListener = nil
        }
    }

    private func stopEngine() {
        if queue != nil || defaultListener != nil {
            control.sync {
                stoppingQueue = true
                watchDefaultInput(false)
                if let q = queue { queue = nil; AudioQueueStop(q, true); AudioQueueDispose(q, true) }
            }
        }
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
        append(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// 16 kHz mono samples from either capture path.
    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        let n = chunk.count
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

    /// True when recording from `uid` (nil = system default) uses a Bluetooth headset microphone,
    /// which switches the headphones into call mode (mono, 16–24 kHz) while it is open.
    public static func isBluetoothInput(uid: String?) -> Bool {
        guard let id = uid.flatMap(deviceID(forUID:)) ?? defaultInputID() else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : nil
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
