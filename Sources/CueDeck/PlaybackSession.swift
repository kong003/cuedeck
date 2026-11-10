import AVFoundation
import CMixer
import Foundation
import OSLog
import QuartzCore

/// Diagnostics of stream playback (Console.app, subsystem "CueDeck").
let streamLog = Logger(subsystem: "CueDeck", category: "stream")

/// Serial queue for releasing audio resources. Voices are released here and
/// audio outputs are disposed here too, so an output is never destroyed while
/// a decoder still writes into its mixer.
enum AudioCleanup {
    static let queue = DispatchQueue(label: "CueDeck.audio-cleanup", qos: .utility)

    /// Silences a voice now and frees it (and its decoder) in the background.
    static func release(voice: Int32, decoder: VoiceFeeder?, output: AudioOutput?) {
        guard let output, voice >= 0 else {
            if let decoder { queue.async { decoder.cancelAndWait() } }
            return
        }
        cm_voice_stop(output.mixer, voice, 0)
        queue.async {
            decoder?.cancelAndWait()
            cm_voice_release(output.mixer, voice)
        }
    }
}

/// One playing instance of a cue: an audio voice in the mixer (all audio
/// tracks, routed to output channels) plus an AVPlayer for the video, both
/// started at the same host time and running on the audio device's clock.
///
/// Positions are "media time" (see CueTimeline): seconds of source material
/// since the cue's start point. Output time = media time / speed.
@MainActor
final class PlaybackSession: Identifiable {
    enum State { case preparing, playing, paused, stopping, finished }

    let id = UUID()
    private(set) var cue: Cue
    private(set) var state: State = .preparing
    private(set) var mediaDuration: Double = 0
    private(set) var speed: Double
    private(set) var finishedNaturally = false
    private(set) var isCancelled = false
    /// Set by the engine once the following cue has been scheduled.
    var followTriggered = false

    private let output: AudioOutput?
    private let video: VideoOutput
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var layerAttached = false

    private var voice: Int32 = -1
    private var voiceSpeed: Double = 1
    private var decoder: VoiceFeeder?
    /// The previous stream during a speed crossfade.
    private var retiringVoice: Int32 = -1
    private var retiringDecoder: VoiceFeeder?
    private var audioAsset: AVComposition?
    private var audioTracks: [(track: AVCompositionTrack, channels: Int, layout: Data?)] = []

    private var endObserver: NSObjectProtocol?
    private var videoEnded = false
    private var cleanedUp = false

    // Clock anchor: media time `anchorMedia` is heard at host time `anchorHost`.
    private var anchorHost: UInt64 = 0
    private var anchorMedia: Double = 0
    private var anchorPreviousSpeed: Double = 0
    private var firstStartHost: UInt64 = .max
    private var pausedMedia: Double = 0

    private var stopStartedAt: CFTimeInterval = 0
    private var stopFade: Double = 0
    /// Video fades run as Core Animation (smooth even when the UI is busy).
    /// Until this time (CACurrentMediaTime) tick() leaves the opacity alone.
    private var fadeAnimationEnd: CFTimeInterval = 0
    private var endFadeScheduled = false

    private var seekGeneration = 0
    private var seeking = false
    private var resumeAfterScrub = false
    private var targetSpeed: Double
    private var speedTask: Task<Void, Never>?

    // BCC Media streams: where the audio and video come from. The stream's
    // player runs in file time, so player time = media time + playerOffset.
    private let streamResolver: ((Cue) async throws -> StreamPlan)?
    private var streamPlan: StreamPlan?
    private var playerOffset: Double = 0
    /// A stream player the engine prepared ahead (already buffered).
    private var preparedPlayer: AVPlayer?
    /// Livestream: where it starts on the stream timeline, and the playlist
    /// proxy of its player (kept alive with the player).
    private(set) var liveStart: LiveStartPoint?
    private var liveProxy: LiveHLSProxy?

    /// Streams: the loaded part of the video around the playhead, in file time.
    var bufferedFileRange: ClosedRange<Double>? {
        guard let item = player?.currentItem else { return nil }
        let now = item.currentTime().seconds
        for r in item.loadedTimeRanges.map(\.timeRangeValue) {
            let a = r.start.seconds, b = (r.start + r.duration).seconds
            if a.isFinite, b.isFinite, a <= now + 0.5, b >= now {
                return (a + playerOffset)...(b + playerOffset)
            }
        }
        return nil
    }

    /// Livestream: the current position on the stream timeline (for subtitles).
    var liveStreamTime: Double? { liveStart.map { $0.time + mediaTime } }

