import AppKit
import Combine
import CryptoKit
import Network
import Security

/// v544: updates from inside the app.
///
/// Indra's source lives in a private GitHub repository (default shadow011-dev/Indra), so every call to GitHub goes through the
/// `git` of this Mac, which already has the login that `indra-ship.sh` uses to push; no token is stored anywhere in Indra.
///
///  * CHECK: reads only the `VERSION` file of the newest commit (a "blobless" shallow clone: a few kilobytes), at launch, then
///    every 10 minutes, after the Mac wakes, when the network comes back, and when "Check for updates" is pressed (v553: always
///    on, there is no switch for it). A bigger number than this build's number means an update.
///  * UPDATE: fetches the newest commit, generates the Xcode project (xcodegen, when installed), builds a Release copy with
///    xcodebuild into a private cache folder, and then a small detached script waits for Indra to quit, puts the new app where the
///    old one was (the old one is kept as Indra.previous.app in the cache folder), and opens it.
///
/// Everything runs in a child process in the background and nothing blocks the main thread: the process
/// reports back through its termination handler, and every call has a time limit.
/// v546: the GitHub access token for the private repository, kept in this Mac's Keychain (never in a file, never on a command line).
/// A Mac that is not the developer's has no git login, so "GitHub did not accept this Mac's login" could never be fixed there:
/// the person pastes a read-only token once (Settings > About > Updates) and every check and update uses it.
enum UpdateToken {
    nonisolated private static let service = "com.indra.Indra.update"
    nonisolated private static let account = "github-token"

    nonisolated static var value: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    nonisolated static var isSaved: Bool { value != nil }

    @discardableResult
    nonisolated static func save(_ token: String) -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let data = clean.data(using: .utf8) else { return false }
        remove()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// v565: shell text for the scripts that talk to the private repository, put right after `export PATH=...`. When no token was
    /// saved in Indra, the GitHub login that `gh` already has on this Mac is used for the run (the developer's Mac has it: it is what
    /// `scripts/release.sh --publish` needs), so "Check for updates" works there without pasting a token. Nothing is stored or printed.
    nonisolated static let shellGitLogin = """
    if [ -z "${GIT_CONFIG_COUNT:-}" ]; then
      for GH in /opt/homebrew/bin/gh /usr/local/bin/gh; do
        if [ -x "$GH" ]; then
          GHT=$("$GH" auth token 2>/dev/null || true)
          if [ -n "$GHT" ]; then
            export GIT_CONFIG_COUNT=1
            export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
            export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GHT" | base64 | tr -d '\\n')"
          fi
          break
        fi
      done
    fi
    """

    /// v565: gets the newest commit of the repository into $REPO (made by `git clone` the first time). It tries the https address,
    /// and when GitHub refuses that, the same repository over SSH with the keys of this Mac (never asking a question: BatchMode).
    /// When both fail, both answers are printed, so the message can say what happened.
    nonisolated static func shellFetch(repo: String) -> String {
        """
        HTTPS="\(repo)"
        SSH_URL=$(printf '%s' "$HTTPS" | sed -E 's#^https://github\\.com/#git@github.com:#')
        ERR1=$(mktemp "${TMPDIR:-/tmp}/indra-git.XXXXXX"); ERR2=$(mktemp "${TMPDIR:-/tmp}/indra-git.XXXXXX")
        try_remote() {
          if [ ! -d "$REPO/.git" ]; then
            rm -rf "$REPO"
            git clone --quiet --depth 1 --filter=blob:none --no-checkout "$1" "$REPO" || return 1
          fi
          git -C "$REPO" remote set-url origin "$1" && git -C "$REPO" fetch --quiet --depth 1 origin HEAD
        }
        if ! try_remote "$HTTPS" 2>"$ERR1"; then
          if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes" try_remote "$SSH_URL" 2>"$ERR2"; then
            :
          else
            cat "$ERR1" "$ERR2" >&2
            rm -f "$ERR1" "$ERR2"
            exit 1
          fi
        fi
        rm -f "$ERR1" "$ERR2"
        """
    }

