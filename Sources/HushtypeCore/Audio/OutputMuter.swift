import CoreAudio
import Foundation

/// Mutes the default output device while the user dictates (music and videos go quiet) and restores
/// exactly the previous state afterwards. Devices without a mute control (some HDMI/USB outputs) fall
/// back to volume 0 and restore the previous volume.
public final class OutputMuter: @unchecked Sendable {
    private var saved: (device: AudioDeviceID, mute: UInt32?, volume: Float32?)?
    private let lock = NSLock()

    public init() {}

    public func mute() {
        lock.lock(); defer { lock.unlock() }
        guard saved == nil, let dev = Self.defaultOutput() else { return }
        let m: UInt32? = Self.get(dev, kAudioDevicePropertyMute)
        if m == 1 { return }  // already muted by the user: leave alone
        if m != nil, Self.set(dev, kAudioDevicePropertyMute, UInt32(1)) {
            saved = (dev, 0, nil)
        } else if let v: Float32 = Self.get(dev, kAudioDevicePropertyVolumeScalar), v > 0,
                  Self.set(dev, kAudioDevicePropertyVolumeScalar, Float32(0)) {
            saved = (dev, nil, v)
        }
    }

    public func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let s = saved else { return }
        saved = nil
        if let m = s.mute { _ = Self.set(s.device, kAudioDevicePropertyMute, m) }
        if let v = s.volume { _ = Self.set(s.device, kAudioDevicePropertyVolumeScalar, v) }
    }

    /// The default output, as far as timing goes: Bluetooth headphones buffer ~0.1–0.3 s of audio,
    /// apply mute / unmute on the earbuds, and let the link go idle in silence (the first part of the
    /// next sound is spent waking it), so UI sounds have to be scheduled around that.
    public struct Route: Sendable { public var bluetooth: Bool; public var latency: Double; public var running = false }
    public static func currentRoute() -> Route {
        guard let dev = defaultOutput() else { return Route(bluetooth: false, latency: 0) }
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : 0
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &rate)
        let t = u32(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        let frames = u32(kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
            + u32(kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)
            + u32(kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput)
        return Route(bluetooth: t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
                     latency: rate > 0 ? Double(frames) / rate : 0,
                     running: u32(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) != 0)
    }

    /// Calls `done` on the main queue once the default output's sample rate satisfies `ok` (checked
    /// every 50 ms), or after `timeout`. Headphones in call mode run at 16–24 kHz, in music mode at
    /// 44.1 / 48 kHz, so this waits for a Bluetooth headset to finish switching either way.
    public static func whenOutputRate(_ ok: @escaping @Sendable (Double) -> Bool, timeout: Double,
                                      _ done: @escaping @Sendable (_ timedOut: Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        @Sendable func check() {
            let rate = defaultOutput().flatMap { dev -> Double? in
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
                var r: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
                return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &r) == noErr ? r : nil
            } ?? 48000
            if ok(rate) { DispatchQueue.main.async { done(false) }; return }
            if Date() >= deadline { DispatchQueue.main.async { done(true) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        check()
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> T? where T: Numeric {
        var addr = address(sel)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func set<T>(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ value: T) -> Bool {
        var addr = address(sel)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr), AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
}
