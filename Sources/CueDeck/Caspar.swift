import Foundation
import Network

/// Sends the subtitles of the playing cue to a CasparCG server (AMCP over TCP)
/// using the HTML template `template` (by default the caspardcg/subtitle
/// template from template/caspardcg) on `channel`, layer `layer`.
///
/// The engine calls `update(_:)` on every tick with what should be on air:
/// nil = no cue with subtitles (layer cleared), [] = template loaded but no
/// text right now, otherwise the lines. Only changes are sent; after a
/// reconnect everything is sent again.
@MainActor
final class CasparOutput: ObservableObject {
    /// CueDeck is the only thing playing on its channel, so a fixed layer is fine.
    static let layer = 20

    enum Status: Equatable {
        case off, connecting, connected, failed(String)
    }

    @Published var enabled: Bool { didSet { settingsChanged() } }
    @Published var host: String { didSet { settingsChanged() } }
    @Published var port: Int { didSet { settingsChanged() } }
    @Published var channel: Int { didSet { settingsChanged() } }
    @Published var template: String { didSet { settingsChanged() } }
    @Published private(set) var status: Status = .off
    /// Last error the server answered with (e.g. template not found).
    @Published private(set) var serverError: String?

    private enum Keys {
        static let enabled = "caspar.enabled", host = "caspar.host", port = "caspar.port"
        static let channel = "caspar.channel", template = "caspar.template"
    }

    private var connection: NWConnection?
    private var reconnectWork: DispatchWorkItem?
    private var desired: [String]?
    private var testLines: [String]?
    private var testWork: DispatchWorkItem?
    /// What the server has: template loaded on (channel, layer), and the lines last sent.
    private var loadedOn: Int?
    private var sentLines: [String]?
    private var receiveBuffer = ""

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        host = d.string(forKey: Keys.host) ?? ""
        port = d.object(forKey: Keys.port) as? Int ?? 5250
        channel = d.object(forKey: Keys.channel) as? Int ?? 1
        template = d.string(forKey: Keys.template) ?? "caspardcg/subtitle"
        connect()
    }

    // MARK: Engine interface

    func update(_ lines: [String]?) {
        desired = lines
        apply()
    }

    /// Shows a test subtitle for a few seconds (Settings).
    func test() {
        testWork?.cancel()
        testLines = ["CueDeck test subtitle", "Channel \(channel), layer \(Self.layer)"]
        apply()
        let work = DispatchWorkItem { [weak self] in
            self?.testLines = nil
            self?.apply()
        }
        testWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Clears the layer before the app quits.
    func shutdown() {
        guard let conn = connection, status == .connected, let ch = loadedOn else { return }
        let done = DispatchSemaphore(value: 0)
        conn.send(content: Data("CLEAR \(ch)-\(Self.layer)\r\n".utf8), completion: .contentProcessed { _ in done.signal() })
        _ = done.wait(timeout: .now() + 0.3)
        conn.cancel()
    }

    // MARK: Sending

    private func apply() {
        guard enabled, status == .connected else { return }
        let want = testLines ?? desired
        // Settings changed to another channel: clear the old one first.
        if let ch = loadedOn, ch != channel {
            send("CLEAR \(ch)-\(Self.layer)")
            loadedOn = nil
            sentLines = nil
        }
        guard let lines = want else {
            if let ch = loadedOn {
                send("CLEAR \(ch)-\(Self.layer)")
                loadedOn = nil
                sentLines = nil
            }
            return
        }
        let target = "\(channel)-\(Self.layer)"
        if loadedOn == nil {
            send("CG \(target) ADD 0 \"\(Self.escape(template))\" 1 \"\(Self.escape(Self.json(lines)))\"")
            loadedOn = channel
            sentLines = lines
            // The template loads asynchronously; show it (and send the current
            // text again) once it is ready.
            for delay in [0.4, 1.2, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.loadedOn == self.channel, let current = self.sentLines else { return }
                    self.send("CG \(target) INVOKE 0 \"show\"")
                    self.send("CG \(target) UPDATE 0 \"\(Self.escape(Self.json(current)))\"")
                }
            }
        } else if sentLines != lines {
            send("CG \(target) UPDATE 0 \"\(Self.escape(Self.json(lines)))\"")
            sentLines = lines
        }
    }

    private func send(_ command: String) {
        connection?.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    /// The data the subtitle template expects: {"step": {"0": {"lines": [...]}}}.
    /// The template inserts the lines as HTML, so <, > and & are escaped.
    static func json(_ lines: [String]) -> String {
        let html = lines.map {
            $0.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let object: [String: Any] = ["step": ["0": ["lines": html]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// AMCP quoted parameter: backslashes and quotes are escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Connection

    private func settingsChanged() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: Keys.enabled)
        d.set(host, forKey: Keys.host)
        d.set(port, forKey: Keys.port)
        d.set(channel, forKey: Keys.channel)
        d.set(template, forKey: Keys.template)
        // Wait until typing stops before connecting to a new address.
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func connect() {
        // Leave nothing on air when switching off or moving to another server.
        if let old = connection {
            if status == .connected, let ch = loadedOn {
                old.send(content: Data("CLEAR \(ch)-\(Self.layer)\r\n".utf8),
                         completion: .contentProcessed { _ in old.cancel() })
            } else {
                old.cancel()
            }
        }
        connection = nil
        loadedOn = nil
        sentLines = nil
        serverError = nil
        let h = host.trimmingCharacters(in: .whitespaces)
        guard enabled, !h.isEmpty else { status = .off; return }
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: max(port, 1))) else {
            status = .failed("Invalid port"); return
        }
        status = .connecting
        let conn = NWConnection(host: NWEndpoint.Host(h), port: p, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            DispatchQueue.main.async {
                guard let self, let conn, conn === self.connection else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.loadedOn = nil
                    self.sentLines = nil
                    self.receive(on: conn)
                    self.apply()
                case .waiting(let error), .failed(let error):
                    self.status = .failed(error.localizedDescription)
                    self.retryLater()
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func retryLater() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Reads the server's answers and keeps the last error (4xx/5xx).
    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, let conn, conn === self.connection else { return }
                if let data { self.handle(String(decoding: data, as: UTF8.self)) }
                if isComplete || error != nil {
                    self.status = .failed(error?.localizedDescription ?? "Connection closed by the server")
                    self.retryLater()
                } else {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func handle(_ text: String) {
        receiveBuffer += text
        while let range = receiveBuffer.range(of: "\r\n") {
            let line = String(receiveBuffer[..<range.lowerBound])
            receiveBuffer.removeSubrange(..<range.upperBound)
            if let code = Int(line.prefix(3)), code >= 400 {
                serverError = line
            }
        }
        if receiveBuffer.count > 100_000 { receiveBuffer = "" }
    }
}
