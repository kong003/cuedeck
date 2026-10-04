import CoreAudio
import Foundation

/// An audio output device as seen by Core Audio (built-in output, USB
/// interfaces, Dante Virtual Soundcard, BlackHole, ...).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
    let sampleRate: Double

    var menuLabel: String {
        let rate = sampleRate >= 1000 ? String(format: "%.1f kHz", sampleRate / 1000) : "?"
        return "\(name) (\(outputChannels) ch, \(rate))"
    }
}

enum CoreAudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func allOutputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioDevice(id: id,
                               uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                               outputChannels: channels,
                               sampleRate: nominalSampleRate(id) ?? 0)
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return st == noErr && rate > 0 ? rate : nil
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(selector, scope)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// Frames between the IO cycle's output time stamp and the sound leaving
    /// the device: device latency + safety offset + first stream's latency.
    static func outputLatencyFrames(_ id: AudioDeviceID) -> UInt32 {
        var total = uint32Property(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
        total += uint32Property(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)

        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                total += uint32Property(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return total
    }

    /// Calls `handler` on the main queue whenever devices are added or removed
    /// or the default output changes. Returns a token that removes the listener.
    static func observeChanges(_ handler: @escaping () -> Void) -> () -> Void {
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
        var removers: [() -> Void] = []
        for selector in selectors {
            var addr = address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            let st = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
            if st == noErr {
                removers.append {
                    var a = address(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
                }
            }
        }
        return { removers.forEach { $0() } }
    }
}
