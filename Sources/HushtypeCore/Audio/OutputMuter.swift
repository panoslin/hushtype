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
