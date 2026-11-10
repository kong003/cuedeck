import Foundation

// BCC Media (app.bcc.media): sign-in, episode lookup and the HLS playlists.
//
// Sign-in uses the OAuth device-code flow of login.bcc.no, the same as the
// BCC Media TV app: CueDeck shows a code, the user signs in on their own
// phone or browser, and CueDeck receives a token. CueDeck never sees the
// password. Episodes come from the public GraphQL API of the BCC Media
// platform (github.com/bcc-code/bcc-media-platform); their streams are
// unencrypted HLS (CMAF) with one audio rendition per language and WebVTT
// subtitles.

enum BCCMedia {
    static let authDomain = "login.bcc.no"
    /// Public client of the BCC Media TV app, which offers the device-code flow.
    static let clientID = "rJbKSHYPskua2BgY8mEwOSasK6o6uCRA"
    static let scope = "openid profile email offline_access country church"
    static let audience = "api.bcc.no"
    static let api = URL(string: "https://api.brunstad.tv/query")!

    /// Episode id from a link such as https://app.bcc.media/episode/65/860
    /// (collection 65, episode 860), .../episode/860, .../ep/860 or a bare id.
    static func episodeID(from link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, s.allSatisfy(\.isNumber) { return s }
        guard let url = URL(string: s), let host = url.host, host.contains("bcc.media") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(where: { $0 == "episode" || $0 == "ep" }), i + 1 < parts.count else { return nil }
        // episode/<id> or episode/<collection>/<id>
        let rest = parts[(i + 1)...].prefix(2)
        return rest.count == 2 && rest.last!.allSatisfy(\.isNumber) ? String(rest.last!) : String(rest.first!)
    }

    static func link(forEpisode id: String) -> URL {
        URL(string: "https://app.bcc.media/episode/\(id)")!
    }

    // MARK: Requests

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func postJSON(_ url: URL, _ body: [String: Any], headers: [String: String] = [:]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    // MARK: Episodes

    struct Episode {
        var id: String
        var title: String
        var duration: Double
        var streamURL: URL
        var expiresAt: Date?
    }

    static func episode(id: String, token: String) async throws -> Episode {
        let query = """
        query($id: ID!) { episode(id: $id) { id title duration \
        streams { type url expiresAt } } }
        """
        let (status, json) = try await postJSON(api, ["query": query, "variables": ["id": id]], headers: [
            "Authorization": "Bearer \(token)",
            "X-Application": "cuedeck",
            "Accept-Language": Locale.preferredLanguages.first ?? "en",
        ])
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw APIError(message: "BCC Media: \(first["message"] as? String ?? "error \(status)")")
        }
        guard let data = json["data"] as? [String: Any], let ep = data["episode"] as? [String: Any] else {
            throw APIError(message: status == 401 ? "BCC Media: please sign in again." : "BCC Media: episode \(id) not found.")
        }
        let streams = ep["streams"] as? [[String: Any]] ?? []
        // CMAF first: its segments are fragmented MP4, which CueDeck decodes itself.
        let ordered = streams.sorted { a, b in (a["type"] as? String == "hls_cmaf") && (b["type"] as? String != "hls_cmaf") }
        guard let stream = ordered.first(where: { ($0["type"] as? String)?.hasPrefix("hls") == true }),
              let urlString = stream["url"] as? String, let url = URL(string: urlString) else {
            throw APIError(message: "BCC Media: this episode has no stream CueDeck can play.")
        }
        let expires = (stream["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Episode(id: ep["id"] as? String ?? id,
                       title: (ep["title"] as? String ?? "BCC Media \(id)").trimmingCharacters(in: .whitespaces),
                       duration: Double(ep["duration"] as? Int ?? 0),
                       streamURL: url, expiresAt: expires)
    }
}

// MARK: - HLS master playlist

/// The parts of an HLS master playlist CueDeck uses.
struct HLSMaster {
    struct Rendition {
        var type: String          // AUDIO or SUBTITLES
        var name: String
        var language: String
        var channels: Int
        var isDefault: Bool
        var url: URL
    }
    struct Variant {
        var bandwidth: Int
        var width: Int
        var height: Int
        var frameRate: Double
        var url: URL
    }

    var audio: [Rendition] = []
    var subtitles: [Rendition] = []
    var variants: [Variant] = []

    static func load(_ url: URL) async throws -> HLSMaster {
        let (data, _) = try await URLSession.shared.data(from: url)
        return parse(String(decoding: data, as: UTF8.self), base: url)
    }