    /// The environment that makes git send the token to github.com only (git reads these variables itself, so the token is in
    /// no argument list that `ps` could show and in no `.git/config`).
    nonisolated static func gitEnvironment() -> [String: String] {
        var env = ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"]
        if let token = value {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(basic)"
        }
        return env
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(version: Int)
        case updating(step: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        // v553: the notch listens to this (the update card and the update symbol), whoever changed the state.
        didSet { if state != oldValue { NotificationCenter.default.post(name: .indraUpdateStateChanged, object: nil) } }
    }
    /// The last lines the build printed (shown under the button).
    @Published private(set) var log: [String] = []

    /// v547: the update feed. A small public file (`latest.json`: build number, download address, SHA-256) that `scripts/release.sh`
    /// publishes together with the built app, so ANY Mac can update: no git, no Xcode, no GitHub login, no token.
    /// The source repository stays private; only the built app and this file are public. The old build-from-source path remains
    /// as a fallback for the developer's Mac (used only while no feed is published).
    static let feedKey = "updateFeedURL"
    static let defaultFeed = "https://github.com/shadow011-dev/Indra-releases/releases/latest/download/latest.json"
    static var feedURL: String {
        let saved = UserDefaults.standard.string(forKey: feedKey) ?? ""
        return saved.isEmpty ? defaultFeed : saved
    }

    struct Release: Decodable, Equatable, Sendable {
        let build: Int
        let url: String
        let sha256: String
    }

    private enum Source { case release(Release), git }
    private var source: Source = .git

    private enum FeedResult {
        case ok(Release)
        case notPublished
        case offline
        case failed(String)
    }

    /// v553: GitHub's own answer to "which release is the newest?". It is never served from a cache, unlike the `latest/download`
    /// address (the cause of an update that only appeared hours after it was published). The release it names has its own
    /// `latest.json` at an address that belongs to that release alone, so that file can never be an older copy.
    static let releasesAPI = "https://api.github.com/repos/shadow011-dev/Indra-releases/releases/latest"

    /// v565: the recent releases, newest first, pre-releases included. `releases/latest` skips a release that is marked "pre-release" and
    /// answers 404 when there is none that counts, so a build that was published that way was never found.
    static let releaseListAPI = "https://api.github.com/repos/shadow011-dev/Indra-releases/releases?per_page=20"

    static let repoKey = "updateRepoURL"
    static let defaultRepo = "https://github.com/shadow011-dev/Indra.git"

    static var repoURL: String {
        let saved = UserDefaults.standard.string(forKey: repoKey) ?? ""
        return saved.isEmpty ? defaultRepo : saved
    }

    /// This build's number (the number in VERSION).
    static var currentBuild: Int { Int(IndraLog.appBuild.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var autoTimer: Timer?
    /// A check is running / an update is being fetched (two separate things: a background check must never make a press of
    /// "Update and restart" do nothing).
    private var checking = false
    private var installing = false
    private var lastAvailable = 0
    private var lastCheckAt = Date.distantPast
    /// v565: what the update feed answered in the last check (shown in the message when nothing could be found).
    private var feedNote = ""
    private var wakeObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    /// v553: true from the moment the swap script has been started: Indra is quitting for the update and must not stop to ask
    /// for a fingerprint or a password on the way out (AppDelegate.applicationShouldTerminate reads this).
    private(set) var quittingForUpdate = false

    /// How often a new version is looked for (it was every 12 hours, so a new patch showed up hours late).
    private static let checkInterval: TimeInterval = 10 * 60

    private static var workDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("IndraUpdate", isDirectory: true)
    }

    var isWorking: Bool {
        switch state {
        case .checking, .updating: return true
        default: return false
        }
    }

    var availableVersion: Int? {
        if case .available(let version) = state { return version }
        return nil
    }

    // MARK: - Automatic check

    func startAutoCheck() {
        guard autoTimer == nil else { return }
        // v553: always on. A first look a few seconds after launch (the moment the person has just updated and may be waiting for
        // the next one), then every 10 minutes, after the Mac wakes, and whenever the network comes back.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self?.check(silent: true)
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check(silent: true) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // The network needs a moment after waking.
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await self?.checkIfStale(olderThan: 60)
                }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.checkIfStale(olderThan: 60)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.indra.update.path", qos: .utility))
        pathMonitor = monitor
    }

    /// A silent check, unless one ran very recently (the network and wake events can come in bunches).
    func checkIfStale(olderThan seconds: TimeInterval) async {
        guard !isWorking, Date().timeIntervalSince(lastCheckAt) >= seconds else { return }
        await check(silent: true)
    }

    func shutdown() {
        autoTimer?.invalidate()
        autoTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for token in wakeObservers { workspace.removeObserver(token) }
        wakeObservers.removeAll()
    }

    // MARK: - Check

    func check(silent: Bool = false) async {
        guard !checking, !installing else {
            // A press of "Check for updates" while the background check is still running: that one answers, the line shows it.
            if !silent, !isWorking { state = .checking }
            return
        }
        checking = true
        lastCheckAt = Date()
        defer { checking = false }
        if !silent || state == .idle { state = .checking }
        // v547: the public feed first: it needs nothing installed on this Mac.
        feedNote = ""
        let feed = await Self.fetchFeed()
        switch feed {
        case .ok(let release):
            source = .release(release)
            Trace.log("UPDATE check (feed): this build \(Self.currentBuild), newest \(release.build)")
            finishCheck(latest: release.build, silent: silent)
            return
        case .offline:
            Trace.log("UPDATE check: no connection")
            if !silent { state = .failed("No connection to GitHub.") } else if state == .checking { state = .idle }
            return
        case .failed(let why):
            Trace.log("UPDATE check: the feed answered badly: \(why)")
            feedNote = "the update feed answered badly: \(why)"
        case .notPublished:
            Trace.log("UPDATE check: no feed published yet; trying git")
            feedNote = "the update feed has no release with a latest.json file"
        }
        source = .git
        let repo = Self.repoURL
        let work = Self.workDir.path
        let script = """
        set -e
        export GIT_TERMINAL_PROMPT=0
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH
        \(UpdateToken.shellGitLogin)
        # v546: what this Mac needs, checked first so the message names the real missing piece.
        if [ ! -x /opt/homebrew/bin/git ] && [ ! -x /usr/local/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then echo "INDRA_ERR no-git"; exit 3; fi
        mkdir -p "\(work)"
        REPO="\(work)/repo"
        \(UpdateToken.shellFetch(repo: repo))
        git -C "$REPO" show FETCH_HEAD:VERSION
        """
        let result = await Self.run(script: script, limit: 90, onLine: { _ in })
        guard result.status == 0 else {
            Trace.log("UPDATE check failed (\(result.status)): \(result.output.suffix(300))")
            // v547: an ordinary Mac (no git) with no feed published: there is simply nothing to install, and git is not its business.
            // v565: the message also says what was found out (the feed's answer), so "no published version" can be acted on.
            let base = result.output.contains("INDRA_ERR no-git")
                ? "No published version was found. Try again later." : Self.explain(result.output)
            let message = feedNote.isEmpty || !base.hasPrefix("No published version") ? base : base + " (\(feedNote); the repository could not be read either.)"
            if !silent { state = .failed(message) }
            else if state == .checking { state = .idle }
            return
        }
        // The last line that is only digits is the VERSION file.
        let latest = result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .last
        guard let latest else {
            if !silent { state = .failed("The newest version number could not be read from the repository.") }
            return
        }
        Trace.log("UPDATE check: this build \(Self.currentBuild), newest \(latest)")
        finishCheck(latest: latest, silent: silent)
    }

    private func finishCheck(latest: Int, silent: Bool) {
        if latest > Self.currentBuild {
            lastAvailable = max(lastAvailable, latest)
            if case .available(let known) = state, known >= latest { return }
            state = .available(version: latest)
        } else {
            // A copy of the feed that is older than a version already seen (a cache somewhere) must not make a known update vanish.
            if silent, lastAvailable > Self.currentBuild {
                if case .available = state {} else { state = .available(version: lastAvailable) }
                return
            }
            state = .upToDate(Date())
        }
    }

    // MARK: - The public feed (no git, no Xcode)

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let assets: [Asset]?
    }