    init(cue: Cue, output: AudioOutput?, video: VideoOutput,
         streamResolver: ((Cue) async throws -> StreamPlan)? = nil, preparedPlayer: AVPlayer? = nil) {
        self.cue = cue
        self.output = output
        self.video = video
        self.streamResolver = streamResolver
        self.preparedPlayer = preparedPlayer
        // Streams play at normal speed (no time stretching for them yet).
        let s = cue.isStream ? 1 : min(max(cue.speed, 0.25), 4)
        self.speed = s
        self.targetSpeed = s
    }

    var isActive: Bool { state == .preparing || state == .playing || state == .paused }
    var isDone: Bool { state == .finished && cleanedUp }

    // MARK: - Preparation

    /// Loads everything so that start(at:) is instant. Playback begins at
    /// media time `position`.
    func prepare(fromMedia position: Double = 0) async throws {
        if cue.isStream {
            try await prepareStream(fromMedia: position)
            return
        }
        let timeline = try await CueTimeline.build(for: cue, audioSpeed: speed, includeVideo: cue.playsVideo)
        if isCancelled { return }
        mediaDuration = timeline.mediaDuration
        let begin = clampMedia(position)
        pausedMedia = begin
        anchorMedia = begin

        // Audio: one mixer voice with all tracks.
        if output != nil, let comp = timeline.audioAsset, !timeline.audioTracks.isEmpty {
            audioAsset = comp
            audioTracks = Array(timeline.audioTracks.prefix(Int(CM_MAX_TRACKS)))
            let made = try await makeVoice(asset: comp, tracks: audioTracks, atMedia: begin,
                                           speed: speed, prefillSeconds: 1.0, ramp: 0)
            voice = made.voice
            decoder = made.decoder
            voiceSpeed = speed
            if isCancelled { return }
        }

        // Video: muted AVPlayer slaved to the audio device clock.
        if let videoAsset = timeline.videoAsset {
            try await attachPlayer(AVPlayerItem(asset: videoAsset), begin: begin)
        }
    }

    /// BCC Media: audio from the stream's language renditions (decoded by
    /// CueDeck into the mixer), video from the stream itself.
    private func prepareStream(fromMedia position: Double) async throws {
        guard let resolve = streamResolver else { throw MediaError.build("\(cue.name) can't be streamed.") }
        let plan = try await resolve(cue)
        if isCancelled { return }
        streamPlan = plan
        if cue.isLive {
            try await prepareLive(plan)
            return
        }
        playerOffset = cue.segmentStart
        mediaDuration = cue.segmentDuration
        let begin = clampMedia(position)
        pausedMedia = begin
        anchorMedia = begin

        if output != nil, !plan.audio.isEmpty {
            let made = try await makeStreamVoice(atMedia: begin, prefillSeconds: 1.0, ramp: 0)
            voice = made.voice
            decoder = made.decoder
            voiceSpeed = 1
            if isCancelled { return }
        }
        if cue.playsVideo {
            let prepared = preparedPlayer
            preparedPlayer = nil
            let item = prepared?.currentItem ?? AVPlayerItem(url: plan.masterURL)
            item.preferredForwardBufferDuration = 15
            if cue.outPoint > 0 { item.forwardPlaybackEndTime = cmTime(cue.segmentEnd) }
            try await attachPlayer(item, begin: begin, player: prepared)
        }
    }

    /// The livestream from a few segments behind the live edge: audio and
    /// picture both start at the beginning of the same segment.
    private func prepareLive(_ plan: StreamPlan) async throws {
        let start = try await LiveStartPoint.find(master: plan.master)
        if isCancelled { return }
        playerOffset = 0
        mediaDuration = cue.segmentDuration          // "endless": the cue's long nominal length
        pausedMedia = 0
        anchorMedia = 0
        var audioStart = start
        if cue.playsVideo {
            let proxy = LiveHLSProxy(masterURL: plan.masterURL, startSequence: start.sequence,
                                     refresh: plan.refreshMaster ?? { nil })
            liveProxy = proxy
            let item = AVPlayerItem(asset: proxy.makeAsset())
            item.preferredForwardBufferDuration = 12
            try await attachPlayer(item, begin: 0)
            if isCancelled { return }
            // The player picks its own live position and buffers from there (often a
            // segment after the playlist start). Start there, and the sound with it:
            // asking it to play anything not buffered would leave it standing still.
            if let p = player, let item = p.currentItem {
                var t = p.currentTime().seconds
                if let first = item.loadedTimeRanges.first?.timeRangeValue, first.start.seconds.isFinite,
                   !(t.isFinite && t >= first.start.seconds && t < (first.start + first.duration).seconds) {
                    t = first.start.seconds
                }
                if t.isFinite, t > 0 {
                    playerOffset = t
                    audioStart = start.advanced(by: t)
                }
            }
        }
        liveStart = audioStart
        if output != nil, !plan.audio.isEmpty {
            let made = try await makeStreamVoice(atMedia: 0, prefillSeconds: 1.0, ramp: 0)
            voice = made.voice
            decoder = made.decoder
            voiceSpeed = 1
            if isCancelled { return }
        }
        streamLog.notice("live start: sequence \(audioStart.sequence, privacy: .public), player time \(String(format: "%.2f", self.playerOffset), privacy: .public)")
    }

