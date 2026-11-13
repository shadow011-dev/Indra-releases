import AppKit
import CryptoKit
import Network
import Security

/// Reads the Spotify queue and recent songs through Spotify's Web API (the Spotify app itself has no
/// scripting access to its queue). Signs in with the PKCE flow: no secret is stored, only a refresh token,
/// which lives in the Keychain. The user supplies the Client ID of their own free Spotify developer app.
@MainActor
final class SpotifyWebAPI: ObservableObject {
    static let shared = SpotifyWebAPI()

    @Published private(set) var connected: Bool
    @Published private(set) var status = ""

    static let redirectURI = "http://127.0.0.1:8888/callback"
    /// `user-modify-playback-state` is only needed for "repeat one": Spotify's own scripting can switch repeat on and
    /// off, but only the Web API can set it to the current song.
    private static let scopes = "user-read-playback-state user-read-currently-playing user-read-recently-played user-modify-playback-state"

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var listener: NWListener?
    private var listenerTimeout: Task<Void, Never>?
    private var refreshTask: Task<Bool, Never>?
    private var lastTokenStatus = 0
    /// What the saved sign-in may do, as Spotify reported it. nil until a token has been fetched; a sign-in made
    /// before repeat one existed lacks the modify scope until the person connects again.
    private var grantedScopes: Set<String>?
    private var verifier = ""
    private var state = ""
    private let images = BoundedImageCache<URL>(limit: 40)

    private init() {
        connected = SpotifyKeychain.read() != nil
    }

    // MARK: - Sign in

