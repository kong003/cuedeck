import AppKit
import AVFoundation
import CMixer
import Combine
import Foundation
import UniformTypeIdentifiers

/// One playing cue as shown in the transport bar.
struct NowPlaying: Equatable, Identifiable {
    var id: UUID          // session id
    var cueID: UUID
    var name: String
    var elapsed: Double
    var remaining: Double
    var progress: Double
    var speed: Double
    var paused: Bool
    var stopping: Bool
}

@MainActor
final class PlaybackEngine: NSObject, ObservableObject {
    static let shared = PlaybackEngine()

    // Show
    @Published var cues: [Cue] = [] {
        didSet {
            scheduleAutosave()
            recordUndo(oldValue)
        }
    }

    // Undo: snapshots of the cue list. Changes within `undoGrouping` seconds
    // (slider drags, typing) form one step.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [[Cue]] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [[Cue]] = [] { didSet { canRedo = !redoStack.isEmpty } }
    private var lastUndoRecord = Date.distantPast
    /// Set while the app itself changes the list (loading, undo, reading file info).
    private var suppressUndo = false
    private let undoGrouping: TimeInterval = 0.8
    private let undoLimit = 100
    /// The cue GO plays next and the inspector shows.
    @Published var selection: UUID? {
        didSet {
            syncSetFromSelection()
            // Load a BCC Media cue ahead, so GO starts it at once.
            if let id = selection, let cue = findCue(id), cue.isStream { preloadStream(cue) } else { discardPreload() }
        }
    }
    /// All selected cues in the list (Shift-click for a range, ⌘-click to add).
    @Published var selectedIDs: Set<UUID> = [] { didSet { syncSelectionFromSet() } }
    private var syncingSelection = false
    @Published private(set) var showURL: URL?

    // Outputs
    @Published private(set) var devices: [AudioDevice] = []
    @Published var deviceUID: String = "" {
        didSet {
            guard deviceUID != oldValue else { return }
            UserDefaults.standard.set(deviceUID, forKey: Keys.device)
            loadOutputNames()
            rebuildOutput()
        }
    }
    @Published private(set) var screens: [ScreenInfo] = []
    @Published var screenID: CGDirectDisplayID = 0 {
        didSet {
            guard screenID != oldValue else { return }
            UserDefaults.standard.set(Int(screenID), forKey: Keys.screen)
            if let s = screens.first(where: { $0.id == screenID }) {
                UserDefaults.standard.set(s.name, forKey: Keys.screenName)
            }
            video.setDisplay(screenID)
        }
    }
    @Published var masterDB: Double = 0 {
        didSet {
            UserDefaults.standard.set(masterDB, forKey: Keys.master)
            output?.setMasterGain(Self.gain(masterDB))
        }
    }
    /// Show mode: minimal window for running the show. Cues can't be deleted,
    /// moved or trimmed by accident.
    @Published var showMode = false {
        didSet { UserDefaults.standard.set(showMode, forKey: Keys.showMode) }
    }
    /// Default routing for new cues, per stream: first output (0 based) or a
    /// `RoutingDefault` value. Set in Settings.
    @Published var defaultRouting: [Int] = [] {
        didSet { UserDefaults.standard.set(defaultRouting, forKey: Keys.defaultRouting) }
    }
    /// Custom names of the output channels of the current device ("" = default).
    @Published private(set) var outputNames: [String] = []

    // Status
    @Published private(set) var outputStatus = ""
    @Published private(set) var outputChannels = 0
    @Published private(set) var playing: [NowPlaying] = []
    @Published private(set) var activeCueIDs: Set<UUID> = []
    /// Current file position (seconds) of every playing or paused cue.
    @Published private(set) var playheads: [UUID: Double] = [:]
    /// Where a cue that isn't playing will start (file seconds), set by clicking its timeline.
    @Published private(set) var pendingStarts: [UUID: Double] = [:]
    @Published private(set) var busyMessage: String?
    @Published var message: String?

    let video = VideoOutput()
    /// Subtitles to CasparCG (Settings › Subtitles).
    let caspar = CasparOutput()
    /// BCC Media sign-in (File › Add BCC Media Link…, Settings › BCC Media).
    let bcc = BCCMediaAccount()
    /// Shows the "Add BCC Media Link" sheet.
    @Published var showBCCSheet = false
    /// Stream links of BCC Media episodes, by episode id, until they expire.
    private var streamMasters: [String: (url: URL, master: HLSMaster, expires: Date)] = [:]
    /// The next BCC Media cue, loaded ahead: its first audio segments are in
    /// StreamCache and its video player is buffered at the start position.
    private var preload: (cueID: UUID, fileTime: Double, player: AVPlayer?)?
    private var preloadTask: Task<Void, Never>?
    /// Draw subtitles over the video output (for setups without CasparCG).
    @Published var subtitlesOnVideo: Bool = UserDefaults.standard.bool(forKey: "subtitlesOnVideo") {
        didSet { UserDefaults.standard.set(subtitlesOnVideo, forKey: "subtitlesOnVideo") }
    }
    /// Subtitles read from files, by "path|trackID".
    private var subtitleCache: [String: [SubtitleEntry]] = [:]
    private var subtitlesLoading: Set<String> = []
    private var output: AudioOutput?
    private var sessions: [PlaybackSession] = []
    private var timer: Timer?
    private var tickCount = 0
    private var removeDeviceObserver: (() -> Void)?
    private var autosaveWork: DispatchWorkItem?

