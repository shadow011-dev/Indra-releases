import Foundation
import CryptoKit

/// Builds and locates the tiny helper that reads macOS "Now Playing" for every app
/// (Safari, Chrome, YouTube, Spotify, VLC, games, anything that tells macOS what it plays).
///
/// Why a helper: since macOS 15.4 the system only answers the private MediaRemote calls for
/// processes whose identity starts with `com.apple.`. A normal app gets an empty answer.
/// `/usr/bin/perl` is such a process, so the helper is a small library that perl loads;
/// it asks MediaRemote and prints one JSON line per change on stdout.
///
/// The library is built once when Indra itself is built (Helper/build-helper.sh) and ships inside the app,
/// so the Mac it runs on needs no Xcode and no command line tools. It is copied to Application Support
/// (outside the signed app, 0700) and checked by SHA-256 before every launch. Only a build that lacks the
/// bundled library falls back to compiling the bundled source, and only when a compiler is really installed.
enum NowPlayingHelper {
    /// Bump when `perlScript` or the library change; forces a reinstall.
    static let version = "4"

    struct Paths: Sendable {
        let script: URL
        let library: URL
    }

    enum PrepareError: Error, Sendable {
        case sandboxed
        case failed(String)
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Indra/NowPlaying", isDirectory: true)
    }

    static var logURL: URL { directory.appendingPathComponent("nowplaying.log") }
    private static var hashURL: URL { directory.appendingPathComponent("indra_np.sha256") }

    // MARK: - Integrity

    /// perl loads the library with the privileges of an Apple-signed process, so a swapped library would run with
    /// them. The folder is private to the user (0700), the files are 0600, the library's SHA-256 is recorded when
    /// it is built, and it is checked again before every launch of the helper (and before the library is trusted
    /// as "up to date"); anything that does not match is rebuilt from the source inside the app.
    private static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func lockDown(_ url: URL, mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// True when the helper files on disk are exactly the ones Indra wrote.
    static func verify(_ paths: Paths) -> Bool {
        guard let scriptText = try? String(contentsOf: paths.script, encoding: .utf8), scriptText == perlScript,
              let recorded = try? String(contentsOf: hashURL, encoding: .utf8),
              let actual = sha256Hex(of: paths.library) else { return false }
        return recorded.trimmingCharacters(in: .whitespacesAndNewlines) == actual
    }

    // MARK: - Prepare (blocking: call off the main thread)

    static func prepare() -> Result<Paths, PrepareError> {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return .failure(.sandboxed)
        }
        let fm = FileManager.default
        let dir = directory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            IndraLog.error("Now-playing helper: could not create its folder", error)
            return .failure(.failed("Could not create \(dir.path)"))
        }
        lockDown(dir, mode: 0o700)

        let script = dir.appendingPathComponent("indra_np.pl")
        let library = dir.appendingPathComponent("indra_np.dylib")
        let source = dir.appendingPathComponent("indra_np.m")
        let stamp = dir.appendingPathComponent("version")

        do {
            try perlScript.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            IndraLog.error("Now-playing helper: could not write its files", error)
            return .failure(.failed("Could not write the helper files: \(error.localizedDescription)"))
        }