    /// Muted AVPlayer for `item` on the audio device clock, at media time
    /// `begin`, with its layer (still invisible) on the output.
    private func attachPlayer(_ item: AVPlayerItem, begin: Double, player existing: AVPlayer? = nil) async throws {
        let p = existing ?? AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
        p.isMuted = true
        // Subtitles are CueDeck's job (CasparCG / overlay), never the player's.
        p.appliesMediaSelectionCriteriaAutomatically = false
        if let clock = output?.clock { p.sourceClock = clock }
        player = p

        let deadline = Date().addingTimeInterval(20)
        while item.status == .unknown && Date() < deadline && !isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if isCancelled { return }
        if item.status == .failed {
            throw item.error ?? MediaError.build("The video of \(cue.name) could not be loaded.")
        }
        // A prepared player is usually at the right place already.
        if begin + playerOffset > 0, abs(p.currentTime().seconds - (begin + playerOffset)) > 0.02 || existing == nil {
            _ = await p.seek(to: playerTime(begin), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            item.select(nil, in: group)
        }
        if item.status == .readyToPlay {
            _ = await p.preroll(atRate: Float(speed))
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let session = self else { return }
            Task { @MainActor in session.videoEnded = true }
        }
        // The layer goes on the output (invisible) now, so its first frame
        // is ready the moment playback starts. This opens the output window
        // a fraction of a second before the cue starts.
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.opacity = 0
        playerLayer = layer
        video.attach(layer)
        layerAttached = true
    }

    /// A mixer voice for a BCC Media stream at media time `media` (normal speed).
    private func makeStreamVoice(atMedia media: Double, prefillSeconds: Double,
                                 ramp: Double) async throws -> (voice: Int32, decoder: VoiceFeeder) {
        guard let out = output, let plan = streamPlan else { throw MediaError.build("No audio output.") }
        let channels = cue.audioTracks.map(\.channels)
        let v = try createVoice(channelCounts: channels.map { UInt32($0) }, atMedia: media, speed: 1, ramp: ramp)
        let dec = StreamAudioDecoder(playlists: plan.audio, channels: channels,
                                     start: cue.segmentStart + media, end: cue.segmentEnd,
                                     sampleRate: out.sampleRate, mixer: out.mixer, voice: v,
                                     live: liveStart.map { .init(sequence: $0.sequence, time: $0.time, refresh: nil) },
                                     refresh: plan.refreshAudio)
        dec.start()
        _ = await dec.waitForPrefill(seconds: prefillSeconds, sampleRate: out.sampleRate, timeout: 15)
        if let failure = dec.failure {
            AudioCleanup.release(voice: v, decoder: dec, output: out)
            throw MediaError.build("\(cue.name): \(failure)")
        }
        return (v, dec)
    }

    /// A new mixer voice with routes, gain and envelope, positioned at media time `media`.
    private func createVoice(channelCounts: [UInt32], atMedia media: Double, speed s: Double,
                             ramp: Double) throws -> Int32 {
        guard let out = output else { throw MediaError.build("No audio output.") }
        let ringFrames = UInt32(out.sampleRate * 4)
        let v = channelCounts.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return cm_voice_create(out.mixer, UInt32(buf.count), base, ringFrames)
        }
        guard v >= 0 else {
            throw MediaError.build("Too many cues are playing at the same time.")
        }
        let rate = out.sampleRate
        applyRoutes(to: v, trackCount: channelCounts.count)
        cm_voice_set_gain(out.mixer, v, cue.linearGain)
        let fadeOut = cue.endAction == .loop ? 0 : cue.fadeOut
        cm_voice_set_envelope(out.mixer, v, Int64(mediaDuration / s * rate),
                              Int64(cue.fadeIn * rate), Int64(fadeOut * rate))
        cm_voice_set_position(out.mixer, v, Int64(media / s * rate))
        if ramp > 0 { cm_voice_set_start_ramp(out.mixer, v, Int64(ramp * rate)) }
        return v
    }