    private static func fetchFeed() async -> FeedResult {
        // v553: with the normal (built-in) feed, GitHub's API says which release is newest and that release's own file is read:
        // nothing between GitHub and this Mac can answer with an older copy. If the API cannot be used (a busy shared network
        // can use up its small free allowance), the feed address is read as before, with a unique ending so no cache answers.
        let custom = UserDefaults.standard.string(forKey: feedKey) ?? ""
        if custom.isEmpty, let fresh = await fetchFromReleasesAPI() { return fresh }
        if custom.isEmpty, let listed = await fetchFromReleaseList() { return listed }
        return await fetchFeedFile(feedURL)
    }

    /// v565: the highest build among the recent releases (the tag is "v<build>"), read from that release's own `latest.json`.
    private static func fetchFromReleaseList() async -> FeedResult? {
        guard let url = URL(string: releaseListAPI) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Indra-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                Trace.log("UPDATE feed: the list of releases answered HTTP \(status)")
                return nil
            }
            let releases = try JSONDecoder().decode([APIRelease].self, from: data)
            let ranked = releases
                .compactMap { release -> (build: Int, address: String)? in
                    guard let build = Int(release.tag_name.filter(\.isNumber)),
                          let asset = release.assets?.first(where: { $0.name == "latest.json" }),
                          asset.browser_download_url.hasPrefix("https://github.com/") else { return nil }
                    return (build, asset.browser_download_url)
                }
                .sorted { $0.build > $1.build }
            guard !ranked.isEmpty else {
                Trace.log("UPDATE feed: \(releases.count) release(s) found, none has a latest.json file")
                return nil
            }
            for candidate in ranked.prefix(3) {
                let result = await fetchFeedFile(candidate.address)
                if case .ok = result { return result }
            }
            return nil
        } catch {
            Trace.log("UPDATE feed: the list of releases could not be read (\(error.localizedDescription))")
            return nil
        }
    }

    private static func fetchFromReleasesAPI() async -> FeedResult? {
        guard let url = URL(string: releasesAPI) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Indra-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Trace.log("UPDATE feed: releases/latest answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let api = try JSONDecoder().decode(APIRelease.self, from: data)
            guard let asset = api.assets?.first(where: { $0.name == "latest.json" }),
                  asset.browser_download_url.hasPrefix("https://github.com/") else {
                Trace.log("UPDATE feed: the newest release (\(api.tag_name)) has no latest.json file")
                return nil
            }
            let result = await fetchFeedFile(asset.browser_download_url)
            if case .ok = result { return result }
            return nil
        } catch {
            return nil
        }
    }

    private static func fetchFeedFile(_ address: String) async -> FeedResult {
        guard let plain = URL(string: address), plain.scheme == "https" else { return .failed("the feed address is not an https address") }
        var addresses: [URL] = []
        if var parts = URLComponents(url: plain, resolvingAgainstBaseURL: false) {
            var items = parts.queryItems ?? []
            items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
            parts.queryItems = items
            if let busted = parts.url { addresses.append(busted) }
        }
        addresses.append(plain)
        var last: FeedResult = .failed("no answer")
        for candidate in addresses {
            let result = await fetchFeedOnce(candidate)
            switch result {
            case .ok, .offline: return result
            default: last = result
            }
        }
        return last
    }

    private static func fetchFeedOnce(_ url: URL) async -> FeedResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Indra-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no HTTP answer") }
            if http.statusCode == 404 { return .notPublished }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.url.hasPrefix("https://"), release.sha256.count == 64, release.build > 0 else {
                return .failed("the feed file is not valid")
            }
            return .ok(release)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                              .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(error.code) {
            return .offline
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the built app from the feed, checks it, and hands it to the same swap script as a build from source.
    private func installRelease(_ release: Release) async {
        guard let url = URL(string: release.url), url.scheme == "https" else {
            state = .failed("The update address is not valid.")
            return
        }
        let work = Self.workDir
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Indra-\(release.build).zip")
        try? FileManager.default.removeItem(at: zip)

        state = .updating(step: "Downloading build \(release.build)")
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 20 * 60
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (temp, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Trace.log("UPDATE download: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                state = .failed("The new version could not be downloaded (the file is not published).")
                return
            }
            try FileManager.default.moveItem(at: temp, to: zip)
        } catch {
            Trace.log("UPDATE download failed: \(error.localizedDescription)")
            state = .failed("The new version could not be downloaded. Check the connection and try again.")
            return
        }

        state = .updating(step: "Checking the download")
        let actual = await Task.detached(priority: .utility) { Self.sha256(of: zip) }.value
        guard let actual, actual.lowercased() == release.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: zip)
            Trace.log("UPDATE download: the SHA-256 does not match the feed")
            state = .failed("The downloaded file did not match its checksum, so it was not installed. Try again.")
            return
        }

        state = .updating(step: "Unpacking")
        let script = """
        set -e
        WORK="\(work.path)"
        rm -rf "$WORK/release"; mkdir -p "$WORK/release"
        /usr/bin/ditto -x -k "\(zip.path)" "$WORK/release"
        APP="$WORK/release/Indra.app"
        PB=/usr/libexec/PlistBuddy
        test -d "$APP" || { echo "INDRA_ERR bad-package"; exit 5; }
        [ "$($PB -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.indra.Indra" ] || { echo "INDRA_ERR wrong-app"; exit 6; }
        [ "$($PB -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "\(release.build)" ] || { echo "INDRA_ERR wrong-build"; exit 7; }
        /usr/bin/codesign --verify --deep --strict "$APP" 2>&1 || { echo "INDRA_ERR bad-signature"; exit 8; }
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        echo "STEP Unpacked"
        """
        let result = await Self.run(script: script, limit: 120, onLine: { _ in })
        guard result.status == 0 else {
            Trace.log("UPDATE unpack failed (\(result.status)): \(result.output.suffix(300))")
            state = .failed("The downloaded update is damaged or not the right app, so it was not installed.")
            return
        }
        try? FileManager.default.removeItem(at: zip)
        state = .updating(step: "Installing and restarting")
        guard installAndRelaunch(built: work.appendingPathComponent("release/Indra.app")) else {
            state = .failed("The new version was downloaded but could not be put in place. Is Indra in a folder you can write to?")
            return
        }
    }

    // MARK: - Update

    func update() async {
        guard !installing else { return }
        // A check that is running right now (the background one) is waited for, a few seconds at most: it is never a reason to
        // do nothing (v552: the press of "Update and restart" was dropped silently while one was running).
        var waited = 0
        while checking, waited < 100 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        if case .available = state {
            // fine
        } else if lastAvailable > Self.currentBuild {
            // The line was changed by a newer look in between; the newest version seen still counts.
            state = .available(version: lastAvailable)
        } else {
            // Nothing is known: look once more instead of ignoring the press.
            await check(silent: false)
            guard case .available = state else { return }
        }
        // Never in the middle of a drop or a send, or while the Mac is locked: and the person is told, not ignored.
        if TrackpadActuator.shared.isQuiet {
            state = .failed("A file is being dragged or sent. Try again in a minute.")
            return
        }
        if LockMonitor.isScreenLockedCached() {
            state = .failed("The Mac is locked. Unlock it and try again.")
            return
        }
        installing = true
        defer { installing = false }
        log = []
        if case .release(let release) = source {
            await installRelease(release)
            return
        }
        state = .updating(step: "Getting the new version")

        let repo = Self.repoURL
        let work = Self.workDir.path
        let script = """
        set -e
        export GIT_TERMINAL_PROMPT=0
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH
        \(UpdateToken.shellGitLogin)
        # v546: what this Mac needs, checked first so the message names the real missing piece.
        if [ ! -x /opt/homebrew/bin/git ] && [ ! -x /usr/local/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then echo "INDRA_ERR no-git"; exit 3; fi
        if ! xcodebuild -version >/dev/null 2>&1; then echo "INDRA_ERR no-xcode"; exit 4; fi
        mkdir -p "\(work)"
        REPO="\(work)/repo"
        echo "STEP Getting the new version"
        \(UpdateToken.shellFetch(repo: repo))
        git -C "$REPO" checkout --quiet -f FETCH_HEAD
        cd "$REPO"
        echo "STEP Preparing the project"
        if command -v xcodegen >/dev/null 2>&1; then xcodegen generate --quiet; fi
        echo "STEP Building (a few minutes)"
        rm -rf "\(work)/build"
        xcodebuild -project Indra.xcodeproj -scheme Indra -configuration Release \
          -derivedDataPath "\(work)/build" -destination 'platform=macOS' \
          CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build 2>&1 | grep --line-buffered -E "error:|BUILD (SUCCEEDED|FAILED)|CompileSwiftSources|Linking|CodeSign" || true
        test -d "\(work)/build/Build/Products/Release/Indra.app"
        echo "STEP Built"
        """
        let result = await Self.run(script: script, limit: 40 * 60, onLine: { [weak self] line in
            Task { @MainActor [weak self] in self?.noteLine(line) }
        })
        guard result.status == 0 else {
            Trace.log("UPDATE build failed (\(result.status)): \(result.output.suffix(600))")
            state = .failed("The new version could not be built. \(Self.explain(result.output))")
            return
        }
        state = .updating(step: "Installing and restarting")
        guard installAndRelaunch() else {
            state = .failed("The new version was built but could not be put in place.")
            return
        }
    }

    private func noteLine(_ line: String) {
        if line.hasPrefix("STEP ") {
            state = .updating(step: String(line.dropFirst(5)))
            return
        }
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    /// Writes the swap script, starts it detached (it waits for this process to end), and quits.
    private func installAndRelaunch(built builtOverride: URL? = nil) -> Bool {
        let work = Self.workDir
        let built = builtOverride ?? work.appendingPathComponent("build/Build/Products/Release/Indra.app")
        guard FileManager.default.fileExists(atPath: built.path) else { return false }

        // The app being replaced: where this copy runs from, unless that is a build folder (then ~/Applications).
        var target = Bundle.main.bundleURL
        // v553: a copy started straight from Downloads runs from a read-only, translocated path: the update goes to ~/Applications.
        if target.path.contains("/DerivedData/") || target.path.contains("/Build/Products/") || target.path.contains("/AppTranslocation/") {
            target = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Indra.app")
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // v547: a folder this person cannot write to (Indra in /Applications of a standard account) cannot be swapped: say so now.
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            Trace.log("UPDATE: \(target.deletingLastPathComponent().path) is not writable")
            return false
        }
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; TARGET="$3"; WORK="$4"
        LOG="$WORK/swap.log"
        for i in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.3; done
        # Indra did not quit (the quit prompt was cancelled): nothing is replaced.
        if kill -0 "$PID" 2>/dev/null; then echo "Indra is still running: no swap ($(date))" >> "$LOG"; exit 0; fi
        {
          echo "swap $(date)"
          OLD="$WORK/Indra.previous.app"
          rm -rf "$OLD"
          if [ -d "$TARGET" ]; then mv "$TARGET" "$OLD"; fi
          if ditto "$NEW" "$TARGET"; then
            xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
            open "$TARGET"
            echo "done"
          else
            echo "copy failed: putting the old app back"
            rm -rf "$TARGET"
            if [ -d "$OLD" ]; then mv "$OLD" "$TARGET"; open "$TARGET"; fi
          fi
        } >> "$LOG" 2>&1
        """
        let scriptURL = work.appendingPathComponent("swap.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup + & so the swap outlives Indra; its output goes to the log file only.
        process.arguments = ["-c", "nohup /bin/bash '\(scriptURL.path)' \(ProcessInfo.processInfo.processIdentifier) '\(built.path)' '\(target.path)' '\(work.path)' >/dev/null 2>&1 &"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        Trace.log("UPDATE: swap started for \(target.path); quitting")
        // v553: Indra quits for the update without the fingerprint / password question of a normal quit (the person has just
        // confirmed the update). Up to v552 that question came up behind other windows and nothing seemed to happen.
        quittingForUpdate = true
        Task { @MainActor in
            // A moment for the script to start, then the normal quit.
            try? await Task.sleep(nanoseconds: 600_000_000)
            NSApp.terminate(nil)
            // If anything still held the quit back, Indra leaves anyway: the swap script is already waiting for it.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if UpdateManager.shared.quittingForUpdate {
                IndraLog.cleanExit()
                exit(0)
            }
        }
        // If Indra is still here after a long while, the update is offered again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000_000)
            guard let self, case .updating = self.state else { return }
            self.quittingForUpdate = false
            self.state = .available(version: max(self.lastAvailable, Self.currentBuild + 1))
        }
        return true
    }

    // MARK: - Running a script

    /// v546: the reason is decided from git's own words, not from any "401" or "403" that happens to be in the output (a build log
    /// is full of numbers), and it says what to DO on this Mac.
    private static func explain(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("indra_err no-git") {
            return "git is not installed on this Mac. Install the Xcode command line tools (run xcode-select --install in Terminal), then try again."
        }
        if text.contains("indra_err no-xcode") {
            return "Xcode is needed on this Mac to build the update. Install Xcode, open it once, then try again."
        }
        let authWords = ["authentication failed", "could not read username", "could not read password", "terminal prompts disabled",
                         "invalid username or password", "requested url returned error: 401", "requested url returned error: 403",
                         "requested url returned error: 404", "repository not found", "permission denied", "write access to repository not granted"]
        if authWords.contains(where: { text.contains($0) }) {
            // v549: only the developer is told about the token; everybody else just sees that nothing is published.
            guard DeveloperAccess.isUnlocked else { return "No published version was found. Try again later." }
            return UpdateToken.isSaved
                ? "GitHub did not accept the saved access token (expired, wrong, or no read access to the repository). Paste a new one below."
                : "This Mac is not signed in to GitHub. Paste a GitHub access token below (one time); no Terminal is needed."
        }
        if text.contains("could not resolve host") || text.contains("network is unreachable") || text.contains("timed out")
            || text.contains("connection reset") || text.contains("the internet connection appears to be offline") {
            return "No connection to GitHub."
        }
        if text.contains("xcodebuild: error") && text.contains("requires xcode") || text.contains("xcode-select: error") {
            return "Xcode is needed on this Mac to build the update."
        }
        if let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("error:") || $0.lowercased().hasPrefix("fatal:") }) {
            return String(line.prefix(180))
        }
        return "Details are in the problem report."
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var all = ""
        private let onLine: @Sendable (String) -> Void
        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func append(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            var lines: [String] = []
            lock.lock()
            pending += text
            while let range = pending.range(of: "\n") {
                lines.append(String(pending[pending.startIndex..<range.lowerBound]))
                pending.removeSubrange(pending.startIndex..<range.upperBound)
            }
            all += text
            if all.count > 40_000 { all = String(all.suffix(30_000)) }
            lock.unlock()
            for line in lines where !line.isEmpty { onLine(line) }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return all
        }
    }

    /// Runs a bash script in the background with a time limit; never blocks the caller's thread.
    private static func run(script: String, limit: TimeInterval,
                            onLine: @escaping @Sendable (String) -> Void) async -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(UpdateToken.gitEnvironment()) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collector = Collector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data) }
        }
        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let outcome: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { collector.append(rest) }
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.append(Data("could not start: \(error.localizedDescription)\n".utf8))
                continuation.resume(returning: -1)
            }
        }
        watchdog.cancel()
        return (outcome, collector.text)
    }
}

extension Notification.Name {
    /// v553: the update state changed (a new version was found, an update started, ...). The notch shows the update card and symbol from it.
    static let indraUpdateStateChanged = Notification.Name("indraUpdateStateChanged")
}
