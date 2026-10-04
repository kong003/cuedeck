import AudioToolbox
import CMixer
import CoreAudio
import CoreMedia
import Foundation

enum AudioOutputError: LocalizedError {
    case coreAudio(String, OSStatus)
    case mixer

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): return "Audio output failed (\(step), error \(status))."
        case .mixer: return "Could not create the audio mixer."
        }
    }
}

/// Host clock helpers (mach_absolute_time ticks).
enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func ticks(seconds: Double) -> UInt64 { UInt64(max(0, seconds) * ticksPerSecond) }

    static func cmTime(_ ticks: UInt64) -> CMTime { CMClockMakeHostTimeFromSystemUnits(ticks) }
}

/// Owns one Core Audio output unit (AUHAL) bound to a device and the mixer
/// that renders into it. The unit runs continuously (silence when idle) so
/// cues start instantly and the clock never stops.
final class AudioOutput: @unchecked Sendable {
    let device: AudioDevice
    let mixer: OpaquePointer
    let sampleRate: Double
    let channels: Int
    /// Clock of the audio device; video players are slaved to it so long
    /// cues never drift (for Dante this is the network clock).
    let clock: CMClock?

    private var unit: AudioUnit?
    private var disposed = false

    init(device: AudioDevice) throws {
        self.device = device
        let rate = CoreAudioDevices.nominalSampleRate(device.id) ?? device.sampleRate
        let channelCount = min(max(device.outputChannels, 1), Int(CM_MAX_OUT))
        guard rate > 0, let m = cm_mixer_create(UInt32(channelCount), rate, HostClock.ticksPerSecond) else {
            throw AudioOutputError.mixer
        }
        self.sampleRate = rate
        self.channels = channelCount
        self.mixer = m

        var deviceClock: CMClock?
        CMAudioDeviceClockCreate(allocator: kCFAllocatorDefault, deviceUID: device.uid as CFString,
                                 clockOut: &deviceClock)
        self.clock = deviceClock

        do {
            unit = try Self.makeUnit(deviceID: device.id, channels: channelCount, rate: rate, mixer: m)
        } catch {
            cm_mixer_destroy(m)
            disposed = true
            throw error
        }
        applyDeviceLatency()
        if let u = unit {
            let st = AudioOutputUnitStart(u)
            if st != noErr {
                dispose()
                throw AudioOutputError.coreAudio("start", st)
            }
        }
    }

    deinit { dispose() }

    private static func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw AudioOutputError.coreAudio(step, status) }
    }

    private static func makeUnit(deviceID: AudioDeviceID, channels: Int, rate: Double,
                                 mixer: OpaquePointer) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioOutputError.coreAudio("find AUHAL", -1)
        }
        var maybeUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &maybeUnit), "create unit")
        guard let unit = maybeUnit else { throw AudioOutputError.coreAudio("create unit", -1) }

        do {
            var off: UInt32 = 0
            var on: UInt32 = 1
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &off, u32), "disable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &on, u32), "enable output")

            var dev = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &dev,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

            var format = AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &format,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set format")

            var maxFrames: UInt32 = 4096
            _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                     kAudioUnitScope_Global, 0, &maxFrames, u32)

            var callback = AURenderCallbackStruct(inputProc: cm_render_callback,
                                                  inputProcRefCon: UnsafeMutableRawPointer(mixer))
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
            try check(AudioUnitInitialize(unit), "initialize")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Compensates the device's own output latency so audio and video line up.
    func applyDeviceLatency() {
        let latencyFrames = Double(CoreAudioDevices.outputLatencyFrames(device.id))
        cm_mixer_set_latency_ticks(mixer, Int64(latencyFrames / sampleRate * HostClock.ticksPerSecond))
    }

    func setMasterGain(_ gain: Float) { cm_mixer_set_master_gain(mixer, gain) }

    func takePeaks() -> [Float] {
        var peaks = [Float](repeating: 0, count: channels)
        peaks.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress { cm_mixer_take_peaks(mixer, base, UInt32(channels)) }
        }
        return peaks
    }

    var underruns: UInt64 { cm_mixer_underruns(mixer) }

    /// Stops the unit and frees the mixer. All voices must be released first.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            unit = nil
        }
        cm_mixer_destroy(mixer)
    }
}
