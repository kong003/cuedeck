import AVFoundation
import CMixer
import CoreMedia
import Foundation
import ObjCSupport

/// Decodes every audio track of a cue on a background thread and feeds the
/// mixer's ring buffers. Each track gets its own AVAssetReader so tracks never
/// block each other. The reader also resamples to the device rate and applies
/// pitch-preserving time stretching for speed changes.
final class AudioDecoder: @unchecked Sendable {
    private let mixer: OpaquePointer
    private let voice: Int32
    private var readers: [AVAssetReader] = []
    private var outputs: [AVAssetReaderOutput] = []
    private let channels: [Int]

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
    private let finished = DispatchSemaphore(value: 0)
    private var started = false
    private(set) var errorMessage: String?

    init(asset: AVAsset, tracks: [(track: AVCompositionTrack, channels: Int, layout: Data?)],
         sampleRate: Double, mixer: OpaquePointer, voice: Int32, startTime: Double = 0) throws {
        self.mixer = mixer
        self.voice = voice
        self.channels = tracks.map(\.channels)

        for t in tracks {
            let reader = try AVAssetReader(asset: asset)
            if startTime > 0 {
                reader.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 48000),
                                               duration: .positiveInfinity)
            }
            // Try with the track's own channel layout first, then without it.
            var added: AVAssetReaderAudioMixOutput?
            var lastError = "unknown error"
            for layout in [t.layout, nil] {
                let settings = MediaInspector.pcmSettings(channels: t.channels, layout: layout, rate: sampleRate)
                var candidate: AVAssetReaderAudioMixOutput?
                if let problem = CDCatchException({
                    let output = AVAssetReaderAudioMixOutput(audioTracks: [t.track], audioSettings: settings)
                    output.audioTimePitchAlgorithm = .spectral
                    output.alwaysCopiesSampleData = false
                    if reader.canAdd(output) {
                        reader.add(output)
                        candidate = output
                    }
                }) {
                    lastError = problem
                    continue
                }
                if let candidate {
                    added = candidate
                    break
                }
                if t.layout == nil { break }
            }
            guard let output = added else {
                throw MediaError.build("The audio of this file can't be decoded (\(lastError)).")
            }
            readers.append(reader)
            outputs.append(output)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        for r in readers { r.startReading() }
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.name = "CueDeck audio decoder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops decoding and waits for the thread to exit. After this returns the
    /// decoder never touches the mixer again.
    func cancelAndWait() {
        cancelled = true
        if started { _ = finished.wait(timeout: .now() + 5) }
        for r in readers where r.status == .reading { r.cancelReading() }
    }

    /// Waits until every track has `seconds` of audio buffered (or ended).
    func waitForPrefill(seconds: Double, sampleRate: Double, timeout: Double = 8) async -> Bool {
        let wanted = UInt32(seconds * sampleRate)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var ready = true
            for t in 0..<channels.count {
                let buffered = cm_voice_buffered(mixer, voice, UInt32(t))
                let space = cm_voice_write_space(mixer, voice, UInt32(t))
                if buffered < wanted && space > 0 && !trackDone(t) { ready = false }
            }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private var doneFlags: [Bool] = []
    private func trackDone(_ t: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return t < doneFlags.count ? doneFlags[t] : false
    }
    private func markDone(_ t: Int) {
        lock.lock(); defer { lock.unlock() }
        if doneFlags.count < channels.count { doneFlags = Array(repeating: false, count: channels.count) }
        doneFlags[t] = true
    }

    private func run() {
        let n = outputs.count
        var pending = [[Float]](repeating: [], count: n)
        var offset = [Int](repeating: 0, count: n)   // frames already written from pending
        var done = [Bool](repeating: false, count: n)

        while !cancelled {
            var progressed = false
            for t in 0..<n where !done[t] {
                let ch = channels[t]
                if offset[t] * ch >= pending[t].count {
                    // Need a new buffer, but only if there is room for it.
                    guard cm_voice_write_space(mixer, voice, UInt32(t)) > 0 else { continue }
                    if let sample = outputs[t].copyNextSampleBuffer() {
                        load(sample, into: &pending[t])
                        offset[t] = 0
                        progressed = true
                    } else {
                        if readers[t].status == .failed {
                            errorMessage = readers[t].error?.localizedDescription
                        }
                        done[t] = true
                        markDone(t)
                        cm_voice_set_eof(mixer, voice, UInt32(t))
                        progressed = true
                        continue
                    }
                }
                let remaining = pending[t].count / ch - offset[t]
                if remaining > 0 {
                    let written = pending[t].withUnsafeBufferPointer { buf -> UInt32 in
                        guard let base = buf.baseAddress else { return 0 }
                        return cm_voice_write(mixer, voice, UInt32(t), base + offset[t] * ch, UInt32(remaining))
                    }
                    if written > 0 {
                        offset[t] += Int(written)
                        progressed = true
                    }
                }
            }
            if done.allSatisfy({ $0 }) { break }
            if !progressed { usleep(4000) }
        }
    }

    private func load(_ sample: CMSampleBuffer, into buffer: inout [Float]) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        if buffer.count != count { buffer = [Float](repeating: 0, count: count) }
        buffer.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: base)
            }
        }
    }
}