    private enum Keys {
        static let device = "audioDeviceUID"
        static let screen = "videoDisplayID"
        static let screenName = "videoDisplayName"
        static let master = "masterDB"
        static let defaultRouting = "defaultRouting"
        static let showMode = "showMode"
        static func outputNames(_ uid: String) -> String { "outputNames.\(uid)" }
    }

    static func gain(_ db: Double) -> Float { db <= -60 ? 0 : Float(pow(10.0, db / 20.0)) }

    /// Channel count offered in routing menus.
    var routingChannels: Int {
        if outputChannels > 0 { return outputChannels }
        return devices.first(where: { $0.uid == deviceUID })?.outputChannels ?? 64
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        masterDB = d.object(forKey: Keys.master) as? Double ?? 0
        defaultRouting = d.array(forKey: Keys.defaultRouting) as? [Int] ?? []
        showMode = d.bool(forKey: Keys.showMode)

        refreshScreens()
        let savedScreen = CGDirectDisplayID(d.integer(forKey: Keys.screen))
        let savedName = d.string(forKey: Keys.screenName)
        if let s = screens.first(where: { $0.id == savedScreen }) ?? screens.first(where: { $0.name == savedName }) {
            screenID = s.id
        } else {
            screenID = screens.first(where: { !$0.isMain })?.id ?? screens.first?.id ?? 0
        }
        video.setDisplay(screenID)

        devices = CoreAudioDevices.allOutputDevices()
        if let saved = d.string(forKey: Keys.device), !saved.isEmpty {
            deviceUID = saved
        } else {
            deviceUID = Self.preferredDevice(in: devices)?.uid ?? ""
        }
        loadOutputNames()
        if output == nil { rebuildOutput() }

        removeDeviceObserver = CoreAudioDevices.observeChanges { [weak self] in
            guard let engine = self else { return }
            Task { @MainActor in engine.refreshDevices() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        loadAutosave()

        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tickTimer),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func preferredDevice(in devices: [AudioDevice]) -> AudioDevice? {
        if let dante = devices.first(where: { $0.name.localizedCaseInsensitiveContains("dante") }) { return dante }
        if let id = CoreAudioDevices.defaultOutputDeviceID() { return devices.first { $0.id == id } }
        return devices.first
    }

    // MARK: - Devices, screens, output names

    func refreshDevices() {
        devices = CoreAudioDevices.allOutputDevices()
        let current = devices.first { $0.uid == deviceUID }
        if let out = output {
            // Device gone or reconfigured (e.g. Dante channel count or rate changed)?
            if current == nil || current!.id != out.device.id ||
                current!.outputChannels != out.device.outputChannels ||
                current!.sampleRate != out.device.sampleRate {
                rebuildOutput()
            }
        } else if current != nil {
            rebuildOutput()
        }
    }

    @objc private func screensDidChange() {
        refreshScreens()
        video.screensChanged()
    }

    private func refreshScreens() {
        screens = ScreenInfo.all()
    }

    private func rebuildOutput() {
        if !sessions.isEmpty {
            stopAll(fade: false)
            message = "Playback stopped because the audio output changed."
        }
        if let old = output {
            output = nil
            AudioCleanup.queue.async { old.dispose() }
        }
        outputChannels = 0
        guard let device = devices.first(where: { $0.uid == deviceUID }) else {
            outputStatus = deviceUID.isEmpty ? "No audio device selected" : "Audio device not available"
            return
        }
        do {
            let out = try AudioOutput(device: device)
            out.setMasterGain(Self.gain(masterDB))
            output = out
            outputChannels = out.channels
            outputStatus = "\(device.name) · \(out.channels) ch · \(String(format: "%.1f", out.sampleRate / 1000)) kHz"
        } catch {
            outputStatus = error.localizedDescription
        }
    }

    private func loadOutputNames() {
        outputNames = UserDefaults.standard.stringArray(forKey: Keys.outputNames(deviceUID)) ?? []
    }

    /// "3 · FOH L" if named, else "Output 3". `index` is 0 based.
    func outputName(_ index: Int) -> String {
        if index < outputNames.count {
            let n = outputNames[index].trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return "\(index + 1) · \(n)" }
        }
        return "Output \(index + 1)"
    }

    func customOutputName(_ index: Int) -> String {
        index < outputNames.count ? outputNames[index] : ""
    }

    func setOutputName(_ index: Int, _ name: String) {
        var names = outputNames
        while names.count <= index { names.append("") }
        names[index] = name
        while let last = names.last, last.isEmpty { names.removeLast() }
        outputNames = names
        UserDefaults.standard.set(names, forKey: Keys.outputNames(deviceUID))
    }

    /// Label for a block of consecutive outputs, e.g. "Outputs 3–4" or "Output 5 · Sub".
    func outputBlockName(start: Int, count: Int) -> String {
        if count <= 1 { return outputName(start) }
        let names = (start..<(start + count)).map { customOutputName($0).trimmingCharacters(in: .whitespaces) }
        let base = "Outputs \(start + 1)–\(start + count)"
        let named = names.filter { !$0.isEmpty }
        return named.isEmpty ? base : "\(base) · \(named.joined(separator: "/"))"
    }

    // MARK: - Cue list

    var selectedIndex: Int? {
        guard let s = selection else { return nil }
        return cues.firstIndex { $0.id == s }
    }

    func findCue(_ id: UUID) -> Cue? { cues.first { $0.id == id } }

    // MARK: - Undo

    private func recordUndo(_ old: [Cue]) {
        guard !suppressUndo, old != cues else { return }
        let now = Date()
        if now.timeIntervalSince(lastUndoRecord) > undoGrouping {
            undoStack.append(old)
            if undoStack.count > undoLimit { undoStack.removeFirst() }
        }
        lastUndoRecord = now
        redoStack.removeAll()
    }

    /// Changes the list without creating an undo step.
    private func withoutUndo(_ change: () -> Void) {
        suppressUndo = true
        change()
        suppressUndo = false
    }

    private func clearUndo() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func undo() {
        guard !showMode, let previous = undoStack.popLast() else { return }
        redoStack.append(cues)
        restore(previous)
    }

    func redo() {
        guard !showMode, let next = redoStack.popLast() else { return }
        undoStack.append(cues)
        restore(next)
    }

    private func restore(_ list: [Cue]) {
        withoutUndo { cues = list }
        lastUndoRecord = .distantPast
        // Playing cues take over restored volume, speed and routing.
        for s in sessions where s.state != .finished {
            if let c = findCue(s.cue.id) { s.update(cue: c) }
        }
        if let sel = selection, findCue(sel) == nil { selection = cues.first?.id }
    }

    /// Called by the inspector; applies volume, routing and speed live to a playing cue.
    func updateCue(_ edited: Cue) {
        let cue = edited.sanitized()
        guard let i = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        if cues[i] != cue { cues[i] = cue }
        for s in sessions where s.cue.id == cue.id && s.state != .finished { s.update(cue: cue) }
    }

    /// Adds a BCC Media episode (link from app.bcc.media) as a cue that plays
    /// from the internet, with all its audio languages as streams and its subtitles.
    func addBCCEpisode(link: String, at index: Int? = nil) async throws {
        guard let id = BCCMedia.episodeID(from: link) else {
            throw BCCMedia.APIError(message: "This is not a link to a BCC Media episode (app.bcc.media/episode/…).")
        }
        let token = try await bcc.accessToken()
        let episode = try await BCCMedia.episode(id: id, token: token)
        let master = try await HLSMaster.load(episode.streamURL)

        var cue = Cue(url: BCCMedia.link(forEpisode: episode.id))
        cue.name = episode.title
        cue.bccEpisodeID = episode.id
        cue.duration = episode.duration
        if let best = master.variants.max(by: { $0.height < $1.height }) {
            cue.hasVideo = true
            cue.videoSize = best.width > 0 ? "\(best.width)×\(best.height)" : "Video"
            cue.frameRate = best.frameRate
            if best.frameRate > 0 { cue.videoSize += String(format: " · %g fps", (best.frameRate * 100).rounded() / 100) }
        }
        cue.streamLanguages = master.audio.map { StreamLanguage(language: $0.language, name: $0.name, channels: $0.channels) }
        // Two streams by default: German and Norwegian (only one of them if the
        // other is missing); without either, the episode's default language.
        var picked = [cue.streamLanguages.first(where: \.isGerman), cue.streamLanguages.first(where: \.isNorwegian)]
            .compactMap { $0 }
        if picked.isEmpty {
            let fallback = master.audio.firstIndex(where: \.isDefault) ?? 0
            if fallback < cue.streamLanguages.count { picked = [cue.streamLanguages[fallback]] }
        }
        cue.audioTracks = picked.enumerated().map { Self.streamSlot($0, $1) }
        cue.subtitleTracks = master.subtitles.enumerated().map { i, r in
            SubtitleTrackInfo(index: i, trackID: Int32(i), language: r.language, fileName: r.name)
        }
        cue.normalizeRoutes(outputChannels: routingChannels, defaults: defaultRouting)
        if let index { cues.insert(cue, at: min(max(index, 0), cues.count)) } else { cues.append(cue) }
        selection = cue.id          // also loads it ahead
    }

    /// Loads the start of a BCC Media cue ahead: audio of its languages into
    /// StreamCache, and a video player buffered at the start (not on screen).
    func preloadStream(_ cue: Cue) {
        let fileTime = pendingStarts[cue.id] ?? cue.segmentStart
        if let p = preload, p.cueID == cue.id, abs(p.fileTime - fileTime) < 0.05 { return }
        discardPreload()
        preload = (cue.id, fileTime, nil)
        preloadTask = Task { [weak self] in
            guard let self, let plan = try? await self.streamPlan(for: cue), !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for url in plan.audio {
                    group.addTask { await StreamAudioTrack.prefetch(playlistURL: url, start: fileTime) }
                }
            }
            guard cue.playsVideo, !Task.isCancelled, self.preload?.cueID == cue.id else { return }
            let item = AVPlayerItem(url: plan.masterURL)
            item.preferredForwardBufferDuration = 6
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            player.isMuted = true
            let deadline = Date().addingTimeInterval(20)
            while item.status == .unknown && Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard item.status == .readyToPlay, !Task.isCancelled, self.preload?.cueID == cue.id else { return }
            _ = await player.seek(to: CMTime(seconds: fileTime, preferredTimescale: 48000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            _ = await player.preroll(atRate: 1)
            if !Task.isCancelled, self.preload?.cueID == cue.id {
                self.preload = (cue.id, fileTime, player)
            }
        }
    }

    private func discardPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        if let p = preload?.player {
            p.cancelPendingPrerolls()
            p.replaceCurrentItem(with: nil)
        }
        preload = nil
    }

    /// The buffered player for `cue` starting at `fileTime`, if it was loaded ahead.
    private func takePreparedPlayer(for cue: Cue, fileTime: Double) -> AVPlayer? {
        guard let p = preload, p.cueID == cue.id, abs(p.fileTime - fileTime) < 0.05, let player = p.player else { return nil }
        preload = nil
        preloadTask = nil
        return player
    }

    /// The current stream links for a BCC Media cue: the master playlist and
    /// one audio playlist per cue stream (matched by language).
    func streamPlan(for cue: Cue) async throws -> StreamPlan {
        guard let id = cue.bccEpisodeID else { throw StreamError("\(cue.name) is not a BCC Media cue.") }
        var entry = streamMasters[id]
        if entry == nil || entry!.expires < Date().addingTimeInterval(600) {
            guard bcc.isSignedIn else {
                throw StreamError("Sign in to BCC Media to play \(cue.name) (File › Add BCC Media Link…).")
            }
            let token = try await bcc.accessToken()
            let episode = try await BCCMedia.episode(id: id, token: token)
            let master = try await HLSMaster.load(episode.streamURL)
            entry = (episode.streamURL, master, episode.expiresAt ?? Date().addingTimeInterval(3600))
            streamMasters[id] = entry
        }
        guard let entry else { throw StreamError("No stream for \(cue.name).") }
        let audio = try cue.audioTracks.map { t -> URL in
            if let r = entry.master.audio.first(where: { $0.language == t.language && !t.language.isEmpty }) { return r.url }
            if t.language.isEmpty, t.index < entry.master.audio.count { return entry.master.audio[t.index].url }
            throw StreamError("\(cue.name): the language \(t.fileName) is no longer offered.")
        }
        return StreamPlan(masterURL: entry.url, audio: audio, subtitles: entry.master.subtitles)
    }

    private static func streamSlot(_ index: Int, _ l: StreamLanguage) -> AudioTrackInfo {
        var info = AudioTrackInfo(index: index, channels: l.channels,
                                  label: "Stream \(index + 1) · \(l.channels) ch · \(l.language)")
        info.fileName = l.name
        info.language = l.language
        return info
    }

    /// BCC Media cue: which language a stream plays. Keeps its outputs.
    func setStreamLanguage(cueID: UUID, stream: Int, language: String) {
        guard !showMode, var cue = findCue(cueID), stream < cue.audioTracks.count,
              let l = cue.streamLanguages.first(where: { $0.language == language }) else { return }
        let start = cue.blockStart(ofTrack: stream) ?? cue.routes[stream].first ?? -1
        cue.audioTracks[stream] = Self.streamSlot(stream, l)
        cue.setBlock(track: stream, start: start, outputChannels: routingChannels)
        updateCue(cue)
    }

    /// BCC Media cue: one more stream, with the next language not in use yet,
    /// on the outputs after the ones already used.
    func addStream(cueID: UUID) {
        guard !showMode, var cue = findCue(cueID), cue.audioTracks.count < min(Int(CM_MAX_TRACKS), cue.streamLanguages.count),
              let l = cue.streamLanguages.first(where: { l in !cue.audioTracks.contains { $0.language == l.language } })
        else { return }
        let index = cue.audioTracks.count
        cue.audioTracks.append(Self.streamSlot(index, l))
        while cue.routes.count < index + 1 { cue.routes.append([]) }
        let next = (cue.routes.flatMap { $0 }.max() ?? -1) + 1
        cue.setBlock(track: index, start: next + l.channels <= routingChannels ? next : -1, outputChannels: routingChannels)
        updateCue(cue)
    }

    func removeStream(cueID: UUID, stream: Int) {
        guard !showMode, var cue = findCue(cueID), cue.audioTracks.count > 1, stream < cue.audioTracks.count else { return }
        cue.audioTracks.remove(at: stream)
        if stream < cue.routes.count { cue.routes.remove(at: stream) }
        cue.audioTracks = cue.audioTracks.enumerated().map { i, t in
            var t = t
            t.index = i
            t.label = "Stream \(i + 1) · \(t.channels) ch · \(t.language)"
            return t
        }
        updateCue(cue)
    }

    /// Adds files to the list, at `index` (where they were dropped) or at the end.
    func addFiles(_ urls: [URL], selectAdded: Bool = false, at index: Int? = nil) {
        Task {
            var insertAt = index
            for url in urls {
                if let id = await addFile(url, at: insertAt) {
                    if selectAdded { selection = id }
                    insertAt = insertAt.map { $0 + 1 }
                }
            }
        }
    }

    /// Files opened from Finder (double-click, Open With, Dock icon).
    func openFiles(_ urls: [URL]) {
        var media: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "cuedeck" {
                openShow(at: url)
            } else if let existing = cues.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                selection = existing.id
            } else {
                media.append(url)
            }
        }
        if !media.isEmpty { addFiles(media, selectAdded: true) }
    }

    @discardableResult
    private func addFile(_ original: URL, at index: Int? = nil) async -> UUID? {
        var url = original
        let ext = url.pathExtension.lowercased()
        if MediaInspector.needsConversion.contains(ext) {
            guard let converted = await convert(url) else { return nil }
            url = converted
        }
        var cue = Cue(url: url)
        do {
            try await MediaInspector.inspect(&cue)
        } catch {
            // Not playable natively: try converting once.
            guard url == original, let converted = await convert(url) else {
                if url == original && !Converter.isAvailable {
                    message = "\(error.localizedDescription) Install ffmpeg (brew install ffmpeg) to convert it."
                } else if url != original {
                    message = error.localizedDescription
                }
                return nil
            }
            cue = Cue(url: converted)
            do { try await MediaInspector.inspect(&cue) } catch {
                message = error.localizedDescription
                return nil
            }
        }
        cue.normalizeRoutes(outputChannels: routingChannels, defaults: defaultRouting)
        if let index { cues.insert(cue, at: min(max(index, 0), cues.count)) } else { cues.append(cue) }
        if selection == nil { selection = cue.id }
        return cue.id
    }

    private func convert(_ url: URL) async -> URL? {
        guard Converter.isAvailable else {
            message = "\(url.lastPathComponent) needs converting, but ffmpeg is not installed (brew install ffmpeg)."
            return nil
        }
        busyMessage = "Converting \(url.lastPathComponent) to ProRes…"
        defer { busyMessage = nil }
        do {
            return try await Converter.convert(url)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Keeps `selection` inside the multi-selection.
    private func syncSelectionFromSet() {
        guard !syncingSelection else { return }
        syncingSelection = true
        defer { syncingSelection = false }
        if selectedIDs.count <= 1 {
            selection = selectedIDs.first
        } else if selection == nil || !selectedIDs.contains(selection!) {
            selection = cues.first { selectedIDs.contains($0.id) }?.id
        }
    }

    /// When the app moves the selection (GO, adding files), select just that cue.
    private func syncSetFromSelection() {
        guard !syncingSelection else { return }
        syncingSelection = true
        defer { syncingSelection = false }
        let wanted: Set<UUID> = selection.map { [$0] } ?? []
        if selectedIDs != wanted { selectedIDs = wanted }
    }

    /// Deletes every selected cue (Backspace).
    func removeSelected() {
        var ids = selectedIDs
        if ids.isEmpty, let s = selection { ids = [s] }
        removeCues(ids)
    }

    /// Deletes cues from the list; playing ones stop immediately.
    func removeCues(_ ids: Set<UUID>) {
        guard !showMode, !ids.isEmpty else { return }
        let lastIndex = cues.lastIndex { ids.contains($0.id) } ?? 0
        let removedBefore = cues[..<min(lastIndex + 1, cues.count)].filter { ids.contains($0.id) }.count
        for s in sessions where ids.contains(s.cue.id) { s.stop(fade: 0) }
        for id in ids { pendingStarts[id] = nil }
        cues.removeAll { ids.contains($0.id) }
        // Select the cue that followed the last deleted one.
        let next = lastIndex + 1 - removedBefore
        selection = cues.isEmpty ? nil : cues[min(max(next, 0), cues.count - 1)].id
    }

    func moveCues(from: IndexSet, to: Int) {
        guard !showMode else { return }
        cues.move(fromOffsets: from, toOffset: to)
    }

    func resetRoutes(for id: UUID) {
        guard var cue = findCue(id) else { return }
        cue.assignDefaultRoutes(outputChannels: routingChannels, defaults: defaultRouting)
        updateCue(cue)
    }

    /// Default routing of one stream (Settings).
    func defaultRouting(forStream t: Int) -> Int {
        t < defaultRouting.count ? defaultRouting[t] : RoutingDefault.automatic
    }

    func setDefaultRouting(forStream t: Int, to value: Int) {
        var list = defaultRouting
        while list.count <= t { list.append(RoutingDefault.automatic) }
        list[t] = value
        while list.last == RoutingDefault.automatic { list.removeLast() }
        defaultRouting = list
    }

    /// Replaces the routing of every cue with the default routing.
    func applyDefaultRoutingToAllCues() {
        for cue in cues { resetRoutes(for: cue.id) }
    }

    /// Routes a whole audio track (stream) to consecutive outputs, -1 = off.
    func setTrackBlock(cueID: UUID, track: Int, start: Int) {
        guard !showMode, var cue = findCue(cueID) else { return }
        cue.setBlock(track: track, start: start, outputChannels: routingChannels)
        updateCue(cue)
    }

    /// Applies the next time the cue starts.
    func setAudioOnly(_ id: UUID, _ on: Bool) {
        guard !showMode, var cue = findCue(id) else { return }
        cue.audioOnly = on
        updateCue(cue)
    }

    func setAutoStart(_ id: UUID, _ mode: AutoStart) {
        guard !showMode, var cue = findCue(id) else { return }
        cue.autoStart = mode
        updateCue(cue)
    }

    func reinspect(_ id: UUID) {
        guard let original = findCue(id), !original.isStream else { return }
        Task {
            var cue = original
            do {
                try await MediaInspector.inspect(&cue)
                cue.adoptNames(from: original.audioTracks)
                cue.normalizeRoutes(outputChannels: routingChannels, defaults: defaultRouting)
            } catch {
                message = error.localizedDescription
            }
            updateCue(cue)
        }
    }

    // MARK: - Transport

    /// Plays the selected cue (and the cues set to start with it) and selects
    /// the next cue that waits for GO.
    /// GO fades out whatever is playing; GO + KEEP (`keepOthers`) leaves it running.
    func go(keepOthers: Bool = false) {
        guard !cues.isEmpty else { return }
        let index = selectedIndex ?? 0
        start(group(from: index), at: nil, stopOthers: !keepOthers)
        if let next = nextManualIndex(after: index) { selection = cues[next].id }
    }

    /// Plays a cue now. `keepOthers` leaves the other cues playing.
    func play(_ id: UUID, keepOthers: Bool = false) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        start(group(from: i), at: nil, stopOthers: !keepOthers)
    }

    /// The cue at `index` plus the cues below it set to start together with it.
    private func group(from index: Int) -> [Cue] {
        var end = index + 1
        while end < cues.count && cues[end].autoStart == .withPrevious { end += 1 }
        return Array(cues[index..<end])
    }

    /// The first cue after `index` that waits for GO (cues that start by themselves are skipped).
    private func nextManualIndex(after index: Int) -> Int? {
        cues.indices.first { $0 > index && cues[$0].autoStart == .off }
    }

    func stopCue(_ id: UUID) {
        for s in sessions where s.cue.id == id { s.stop(fade: s.cue.stopFade) }
    }

    func togglePause(_ id: UUID) {
        let mine = sessions.filter { $0.cue.id == id }
        if mine.contains(where: { $0.state == .playing }) {
            mine.forEach { $0.pause() }
        } else {
            mine.forEach { $0.resume() }
        }
    }

    /// Starts a group of cues at the same host time, once all of them are prepared.
    private func start(_ group: [Cue], at hostTime: UInt64?, stopOthers: Bool) {
        var ready: [(session: PlaybackSession, media: Double)] = []
        for cue in group {
            if !cue.isStream && (cue.missing || !FileManager.default.fileExists(atPath: cue.url.path)) {
                message = "File not found: \(cue.url.path)"
                continue
            }
            if output == nil && !cue.audioTracks.isEmpty {
                message = "No audio output: \(outputStatus). \(cue.name) plays without sound."
            }
            let startMedia = pendingStarts[cue.id].map { cue.mediaTime(forFile: min(cue.seekTarget($0), cue.segmentEnd)) } ?? 0
            pendingStarts[cue.id] = nil
            let resolver: ((Cue) async throws -> StreamPlan)? = cue.isStream
                ? { [weak self] c in
                    guard let self else { throw StreamError("CueDeck is closing.") }
                    return try await self.streamPlan(for: c)
                }
                : nil
            let prepared = cue.isStream ? takePreparedPlayer(for: cue, fileTime: cue.segmentStart + startMedia) : nil
            ready.append((PlaybackSession(cue: cue, output: output, video: video,
                                          streamResolver: resolver, preparedPlayer: prepared), startMedia))
        }
        guard !ready.isEmpty else { return }
        let previous = sessions.filter { $0.isActive }
        sessions.append(contentsOf: ready.map(\.session))
        Task {
            var prepared: [PlaybackSession] = []
            for (session, media) in ready {
                do {
                    try await session.prepare(fromMedia: media)
                    if session.isCancelled { session.finish() } else { prepared.append(session) }
                } catch {
                    session.finish()
                    message = "\(session.cue.name): \(error.localizedDescription)"
                }
            }
            guard !prepared.isEmpty else { return }
            if stopOthers {
                for p in previous where p.state != .preparing { p.stop(fade: p.cue.stopFade) }
                for p in previous where p.state == .preparing { p.stop(fade: 0) }
            }
            let soon = HostClock.now() + HostClock.ticks(seconds: 0.06)
            let at = max(hostTime ?? 0, soon)
            for s in prepared { s.start(at: at) }
        }
    }

    var isAnythingPlaying: Bool { sessions.contains { $0.state == .playing } }

    func togglePause() {
        if sessions.contains(where: { $0.state == .playing }) {
            sessions.forEach { $0.pause() }
        } else {
            sessions.forEach { $0.resume() }
        }
    }

    /// Stops all cues, with each cue's stop fade unless `fade` is false.
    func stopAll(fade: Bool = true) {
        for s in sessions { s.stop(fade: fade ? s.cue.stopFade : 0) }
    }

    /// Immediate stop of everything and close the video output.
    func panic() {
        stopAll(fade: false)
        video.close()
    }

    // MARK: - Timeline (positions are seconds in the source file)

    private func activeSession(for id: UUID) -> PlaybackSession? {
        sessions.last { $0.cue.id == id && ($0.state == .playing || $0.state == .paused) }
    }

    /// Where the timeline's playhead is for a cue: live position if playing,
    /// otherwise the chosen start position (nil = start point).
    func playhead(for id: UUID) -> Double? {
        playheads[id] ?? pendingStarts[id]
    }

    func isPlaying(_ id: UUID) -> Bool { activeSession(for: id) != nil }

    /// While dragging on a timeline.
    func scrub(_ id: UUID, toFile seconds: Double) {
        if let s = activeSession(for: id) {
            // The running cue keeps the start/end points it was started with.
            let sc = s.cue
            let f = min(max(seconds, sc.segmentStart), sc.segmentEnd)
            s.scrub(toMedia: sc.mediaTime(forFile: f, pass: s.loopPass))
            playheads[id] = f
        } else if let cue = findCue(id) {
            pendingStarts[id] = min(max(seconds, cue.segmentStart), cue.segmentEnd)
        }
    }

    /// Click on a timeline or a typed timecode. Lands on the
    /// video frame that contains `seconds`.
    func seek(_ id: UUID, toFile seconds: Double) {
        if let s = activeSession(for: id) {
            let sc = s.cue
            let f = min(max(seconds, sc.segmentStart), sc.segmentEnd)
            playheads[id] = f
            let m = sc.mediaTime(forFile: min(sc.seekTarget(f), sc.segmentEnd), pass: s.loopPass)
            Task { await s.seek(toMedia: m) }
        } else if let cue = findCue(id) {
            pendingStarts[id] = min(max(seconds, cue.segmentStart), cue.segmentEnd)
            if cue.isStream && selection == id { preloadStream(cue) }     // load ahead from the new start
        }
    }

    func nudge(_ id: UUID, by delta: Double) {
        seek(id, toFile: livePlayhead(id) + delta)
    }

    /// Exact current position: the frame on screen for a playing cue,
    /// otherwise the chosen start position.
    func livePlayhead(_ id: UUID) -> Double {
        if let s = activeSession(for: id) { return s.displayedFileTime }
        return pendingStarts[id] ?? findCue(id)?.segmentStart ?? 0
    }

    /// Steps one video frame forward or back (pauses a playing cue first).
    func stepFrame(_ id: UUID, by frames: Int) {
        guard let cue = findCue(id) else { return }
        if let s = activeSession(for: id), s.state == .playing { s.pause() }
        let fps = cue.frameRate > 0 ? cue.frameRate : 25
        let current = cue.frameStart(livePlayhead(id))
        seek(id, toFile: current + Double(frames) / fps)
    }

    /// Sets the start point (file seconds). Applies the next time the cue starts.
    func setStartPoint(_ id: UUID, to seconds: Double) {
        guard !showMode, var cue = findCue(id) else { return }
        let end = cue.segmentEnd
        cue.inPoint = min(max(0, cue.frameStart(seconds)), max(0, end - 0.1))
        updateCue(cue)
        if let p = pendingStarts[id], p < cue.inPoint { pendingStarts[id] = nil }
    }

    /// Sets the end point (file seconds); at or past the file's end clears it.
    func setEndPoint(_ id: UUID, to seconds: Double) {
        guard !showMode, var cue = findCue(id) else { return }
        let t = cue.frameStart(seconds)
        if t >= cue.duration - 0.01 {
            cue.outPoint = 0
        } else {
            cue.outPoint = max(t, cue.segmentStart + 0.1)
        }
        updateCue(cue)
        if let p = pendingStarts[id], p > cue.segmentEnd { pendingStarts[id] = nil }
    }

    func clearStartEnd(_ id: UUID) {
        guard !showMode, var cue = findCue(id) else { return }
        cue.inPoint = 0
        cue.outPoint = 0
        updateCue(cue)
    }

    func clearPendingStart(_ id: UUID) { pendingStarts[id] = nil }

    /// Speed buttons in the transport bar; applies live.
    func changeSpeed(_ id: UUID, to speed: Double) {
        guard var cue = findCue(id) else { return }
        cue.speed = (speed * 100).rounded() / 100
        updateCue(cue)
    }

    // MARK: - Timer

    @objc private func tickTimer() {
        for s in sessions { s.tick() }

        // Autostart "at end of previous cue": schedule the next cue (and the cues
        // that start with it) to start exactly when this one ends.
        for s in sessions where s.state == .playing && s.cue.endAction != .loop && !s.followTriggered {
            guard s.remaining < 1.5, let i = cues.firstIndex(where: { $0.id == s.cue.id }),
                  i + 1 < cues.count, cues[i + 1].autoStart == .afterPrevious else { continue }
            s.followTriggered = true
            let followers = group(from: i + 1)
            start(followers, at: s.endHostTime, stopOthers: false)
            // If GO would play one of these cues next, move on to the next manual cue.
            if let sel = selection, followers.contains(where: { $0.id == sel }) {
                selection = nextManualIndex(after: i + followers.count).map { cues[$0].id } ?? sel
            }
        }
        sessions.removeAll { $0.isDone }
        updateSubtitles()

        tickCount += 1
        if tickCount % 4 == 0 { publishStatus() }
    }

    // MARK: - Subtitles

    /// Sends the subtitle of the newest playing cue that has subtitles.
    private func updateSubtitles() {
        guard caspar.enabled || subtitlesOnVideo else {
            video.setSubtitle(nil)
            return
        }
        let candidate = sessions.last { s in
            (s.state == .preparing || s.state == .playing || s.state == .paused)
                && findCue(s.cue.id)?.selectedSubtitles != nil
        }
        var lines: [String]?
        var onVideo = false
        if let s = candidate, let cue = findCue(s.cue.id), !cue.isStream, let track = cue.selectedSubtitles {
            onVideo = cue.playsVideo
            let key = "\(cue.url.path)|\(track.trackID)"
            if let entries = subtitleCache[key], s.state != .preparing {
                lines = SubtitleReader.entry(at: s.displayedFileTime, in: entries)?.lines ?? []
            } else {
                loadSubtitles(url: cue.url, trackID: track.trackID, key: key)
                lines = []             // CasparCG loads the template now, ready for the first line
            }
        }
        if caspar.enabled { caspar.update(lines) }
        video.setSubtitle(subtitlesOnVideo && onVideo ? lines : nil)
    }

    private func loadSubtitles(url: URL, trackID: Int32, key: String) {
        guard subtitleCache[key] == nil, !subtitlesLoading.contains(key) else { return }
        subtitlesLoading.insert(key)
        Task {
            let entries = await SubtitleReader.load(url: url, trackID: trackID)
            subtitleCache[key] = entries
            subtitlesLoading.remove(key)
        }
    }

    private func publishStatus() {
        let visible = sessions.filter { $0.state == .playing || $0.state == .paused || $0.state == .stopping }
        let ids = Set(visible.map { $0.cue.id })
        if ids != activeCueIDs { activeCueIDs = ids }

        let list = visible.map { s -> NowPlaying in
            let t = min(s.elapsed, s.duration)
            return NowPlaying(id: s.id, cueID: s.cue.id, name: s.cue.name, elapsed: t,
                              remaining: s.remaining,
                              progress: s.duration > 0 ? t / s.duration : 0,
                              speed: s.speed,
                              paused: s.state == .paused, stopping: s.state == .stopping)
        }
        if list != playing { playing = list }

        var heads: [UUID: Double] = [:]
        for s in visible where s.state != .stopping { heads[s.cue.id] = s.fileTime }
        if heads != playheads { playheads = heads }
    }

    // MARK: - Default app

    /// Makes CueDeck the app that opens common video files from Finder.
    func makeDefaultVideoPlayer() {
        let types: [UTType] = [UTType.quickTimeMovie, UTType.mpeg4Movie] + [UTType("com.apple.m4v-video")].compactMap { $0 }
        let app = Bundle.main.bundleURL
        Task {
            var failures = 0
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                } catch {
                    failures += 1
                }
            }
            message = failures == 0
                ? "CueDeck now opens .mov, .mp4 and .m4v files."
                : "macOS did not allow changing the default app. Use Finder › Get Info › Open with › Change All."
        }
    }

    // MARK: - Saving

    nonisolated private static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CueDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autosave.cuedeck")
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let snapshot = ShowFile(cues: cues)
        let url = showURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.autosaveURL, options: .atomic)
            if let url { try? data.write(to: url, options: .atomic) }
        }
        autosaveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func loadAutosave() {
        guard let data = try? Data(contentsOf: Self.autosaveURL),
              let show = try? JSONDecoder().decode(ShowFile.self, from: data) else { return }
        loadShow(show)
    }

    private func loadShow(_ show: ShowFile) {
        var loaded = show.cues
        for i in loaded.indices {
            loaded[i].missing = !loaded[i].isStream && !FileManager.default.fileExists(atPath: loaded[i].url.path)
            loaded[i].normalizeRoutes(outputChannels: routingChannels, defaults: defaultRouting)
            // Older shows: "play next cue when finished" is now the next cue's autostart.
            if loaded[i].endAction == .next {
                loaded[i].endAction = .stop
                if i + 1 < loaded.count && loaded[i + 1].autoStart == .off { loaded[i + 1].autoStart = .afterPrevious }
            }
        }
        withoutUndo { cues = loaded }
        clearUndo()
        pendingStarts = [:]
        selection = cues.first?.id
        refreshStreamNames()
    }

    /// Reads the stream names from the files again (shows saved before
    /// CueDeck read them, or files that changed).
    private func refreshStreamNames() {
        let list = cues.filter { !$0.missing && !$0.isStream && $0.duration > 0 }.map { ($0.id, $0.url) }
        Task {
            for (id, url) in list {
                let names = await MediaInspector.trackNames(of: url)
                let subtitles = await MediaInspector.subtitleTracks(of: url)
                guard var cue = findCue(id) else { continue }
                let before = cue
                if let names, names.count == cue.audioTracks.count {
                    for i in names.indices { cue.audioTracks[i].fileName = names[i] }
                }
                if subtitles != cue.subtitleTracks { cue.subtitleTracks = subtitles }
                if cue != before { withoutUndo { updateCue(cue) } }
            }
        }
    }

    func newShow() {
        stopAll(fade: false)
        showURL = nil
        withoutUndo { cues = [] }
        clearUndo()
        pendingStarts = [:]
        selection = nil
    }

    func openShow() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .data]
        panel.message = "Open a CueDeck show (.cuedeck)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openShow(at: url)
    }

    func openShow(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let show = try JSONDecoder().decode(ShowFile.self, from: data)
            stopAll(fade: false)
            showURL = url
            loadShow(show)
        } catch {
            message = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveShowAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = showURL?.lastPathComponent ?? "Show.cuedeck"
        panel.message = "Save the cue list"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showURL = url
        saveShow()
    }

    func saveShow() {
        guard let url = showURL else { saveShowAs(); return }
        do {
            let data = try JSONEncoder().encode(ShowFile(cues: cues))
            try data.write(to: url, options: .atomic)
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    func addFilesWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add video or audio files"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    /// Called when the app quits.
    func shutdown() {
        timer?.invalidate()
        caspar.shutdown()
        stopAll(fade: false)
        video.close()
        autosaveWork?.perform()
        removeDeviceObserver?()
        if let out = output {
            output = nil
            AudioCleanup.queue.sync { out.dispose() }
        }
    }
}