    static func parse(_ text: String, base: URL) -> HLSMaster {
        var master = HLSMaster()
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
                let r = Rendition(type: a["TYPE"] ?? "", name: a["NAME"] ?? "", language: a["LANGUAGE"] ?? "",
                                  channels: Int((a["CHANNELS"] ?? "2").split(separator: "/").first ?? "2") ?? 2,
                                  isDefault: a["DEFAULT"] == "YES", url: url)
                if r.type == "AUDIO" { master.audio.append(r) }
                if r.type == "SUBTITLES" { master.subtitles.append(r) }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let a = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let next = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                      let url = URL(string: next, relativeTo: base)?.absoluteURL else { continue }
                let res = (a["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                master.variants.append(Variant(bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                                               width: res.first ?? 0, height: res.count > 1 ? res[1] : 0,
                                               frameRate: Double(a["FRAME-RATE"] ?? "") ?? 0, url: url))
            }
        }
        return master
    }

    /// KEY=VALUE,KEY="quoted, value" attribute lists.
    static func attributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }
}

// MARK: - Account

/// The BCC Media sign-in. Tokens are kept in a file only this user can read
/// (Application Support/CueDeck/bcc-media.json); the access token is renewed
/// with the refresh token when it runs out.
@MainActor
final class BCCMediaAccount: ObservableObject {
    enum State: Equatable {
        case signedOut
        case waiting(code: String, url: URL)
        case signedIn(name: String)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var name: String
    }

    private var tokens: Tokens?
    private var signInTask: Task<Void, Never>?

    private static var tokenFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CueDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bcc-media.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.tokenFile), let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
            state = .signedIn(name: t.name)
        }
    }

    var isSignedIn: Bool { tokens != nil }

    /// Starts the device-code sign-in; `state` shows the code to enter.
    func signIn() {
        signInTask?.cancel()
        signInTask = Task { await runSignIn() }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .waiting = state { state = tokens.map { .signedIn(name: $0.name) } ?? .signedOut }
    }

    func signOut() {
        cancelSignIn()
        tokens = nil
        try? FileManager.default.removeItem(at: Self.tokenFile)
        state = .signedOut
    }

    /// A valid access token, renewed if needed.
    func accessToken() async throws -> String {
        guard var t = tokens else { throw BCCMedia.APIError(message: "Sign in to BCC Media first.") }
        if t.expiresAt > Date().addingTimeInterval(60) { return t.accessToken }
        guard let refresh = t.refreshToken else {
            signOut()
            throw BCCMedia.APIError(message: "The BCC Media sign-in has expired. Please sign in again.")
        }
        let (status, json) = try await BCCMedia.postJSON(URL(string: "https://\(BCCMedia.authDomain)/oauth/token")!, [
            "grant_type": "refresh_token", "client_id": BCCMedia.clientID, "refresh_token": refresh,
        ])
        guard status == 200, let access = json["access_token"] as? String else {
            if status == 400 || status == 401 || status == 403 { signOut() }
            throw BCCMedia.APIError(message: "The BCC Media sign-in has expired. Please sign in again.")
        }
        t.accessToken = access
        if let r = json["refresh_token"] as? String { t.refreshToken = r }
        t.expiresAt = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600))
        store(t)
        return access
    }

    private func runSignIn() async {
        do {
            let (status, code) = try await BCCMedia.postJSON(URL(string: "https://\(BCCMedia.authDomain)/oauth/device/code")!, [
                "client_id": BCCMedia.clientID, "scope": BCCMedia.scope, "audience": BCCMedia.audience,
            ])
            guard status == 200, let device = code["device_code"] as? String, let user = code["user_code"] as? String,
                  let link = URL(string: (code["verification_uri_complete"] as? String) ?? (code["verification_uri"] as? String) ?? "")
            else {
                state = .failed("BCC Media sign-in is not available right now (\(status)).")
                return
            }
            state = .waiting(code: user, url: link)
            var interval = Double(code["interval"] as? Int ?? 5)
            let deadline = Date().addingTimeInterval(Double(code["expires_in"] as? Int ?? 600))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let (s, json) = try await BCCMedia.postJSON(URL(string: "https://\(BCCMedia.authDomain)/oauth/token")!, [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": device, "client_id": BCCMedia.clientID,
                ])
                if s == 200, let access = json["access_token"] as? String {
                    let name = Self.name(fromIDToken: json["id_token"] as? String) ?? "BCC account"
                    store(Tokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
                                 expiresAt: Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600)),
                                 name: name))
                    state = .signedIn(name: name)
                    return
                }
                switch json["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                default:
                    state = .failed("Sign-in was not completed: \(json["error_description"] as? String ?? "cancelled").")
                    return
                }
            }
            state = .failed("The code has expired. Please try again.")
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func store(_ t: Tokens) {
        tokens = t
        guard let data = try? JSONEncoder().encode(t) else { return }
        let path = Self.tokenFile.path
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The "name" claim of the ID token (a JWT), for "Signed in as …".
    private static func name(fromIDToken jwt: String?) -> String? {
        guard let part = jwt?.split(separator: ".").dropFirst().first else { return nil }
        var b64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (claims["name"] as? String) ?? (claims["email"] as? String)
    }
}