        let stamped = (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedHash = (try? String(contentsOf: hashURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedHash = sha256Hex(of: library)
        let bundledLibrary = Bundle.main.url(forResource: "indra_np", withExtension: "dylib")

        if let bundledLibrary {
            // Normal case: install the library that was built together with the app.
            guard let data = try? Data(contentsOf: bundledLibrary), !data.isEmpty else {
                log("bundled library unreadable at \(bundledLibrary.path)")
                return .failure(.failed("The Now Playing helper inside Indra is damaged; reinstall Indra."))
            }
            let bundledHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let upToDate = stamped == version && recordedHash == bundledHash && installedHash == bundledHash
            if !upToDate {
                try? fm.removeItem(at: library)
                do {
                    // Written as plain bytes: no quarantine flag or other attributes travel with it.
                    try data.write(to: library, options: .atomic)
                } catch {
                    log("could not install library: \(error.localizedDescription)")
                    return .failure(.failed("Could not install the Now Playing helper: \(error.localizedDescription)"))
                }
                try? version.write(to: stamp, atomically: true, encoding: .utf8)
                try? bundledHash.write(to: hashURL, atomically: true, encoding: .utf8)
                log("helper installed from the app (version \(version))")
            }
            for file in [script, library, stamp, hashURL] { lockDown(file, mode: 0o600) }
            return .success(Paths(script: script, library: library))
        }

        // No bundled library (a build made without Helper/build-helper.sh): compile it here, but only when a
        // compiler exists. Calling /usr/bin/clang without one makes macOS show an "install developer tools" popup.
        let upToDate = stamped == version && recordedHash != nil && recordedHash == installedHash
        if !upToDate {
            guard developerToolsInstalled() else {
                log("no bundled library and no developer tools; cannot build the helper")
                return .failure(.failed("This copy of Indra was built without the Now Playing helper. Install the latest Indra."))
            }
            guard let bundledSource = Bundle.main.url(forResource: "indra_np", withExtension: "m"),
                  let text = try? String(contentsOf: bundledSource, encoding: .utf8) else {
                log("no bundled library and no bundled source")
                return .failure(.failed("This copy of Indra was built without the Now Playing helper. Install the latest Indra."))
            }
            do { try text.write(to: source, atomically: true, encoding: .utf8) } catch {
                return .failure(.failed("Could not write the helper files: \(error.localizedDescription)"))
            }
            try? fm.removeItem(at: library)
            // Universal first (perl runs as arm64e or x86_64 depending on the Mac), then the native slice only.
            let attempts: [[String]] = [["-arch", "arm64", "-arch", "x86_64"], []]
            var lastError = ""
            for arch in attempts {
                let result = run("/usr/bin/clang",
                                 ["-dynamiclib", "-fobjc-arc", "-fblocks", "-O1",
                                  "-mmacosx-version-min=11.0", "-framework", "Foundation"]
                                 + arch + ["-o", library.path, source.path])
                if result.status == 0, fm.fileExists(atPath: library.path) { lastError = ""; break }
                lastError = result.output
            }
            guard fm.fileExists(atPath: library.path) else {
                log("compile failed:\n\(lastError)")
                return .failure(.failed("The helper could not be built; see nowplaying.log."))
            }
            try? version.write(to: stamp, atomically: true, encoding: .utf8)
            if let hash = sha256Hex(of: library) { try? hash.write(to: hashURL, atomically: true, encoding: .utf8) }
            log("helper built on this Mac (version \(version))")
        }
        for file in [source, script, library, stamp, hashURL] { lockDown(file, mode: 0o600) }
        return .success(Paths(script: script, library: library))
    }

    /// True when a compiler is really installed. `xcode-select -p` never shows the install popup, unlike running clang.
    private static func developerToolsInstalled() -> Bool {
        run("/usr/bin/xcode-select", ["-p"]).status == 0
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            IndraLog.error("Now-playing helper: could not run a tool", error)
            return (-1, error.localizedDescription)
        }
        // Read before waiting so a chatty compiler can never fill the pipe and stall.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Log

    private static let logLock = NSLock()

    static func log(_ text: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Perl loader

    /// perl is allowed to talk to MediaRemote. It loads the library and calls its entry point,
    /// which never returns (it runs the run loop and exits when Indra closes its stdin).
    static let perlScript = #"""
    use strict;
    use warnings;
    use DynaLoader;
    $| = 1;
    my $lib = shift @ARGV;
    sub fail {
        my ($msg) = @_;
        $msg = "" unless defined $msg;
        $msg =~ s/["\\\r\n]/ /g;
        print "{\"error\":\"$msg\"}\n";
        exit 2;
    }
    my $handle = DynaLoader::dl_load_file($lib, 0) or fail("load: " . (DynaLoader::dl_error() || "unknown"));
    my $symbol = DynaLoader::dl_find_symbol($handle, "indra_np_run") or fail("symbol missing");
    my $xs = DynaLoader::dl_install_xsub("main::indra_np_run", $symbol);
    &$xs();
    """#
}
