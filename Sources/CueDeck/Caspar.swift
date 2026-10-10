import Foundation
import Network

/// Sends the subtitles of the playing cue to a CasparCG server (AMCP over TCP):
/// the same lines on every channel in `channels`, with the HTML template
/// `template` (template/caspardcg/subtitle.html on the server) on layer `layer`.
///
/// The engine calls `update(_:)` on every tick with what should be on air:
/// nil = no cue with subtitles (layers cleared), [] = template loaded but no
/// text right now, otherwise the lines. Only changes are sent; after a
/// reconnect everything is sent again.
@MainActor
final class CasparOutput: ObservableObject {
    /// CueDeck is the only thing playing on its channels, so a fixed layer is fine.
    static let layer = 20
    /// The subtitle template in the server's template folder (always the same).
    static let template = "caspardcg/subtitle"

    enum Status: Equatable {
        case off, connecting, connected, failed(String)
    }

    @Published var enabled: Bool { didSet { settingsChanged() } }
    @Published var host: String { didSet { settingsChanged() } }
    @Published var port: Int { didSet { settingsChanged() } }
    /// Channels that all show the subtitles. Changes apply at once, no reconnect.
    @Published var channels: [Int] {
        didSet {
            UserDefaults.standard.set(channels, forKey: Keys.channels)
            apply()
        }
    }
    @Published private(set) var status: Status = .off
    /// Last error the server answered with (e.g. template not found).
    @Published private(set) var serverError: String?

    private enum Keys {
        static let enabled = "caspar.enabled", host = "caspar.host", port = "caspar.port"
        static let channels = "caspar.channels"
        static let oldChannel = "caspar.channel"   // before there were several channels
    }

    private var connection: NWConnection?
    private var reconnectWork: DispatchWorkItem?
    private var desired: [String]?
    private var testing = false
    private var testWork: DispatchWorkItem?
    /// What the server has: channels with the template loaded, and the lines last sent there.
    private var sent: [Int: [String]] = [:]
    private var receiveBuffer = ""

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        host = d.string(forKey: Keys.host) ?? ""
        port = d.object(forKey: Keys.port) as? Int ?? 5250
        channels = d.array(forKey: Keys.channels) as? [Int]
            ?? [d.object(forKey: Keys.oldChannel) as? Int ?? 1]
        connect()
    }

    // MARK: Engine interface

    func update(_ lines: [String]?) {
        desired = lines
        apply()
    }

    /// Shows a test subtitle on every channel for a few seconds (Settings).
    func test() {
        testWork?.cancel()
        testing = true
        apply()
        let work = DispatchWorkItem { [weak self] in
            self?.testing = false
            self?.apply()
        }
        testWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Clears the layers before the app quits.
    func shutdown() {
        guard let conn = connection, status == .connected, !sent.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        let commands = sent.keys.map { "CLEAR \($0)-\(Self.layer)\r\n" }.joined()
        conn.send(content: Data(commands.utf8), completion: .contentProcessed { _ in done.signal() })
        _ = done.wait(timeout: .now() + 0.3)
        conn.cancel()
    }

    // MARK: Sending

    private func apply() {
        guard enabled, status == .connected else { return }
        var want: [Int: [String]] = [:]
        for ch in Set(channels) {
            if testing {
                want[ch] = ["CueDeck test subtitle", "Channel \(ch), layer \(Self.layer)"]
            } else if let lines = desired {
                want[ch] = lines
            }
        }

        for ch in sent.keys.sorted() where want[ch] == nil {
            send("CLEAR \(ch)-\(Self.layer)")
            sent[ch] = nil
        }
        for (ch, lines) in want.sorted(by: { $0.key < $1.key }) {
            let target = "\(ch)-\(Self.layer)"
            if sent[ch] == nil {
                send("CG \(target) ADD 0 \"\(Self.escape(Self.template))\" 1 \"\(Self.escape(Self.json(lines)))\"")
                sent[ch] = lines
                // The template loads asynchronously; show it (and send the current
                // text again) once it is ready.
                for delay in [0.4, 1.2, 2.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, let current = self.sent[ch] else { return }
                        self.send("CG \(target) INVOKE 0 \"show\"")
                        self.send("CG \(target) UPDATE 0 \"\(Self.escape(Self.json(current)))\"")
                    }
                }
            } else if sent[ch] != lines {
                send("CG \(target) UPDATE 0 \"\(Self.escape(Self.json(lines)))\"")
                sent[ch] = lines
            }
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
        // Wait until typing stops before connecting to a new address.
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func connect() {
        // Leave nothing on air when switching off or moving to another server.
        if let old = connection {
            if status == .connected, !sent.isEmpty {
                let commands = sent.keys.map { "CLEAR \($0)-\(Self.layer)\r\n" }.joined()
                old.send(content: Data(commands.utf8), completion: .contentProcessed { _ in old.cancel() })
            } else {
                old.cancel()
            }
        }
        connection = nil
        sent = [:]
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
                    self.sent = [:]
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