    func connect() {
        let clientID = Preferences.spotifyClientID
        guard !clientID.isEmpty else {
            status = "Paste your Client ID first."
            return
        }
        verifier = SpotifyWebAPI.randomString(64)
        state = SpotifyWebAPI.randomString(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard startListener() else { return }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyWebAPI.redirectURI),
            URLQueryItem(name: "scope", value: SpotifyWebAPI.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else { return }
        status = "Finish signing in in your browser…"
        NSWorkspace.shared.open(url)
    }

    func disconnect() {
        stopListener()
        SpotifyKeychain.delete()
        accessToken = nil
        expiry = .distantPast
        connected = false
        grantedScopes = nil
        status = ""
    }

    private func stopListener() {
        listenerTimeout?.cancel()
        listenerTimeout = nil
        listener?.cancel()
        listener = nil
    }

    private func startListener() -> Bool {
        stopListener()
        // Only this Mac may reach the sign-in callback (not the local network).
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: 8888),
              let newListener = try? NWListener(using: parameters, on: port) else {
            status = "Port 8888 is in use. Close the other program and try again."
            return false
        }
        newListener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            // A connection that never says anything must not hold the port: drop it after a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // Only the sign-in redirect gets the success page; anything else (a favicon request, a probe, a web
                // page trying to reach this port under another host name) is refused.
                let isCallback = request.hasPrefix("GET /callback") && SpotifyWebAPI.hostIsLocal(request)
                let page = isCallback
                    ? "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(AppBrand.name) is connected to Spotify</h2><p>You can close this tab.</p></body></html>"
                    : ""
                let head = isCallback ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found"
                let response = head + "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n" + page
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if isCallback {
                    Task { @MainActor in self?.handleCallback(request) }
                }
            }
        }
        newListener.start(queue: .main)
        listener = newListener
        // Give up waiting after a few minutes so the port is not held open for ever.
        listenerTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled, let self, self.listener != nil else { return }
            self.stopListener()
            self.status = "Sign-in timed out. Press Connect to try again."
        }
        return true
    }

    /// The request names this Mac's own address (127.0.0.1 or localhost, port 8888) in its Host header.
    nonisolated private static func hostIsLocal(_ request: String) -> Bool {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard line.lowercased().hasPrefix("host:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            return value == "127.0.0.1:8888" || value == "localhost:8888"
        }
        return false
    }

    private func handleCallback(_ request: String) {
        guard let line = request.components(separatedBy: "\r\n").first else { return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
              components.path == "/callback" else { return }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            status = "Spotify said: \(error)"
            stopListener()
            return
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { return }
        stopListener()
        Task { @MainActor in
            let ok = await self.tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": SpotifyWebAPI.redirectURI,
                "client_id": Preferences.spotifyClientID,
                "code_verifier": self.verifier
            ])
            self.status = ok ? "" : "Spotify refused the sign-in. Check the Client ID and the redirect URI."
        }
    }

    // MARK: - Tokens

    private func tokenRequest(_ fields: [String: String]) async -> Bool {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await Net.send(request) else {
            lastTokenStatus = 0
            return false
        }
        lastTokenStatus = response.statusCode
        guard lastTokenStatus == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { return false }
        accessToken = token
        if let scope = json["scope"] as? String { grantedScopes = Set(scope.split(separator: " ").map(String.init)) }
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { SpotifyKeychain.write(refresh) }
        connected = true
        return true
    }

    private func validToken() async -> String? {
        if let accessToken, Date() < expiry { return accessToken }
        guard let refresh = SpotifyKeychain.read() else { return nil }
        // Several requests can need a new token at the same moment (the queue and the recent songs are fetched
        // together). Spotify may rotate the refresh token, so only one refresh may run; the others wait for it.
        if let running = refreshTask {
            return await running.value ? accessToken : nil
        }
        let task = Task { @MainActor in
            await self.tokenRequest(["grant_type": "refresh_token",
                                     "refresh_token": refresh,
                                     "client_id": Preferences.spotifyClientID])
        }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        if !ok, lastTokenStatus == 400 || lastTokenStatus == 401 {
            // Spotify no longer accepts the saved sign-in (revoked, or the Client ID changed).
            disconnect()
            status = "Your Spotify sign-in expired. Press Connect to sign in again."
        }
        return ok ? accessToken : nil
    }

    private func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.spotify.com/v1" + path) else { return nil }
        // v437: a busy answer (429, 5xx) is tried again by Net.send. A 401 means the token stopped working before its
        // time ran out: it is forgotten, a new one is fetched, and the request is made once more.
        for attempt in 0..<2 {
            guard let token = await validToken() else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await Net.send(request,
                                                             policy: RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8)) else { return nil }
            if response.statusCode == 401, attempt == 0 {
                accessToken = nil
                expiry = .distantPast
                continue
            }
            guard response.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return nil
    }

    // MARK: - Repeat

    /// Whether repeat can be set through the Web API (signed in, and the sign-in allows it).
    var canSetRepeat: Bool {
        connected && (grantedScopes?.contains("user-modify-playback-state") ?? true)
    }

    /// Spotify's repeat state: "off", "context" (the playlist or album) or "track" (the current song).
    func repeatState() async -> String? {
        await repeatInfo()?.state
    }

    /// The repeat state together with what Spotify is playing from. A song started without a playlist or album
    /// (a single song from search, say) has no context, so "repeat playlist" has nothing to repeat there.
    struct RepeatInfo {
        var state: String
        var contextKey: String   // the context URI, or "none"
    }

    func repeatInfo() async -> RepeatInfo? {
        guard connected, let player = await get("/me/player"),
              let state = player["repeat_state"] as? String else { return nil }
        var key = "none"
        if let context = player["context"] as? [String: Any], let uri = context["uri"] as? String { key = uri }
        return RepeatInfo(state: state, contextKey: key)
    }

    /// Sets repeat to "off", "context" or "track". False when Spotify refused (no Premium, no active player, or a
    /// sign-in without the modify scope), so the caller can fall back to the on / off switch in Spotify's scripting.
    func setRepeat(_ mode: String) async -> Bool {
        guard canSetRepeat, let token = await validToken(),
              let url = URL(string: "https://api.spotify.com/v1/me/player/repeat?state=" + mode) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        if (200..<300).contains(code) { return true }
        if code == 403 {
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("premium") {
                status = "Repeat one needs Spotify Premium."
            } else {
                // The saved sign-in predates the permission: remember it, so the button stops asking.
                grantedScopes = (grantedScopes ?? []).subtracting(["user-modify-playback-state"])
                status = "To use repeat one, press Disconnect, then Connect again."
            }
        }
        return false
    }

    // MARK: - Songs around the current one

    /// Five songs played before (oldest first, ids -5...-1) and the next three in the queue (ids 1...3).
    func window() async -> [QueueEntry]? {
        guard connected else { return nil }
        async let queueJSON = get("/me/player/queue")
        async let recentJSON = get("/me/player/recently-played?limit=30")
        let (queue, recent) = await (queueJSON, recentJSON)
        guard let queue else { return nil }

        let currentID = (queue["currently_playing"] as? [String: Any])?["id"] as? String
        var seen = Set<String>()
        if let currentID { seen.insert(currentID) }

        var after: [QueueEntry] = []
        for track in (queue["queue"] as? [[String: Any]]) ?? [] {
            guard after.count < 3, let id = track["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            if let entry = SpotifyWebAPI.entry(from: track, id: after.count + 1) { after.append(entry) }
        }

        var before: [QueueEntry] = []
        seen = currentID.map { Set([$0]) } ?? []
        let played = ((recent?["items"] as? [[String: Any]]) ?? []).compactMap { $0["track"] as? [String: Any] }
        for track in played {
            guard before.count < 5, let id = track["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            if let entry = SpotifyWebAPI.entry(from: track, id: -(before.count + 1)) { before.append(entry) }
        }
        return Array(before.reversed()) + after
    }

    private static func entry(from track: [String: Any], id: Int) -> QueueEntry? {
        guard let title = track["name"] as? String, let uri = track["uri"] as? String else { return nil }
        let artist = ((track["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
        let pictures = ((track["album"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []
        // Smallest picture that is still sharp enough at the magnified size.
        let chosen = pictures.last(where: { ($0["width"] as? Int ?? 0) >= 120 }) ?? pictures.first
        let url = (chosen?["url"] as? String).flatMap { URL(string: $0) }
        return QueueEntry(id: id, title: title, artist: artist, image: nil, imageURL: url, uri: uri)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        // v437: kept on disk (Net.cachedData), so the queue's covers appear at once next time, even offline.
        guard let data = await Net.cachedData(for: url), let image = NSImage(data: data) else { return nil }
        images[url] = image
        return image
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement() ?? "a" })
    }
}

/// Keeps the Spotify refresh token in the Keychain.
enum SpotifyKeychain {
    private static let service = "com.indra.spotify"
    private static let account = "refresh-token"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        delete()
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        // Readable only while the Mac is unlocked, never copied to other devices or into backups.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { IndraLog.crumb("Spotify: the sign-in could not be saved to the Keychain (\(status))") }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
