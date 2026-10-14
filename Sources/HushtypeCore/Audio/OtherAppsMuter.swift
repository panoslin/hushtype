import CoreAudio
import Foundation

/// Silences every other app's audio while Hushtype's own sounds keep playing, using a Core Audio
/// process tap with `.muted` (macOS 14.2+). Unlike muting the output device, this survives Bluetooth
/// headphones switching between music and call mode, and the stop sound can play while music stays
/// quiet until the headphones are back in music mode. The tap is never read: nothing is recorded.
/// Needs the "system audio recording" permission (NSAudioCaptureUsageDescription).
public final class OtherAppsMuter: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let lock = NSLock()

    public init() {}

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return tap != 0 }

    /// Returns false when the tap can't be created (older macOS, permission denied).
    @discardableResult
    public func mute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard tap == 0 else { return true }
        guard #available(macOS 14.2, *) else { return false }
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.muteBehavior = .muted
        desc.isPrivate = true
        desc.name = "Hushtype quiet while dictating"
        var id = AudioObjectID(0)
        let st = AudioHardwareCreateProcessTap(desc, &id)
        guard st == noErr, id != 0 else {
            Log.info("mute other apps: tap failed (\(st))")
            return false
        }
        tap = id
        // The mute only takes effect while the tap is running: attach it to a private aggregate device
        // and run an IO proc that ignores the samples. The first run asks for the permission.
        guard startTap(desc.uuid.uuidString) else {
            Log.info("mute other apps: could not start the tap")
            destroyLocked()
            return false
        }
        Log.info("muted other apps (tap \(id), excluding \(exclude.isEmpty ? "nothing" : "Hushtype"))")
        return true
    }

    public func restore() {
        lock.lock(); defer { lock.unlock() }
        guard tap != 0 else { return }
        destroyLocked()
        Log.info("unmuted other apps")
    }

    private func startTap(_ tapUID: String) -> Bool {
        var outUID: String?
        if let out = OutputMuter.defaultOutput() {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var v: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &v) == noErr { outUID = v?.takeRetainedValue() as String? }
        }
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hushtype quiet",
            kAudioAggregateDeviceUIDKey: "app.hushtype.quiet.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        if let outUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        var agg = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr, agg != 0 else { return false }
        aggregate = agg
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { _, _, _, _, _ in }) == noErr, let proc else { return false }
        ioProc = proc
        return AudioDeviceStart(agg, proc) == noErr
    }

    private func destroyLocked() {
        if aggregate != 0 {
            if let p = ioProc { AudioDeviceStop(aggregate, p); AudioDeviceDestroyIOProcID(aggregate, p) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        ioProc = nil; aggregate = 0
        if tap != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
    }

    /// Core Audio's object for a process; it exists once the process has used audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var p = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj) == noErr,
              obj != 0 else { return nil }
        return obj
    }
}