    /// Creates a mixer voice for an audio timeline stretched to `speed`,
    /// positioned at media time `media`, and starts decoding there.
    private func makeVoice(asset: AVComposition,
                           tracks: [(track: AVCompositionTrack, channels: Int, layout: Data?)],
                           atMedia media: Double, speed s: Double,
                           prefillSeconds: Double, ramp: Double) async throws -> (voice: Int32, decoder: VoiceFeeder) {
        guard let out = output else { throw MediaError.build("No audio output.") }
        let v = try createVoice(channelCounts: tracks.map { UInt32($0.channels) }, atMedia: media, speed: s, ramp: ramp)
        let rate = out.sampleRate
        let outputStart = media / s
        do {
            let dec = try AudioDecoder(asset: asset, tracks: tracks, sampleRate: rate,
                                       mixer: out.mixer, voice: v, startTime: outputStart)
            dec.start()
            _ = await dec.waitForPrefill(seconds: prefillSeconds, sampleRate: rate, timeout: 8)
            return (v, dec)
        } catch {
            AudioCleanup.release(voice: v, decoder: nil, output: out)
            throw error
        }
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48000)
    }

    /// The player's time for media time `m` (streams play in file time).
    private func playerTime(_ m: Double) -> CMTime { cmTime(m + playerOffset) }

    // MARK: - Transport

    /// Starts audio and video exactly at `host` (mach_absolute_time ticks).
    func start(at host: UInt64) {
        guard state == .preparing, !isCancelled else { return }
        firstStartHost = host
        setAnchor(host: host, media: pausedMedia, previousSpeed: 0)
        if voice >= 0, let out = output { cm_voice_start(out.mixer, voice, host) }
        player?.setRate(Float(speed), time: playerTime(pausedMedia), atHostTime: HostClock.cmTime(host))
        // Fade the picture in from the exact start time (instantly without a fade in).
        let fadeIn = pausedMedia <= 0 ? cue.fadeIn : 0
        animateOpacity(to: 1, over: fadeIn, from: 0, beginAt: Double(host) / HostClock.ticksPerSecond)
        state = .playing
        startSpeedTaskIfNeeded()
    }

    func pause() {
        guard state == .playing else { return }
        cancelFadeAnimation()
        releaseRetiring()
        pausedMedia = mediaTime
        if voice >= 0, let out = output {
            cm_voice_pause(out.mixer, voice)
            pausedMedia = Double(cm_voice_position(out.mixer, voice)) / out.sampleRate * voiceSpeed
        }
        player?.rate = 0
        state = .paused
    }

    func resume() {
        guard state == .paused, !seeking else { return }
        let host = HostClock.now() + HostClock.ticks(seconds: 0.08)
        var position = pausedMedia
        if voice >= 0, let out = output {
            position = Double(cm_voice_position(out.mixer, voice)) / out.sampleRate * voiceSpeed
            cm_voice_start(out.mixer, voice, host)
        }
        player?.setRate(Float(speed), time: playerTime(position), atHostTime: HostClock.cmTime(host))
        setAnchor(host: host, media: position, previousSpeed: 0)
        state = .playing
        startSpeedTaskIfNeeded()
    }

    /// Fades out over `fade` seconds and finishes. 0 stops immediately.
    func stop(fade: Double) {
        switch state {
        case .preparing:
            isCancelled = true
            return
        case .finished:
            return
        case .stopping:
            if fade <= 0 { finish() }
            return
        case .paused:
            finish()
            return
        case .playing:
            break
        }
        if fade <= 0 {
            finish()
            return
        }
        if voice >= 0, let out = output {
            cm_voice_stop(out.mixer, voice, Int64(fade * out.sampleRate))
        }
        if retiringVoice >= 0, let out = output {
            cm_voice_stop(out.mixer, retiringVoice, Int64(fade * out.sampleRate))
        }
        stopFade = fade
        stopStartedAt = CACurrentMediaTime()
        animateOpacity(to: 0, over: fade)
        state = .stopping
    }

    private func setAnchor(host: UInt64, media: Double, previousSpeed: Double) {
        anchorHost = host
        anchorMedia = media
        anchorPreviousSpeed = previousSpeed
    }

    // MARK: - Video opacity

    private func setOpacity(_ value: Float) {
        guard let layer = playerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
    }

    /// Animates the picture's opacity on the render server, from what is on
    /// screen now (or `from`), starting now or at `beginAt` (CACurrentMediaTime).
    private func animateOpacity(to target: Float, over duration: Double, from: Float? = nil,
                                beginAt: CFTimeInterval? = nil) {
        guard let layer = playerLayer else { return }
        let start = from ?? layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        setOpacity(target)
        let begin = beginAt ?? CACurrentMediaTime()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = target
        animation.duration = max(duration, 0.001)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.beginTime = layer.convertTime(begin, from: nil)
        animation.fillMode = .backwards        // holds `start` until it begins
        layer.add(animation, forKey: "fade")
        fadeAnimationEnd = begin + animation.duration
    }

    /// Keeps the opacity that is on screen and hands it back to tick().
    private func cancelFadeAnimation() {
        guard let layer = playerLayer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        setOpacity(current)
        fadeAnimationEnd = 0
        endFadeScheduled = false
    }

    /// Frees the stream that is being crossfaded away (if any).
    private func releaseRetiring(ifVoice only: Int32? = nil) {
        guard retiringVoice >= 0 else { return }
        if let only, only != retiringVoice { return }
        AudioCleanup.release(voice: retiringVoice, decoder: retiringDecoder, output: output)
        retiringVoice = -1
        retiringDecoder = nil
    }

    // MARK: - Seeking

    /// Live scrubbing while dragging: pauses and shows the frame on the output.
    func scrub(toMedia target: Double) {
        guard state == .playing || state == .paused, !cue.isLive else { return }
        if state == .playing {
            pause()
            resumeAfterScrub = true
        }
        let m = clampMedia(target)
        pausedMedia = m
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        player?.seek(to: playerTime(m), toleranceBefore: tol, toleranceAfter: tol)
    }

    /// Jumps to media time `target`. Keeps playing if the cue was playing (or
    /// was playing before scrubbing), otherwise stays paused there.
    func seek(toMedia target: Double) async {
        guard state == .playing || state == .paused, !cue.isLive else { return }
        let shouldResume = state == .playing || resumeAfterScrub
        resumeAfterScrub = false
        if state == .playing { pause() }

        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        let m = clampMedia(target)
        pausedMedia = m
        videoEnded = false

        // Audio: replace the voice with one that starts at m.
        releaseRetiring()
        if output != nil, streamPlan != nil {
            AudioCleanup.release(voice: voice, decoder: decoder, output: output)
            voice = -1
            decoder = nil
            do {
                let made = try await makeStreamVoice(atMedia: m, prefillSeconds: 0.5, ramp: 0.01)
                if generation != seekGeneration || state == .finished {
                    AudioCleanup.release(voice: made.voice, decoder: made.decoder, output: output)
                    return
                }
                voice = made.voice
                decoder = made.decoder
            } catch {
                if generation == seekGeneration { seeking = false }
                return
            }
        } else if output != nil, let comp = audioAsset {
            AudioCleanup.release(voice: voice, decoder: decoder, output: output)
            voice = -1
            decoder = nil
            do {
                let made = try await makeVoice(asset: comp, tracks: audioTracks, atMedia: m,
                                               speed: voiceSpeed, prefillSeconds: 0.3, ramp: 0.01)
                if generation != seekGeneration || state == .finished {
                    AudioCleanup.release(voice: made.voice, decoder: made.decoder, output: output)
                    return
                }
                voice = made.voice
                decoder = made.decoder
            } catch {
                if generation == seekGeneration { seeking = false }
                return
            }
        }

        if let p = player {
            _ = await p.seek(to: playerTime(m), toleranceBefore: .zero, toleranceAfter: .zero)
            if generation != seekGeneration || state == .finished { return }
        }
        seeking = false
        if shouldResume && state == .paused { resume() }
    }

    private func clampMedia(_ m: Double) -> Double {
        min(max(0, m), max(0, mediaDuration - 0.05))
    }

    // MARK: - Live speed

    /// Changes the playback speed while playing (or paused). Audio crossfades
    /// to a re-stretched stream at an exact host time; video changes rate at
    /// that same moment, so picture and sound stay locked.
    func setSpeed(_ newSpeed: Double) {
        guard !cue.isStream else { return }
        targetSpeed = min(max(newSpeed, 0.25), 4)
        startSpeedTaskIfNeeded()
    }

    private func startSpeedTaskIfNeeded() {
        guard speedTask == nil, targetSpeed != speed, state == .playing || state == .paused else { return }
        speedTask = Task { [weak self] in
            await self?.runSpeedChanges()
        }
    }

    private func runSpeedChanges() async {
        defer { speedTask = nil }
        var attempts = 0
        while targetSpeed != speed && attempts < 20 {
            attempts += 1
            switch state {
            case .playing:
                if seeking {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                } else {
                    await switchSpeedWhilePlaying(to: targetSpeed)
                }
            case .paused:
                await switchSpeedWhilePaused(to: targetSpeed)
            default:
                return
            }
        }
    }

    private func switchSpeedWhilePlaying(to s2: Double) async {
        let s1 = speed
        let generation = seekGeneration

        guard output != nil, audioAsset != nil else {
            // No audio voice: only the video (or the wall clock) changes rate.
            let host = HostClock.now() + HostClock.ticks(seconds: 0.03)
            let m = mediaTime + 0.03 * s1
            player?.setRate(Float(s2), time: cmTime(m), atHostTime: HostClock.cmTime(host))
            setAnchor(host: host, media: m, previousSpeed: s1)
            speed = s2
            return
        }

        guard let timeline = try? await CueTimeline.build(for: cue, audioSpeed: s2, includeVideo: false),
              let comp = timeline.audioAsset, state == .playing, generation == seekGeneration else {
            if state == .playing && generation == seekGeneration { targetSpeed = speed }
            return
        }
        let tracks = Array(timeline.audioTracks.prefix(Int(CM_MAX_TRACKS)))

        // Start the new stream a little ahead, then switch exactly when the
        // current stream reaches that point.
        let switchMedia = clampMedia(mediaTime + 0.35 * s1)
        let made: (voice: Int32, decoder: VoiceFeeder)
        do {
            made = try await makeVoice(asset: comp, tracks: tracks, atMedia: switchMedia,
                                       speed: s2, prefillSeconds: 0.25, ramp: 0.03)
        } catch {
            targetSpeed = speed
            return
        }
        guard state == .playing, generation == seekGeneration, let out = output else {
            AudioCleanup.release(voice: made.voice, decoder: made.decoder, output: output)
            return
        }

        let secondsUntilSwitch = max(0, (switchMedia - mediaTime) / s1)
        let host = HostClock.now() + HostClock.ticks(seconds: secondsUntilSwitch)
        releaseRetiring()
        let oldVoice = voice
        retiringVoice = voice
        retiringDecoder = decoder

        cm_voice_start(out.mixer, made.voice, host)
        if oldVoice >= 0 { cm_voice_stop_at(out.mixer, oldVoice, host, Int64(0.03 * out.sampleRate)) }
        player?.setRate(Float(s2), time: cmTime(switchMedia), atHostTime: HostClock.cmTime(host))

        voice = made.voice
        decoder = made.decoder
        voiceSpeed = s2
        audioAsset = comp
        audioTracks = tracks
        setAnchor(host: host, media: switchMedia, previousSpeed: s1)
        speed = s2

        // Free the old stream once its crossfade is over.
        let delay = UInt64((secondsUntilSwitch + 0.3) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.releaseRetiring(ifVoice: oldVoice)
        }
    }

    private func switchSpeedWhilePaused(to s2: Double) async {
        let generation = seekGeneration
        if output != nil, audioAsset != nil {
            guard let timeline = try? await CueTimeline.build(for: cue, audioSpeed: s2, includeVideo: false),
                  let comp = timeline.audioAsset, state == .paused, generation == seekGeneration else {
                if state == .paused && generation == seekGeneration { targetSpeed = speed }
                return
            }
            audioAsset = comp
            audioTracks = Array(timeline.audioTracks.prefix(Int(CM_MAX_TRACKS)))
            voiceSpeed = s2
            speed = s2
            await seek(toMedia: pausedMedia)   // rebuilds the voice at the new speed, stays paused
        } else {
            speed = s2
        }
    }

    // MARK: - Live changes

    /// Applies volume, routing and speed changes while playing.
    func update(cue newCue: Cue) {
        guard newCue.id == cue.id else { return }
        let routesChanged = newCue.routes != cue.routes
        // A stream whose languages changed needs new audio (another rendition).
        let languagesChanged = cue.isStream && newCue.audioTracks.map(\.language) != cue.audioTracks.map(\.language)
        cue.volumeDB = newCue.volumeDB
        cue.routes = newCue.routes
        cue.stopFade = newCue.stopFade
        cue.name = newCue.name
        cue.audioTracks = newCue.audioTracks
        cue.speed = newCue.speed
        if voice >= 0, let out = output {
            cm_voice_set_gain(out.mixer, voice, cue.linearGain)
            if routesChanged && !languagesChanged { applyRoutes(to: voice, trackCount: voiceTrackCount) }
        }
        if languagesChanged, let resolve = streamResolver, state == .playing || state == .paused {
            Task { [weak self] in
                guard let self, let plan = try? await resolve(self.cue) else { return }
                self.streamPlan = plan
                await self.seek(toMedia: self.mediaTime)      // rebuilds the voice with the new languages
            }
        }
        if !cue.isStream && min(max(newCue.speed, 0.25), 4) != targetSpeed { setSpeed(newCue.speed) }
    }

    /// Tracks of the current voice.
    private var voiceTrackCount: Int { streamPlan?.audio.count ?? audioTracks.count }

    private func applyRoutes(to v: Int32, trackCount: Int) {
        guard v >= 0, let out = output else { return }
        for t in 0..<trackCount {
            let chans = t < cue.routes.count ? cue.routes[t] : []
            let n = t < cue.audioTracks.count ? cue.audioTracks[t].channels : chans.count
            for c in 0..<min(n, Int(CM_MAX_TRACK_CH)) {
                let o = c < chans.count ? chans[c] : -1
                cm_voice_set_route(out.mixer, v, UInt32(t), UInt32(c), Int32(o))
            }
        }
    }

    // MARK: - Clock

    /// Position in media time (seconds of source material since the start point).
    var mediaTime: Double {
        switch state {
        case .preparing, .paused: return pausedMedia
        default: break
        }
        if seeking { return pausedMedia }
        let now = HostClock.now()
        if now < anchorHost {
            // Before a scheduled start or speed switch: extrapolate backwards.
            let ahead = Double(anchorHost - now) / HostClock.ticksPerSecond
            return max(0, anchorMedia - ahead * anchorPreviousSpeed)
        }
        if voice >= 0, let out = output {
            return Double(cm_voice_position(out.mixer, voice)) / out.sampleRate * voiceSpeed
        }
        if let p = player { return max(0, p.currentTime().seconds - playerOffset) }
        return anchorMedia + Double(now - anchorHost) / HostClock.ticksPerSecond * speed
    }

    /// Output seconds left until the cue ends.
    var remaining: Double { max(0, (mediaDuration - mediaTime) / speed) }
    /// Total output length at the current speed.
    var duration: Double { mediaDuration / speed }
    /// Output seconds since the start point at the current speed.
    var elapsed: Double { mediaTime / speed }

    /// Position in the source file (seconds), for the timeline display.
    var fileTime: Double { cue.fileTime(forMedia: mediaTime) }

    /// File time of the video frame on screen right now (falls back to the
    /// audio position for cues without video). Used for exact frame steps.
    var displayedFileTime: Double {
        if let p = player, state != .preparing, !seeking {
            let t = p.currentTime().seconds - playerOffset
            if t.isFinite { return cue.fileTime(forMedia: max(0, t)) }
        }
        return fileTime
    }

    /// Which loop pass is playing (0 for cues that don't loop).
    var loopPass: Int {
        let seg = cue.segmentDuration
        guard cue.endAction == .loop, seg > 0 else { return 0 }
        return Int(mediaTime / seg)
    }

    /// Host time at which the cue will end if nothing changes.
    var endHostTime: UInt64 { HostClock.now() + HostClock.ticks(seconds: remaining) }

    // MARK: - Per-frame update (called by the engine at 60 Hz)

    private var lastStreamLog: CFTimeInterval = 0
    private var lastResync: CFTimeInterval = 0

    /// Streams: if the video player stopped while the cue plays (e.g. after a
    /// network hiccup), start it again at the current position, in sync.
    private func keepStreamVideoRunning() {
        guard cue.isStream, state == .playing, !seeking, !videoEnded, let p = player,
              p.currentItem?.status == .readyToPlay, p.rate == 0,
              HostClock.now() > firstStartHost &+ HostClock.ticks(seconds: 1) else { return }
        let now = CACurrentMediaTime()
        guard now - lastResync > 2 else { return }
        lastResync = now
        let host = HostClock.now() + HostClock.ticks(seconds: 0.1)
        let m = mediaTime + 0.1
        p.setRate(1, time: playerTime(m), atHostTime: HostClock.cmTime(host))
        streamLog.notice("video stopped, restarted at media \(String(format: "%.2f", m), privacy: .public)")
    }

    /// Every 2 s while a stream plays: the video player's state, for diagnosing
    /// problems on other Macs (log show --predicate 'subsystem == "CueDeck"').
    private func logStreamState() {
        guard cue.isStream, let p = player, let item = p.currentItem else { return }
        let now = CACurrentMediaTime()
        guard now - lastStreamLog >= 2 else { return }
        lastStreamLog = now
        let loaded = item.loadedTimeRanges.map {
            String(format: "%.1f-%.1f", $0.timeRangeValue.start.seconds, ($0.timeRangeValue.start + $0.timeRangeValue.duration).seconds)
        }.joined(separator: ",")
        let ev = item.accessLog()?.events.last
        let layer = playerLayer.map { String(format: "layer opacity %.2f ready %d frame %.0fx%.0f",
                                             $0.presentation()?.opacity ?? $0.opacity, $0.isReadyForDisplay ? 1 : 0,
                                             $0.bounds.width, $0.bounds.height) } ?? "no layer"
        streamLog.notice("""
            \(self.cue.name, privacy: .public) state \(String(describing: self.state), privacy: .public)             media \(String(format: "%.2f", self.mediaTime), privacy: .public)             player \(String(format: "%.2f", p.currentTime().seconds), privacy: .public) rate \(p.rate, privacy: .public)             control \(p.timeControlStatus.rawValue, privacy: .public) wait \(p.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public)             item \(item.status.rawValue, privacy: .public) \(item.error?.localizedDescription ?? "", privacy: .public)             loaded \(loaded, privacy: .public) bitrate \(Int((ev?.indicatedBitrate ?? 0) / 1000), privacy: .public)k             observed \(Int((ev?.observedBitrate ?? 0) / 1000), privacy: .public)k stalls \(ev?.numberOfStalls ?? 0, privacy: .public)             dropped \(ev?.numberOfDroppedVideoFrames ?? 0, privacy: .public) \(layer, privacy: .public)
            """)
        for e in item.errorLog()?.events.suffix(2) ?? [] {
            streamLog.error("stream error \(e.errorStatusCode, privacy: .public) \(e.errorComment ?? "", privacy: .public)")
        }
    }

    func tick() {
        logStreamState()
        keepStreamVideoRunning()
        guard state == .playing || state == .stopping else { return }

        let started = HostClock.now() >= firstStartHost
        let elapsedOut = elapsed
        let remainingOut = remaining
        var stopProgress: Double = 0
        if state == .stopping {
            stopProgress = stopFade > 0 ? (CACurrentMediaTime() - stopStartedAt) / stopFade : 1
        }

        if let layer = playerLayer, state == .playing {
            // Fade out at the end: one animation over the remaining time.
            if started, !endFadeScheduled, cue.fadeOut > 0, cue.endAction != .loop,
               remainingOut > 0, remainingOut <= cue.fadeOut {
                endFadeScheduled = true
                animateOpacity(to: 0, over: remainingOut)
            }
            // Otherwise (after a pause or seek) set the opacity the fades call for.
            if CACurrentMediaTime() >= fadeAnimationEnd && !endFadeScheduled {
                var o = 1.0
                if cue.fadeIn > 0 { o = min(o, elapsedOut / cue.fadeIn) }
                if cue.fadeOut > 0 && cue.endAction != .loop { o = min(o, remainingOut / cue.fadeOut) }
                if !started { o = 0 }
                let opacity = Float(min(1, max(0, o)))
                if layer.opacity != opacity { setOpacity(opacity) }
            }
        }
        if seeking || speedTask != nil && HostClock.now() < anchorHost { return }

        let audioDone: Bool = {
            guard voice >= 0, let out = output else { return true }
            return cm_voice_state(out.mixer, voice) == CM_FINISHED
        }()

        if state == .stopping {
            if (stopProgress >= 1 && audioDone) || stopProgress >= 1.5 { finish() }
            return
        }

        let mediaDone: Bool
        if player != nil {
            mediaDone = videoEnded || mediaTime >= mediaDuration - 0.02 * speed
        } else if voice >= 0 {
            mediaDone = true
        } else {
            mediaDone = mediaTime >= mediaDuration
        }
        if audioDone && mediaDone {
            finishedNaturally = true
            finish()
        }
    }

    // MARK: - Teardown

    /// Stops everything now and releases all resources.
    func finish() {
        state = .finished
        guard !cleanedUp else { return }
        cleanedUp = true
        seekGeneration += 1
        speedTask?.cancel()

        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
        player?.rate = 0
        if let layer = playerLayer, layerAttached { video.detach(layer) }
        layerAttached = false
        playerLayer = nil
        player?.replaceCurrentItem(with: nil)
        player = nil

        AudioCleanup.release(voice: voice, decoder: decoder, output: output)
        decoder = nil
        voice = -1
        releaseRetiring()
    }
}
