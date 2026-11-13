import AppKit

struct YouTubeItem: Sendable, Equatable {
    var title: String
    var artist: String
    var imageURL: String?
    /// Page of the video (only for "up next" suggestions).
    var url: String? = nil
}

/// What Indra could read from the YouTube tab that is playing in the browser.
struct YouTubeSnapshot: Sendable {
    var url: String
    var tabName: String
    /// False when the browser refuses to run JavaScript for Indra ("Allow JavaScript from Apple Events" is off).
    var scriptable: Bool
    var playing: Bool
    /// YouTube Music, or a youtube.com video whose category is "Music".
    var isSong: Bool
    /// Index of the playing item in `items`, -1 when unknown.
    var current: Int
    var items: [YouTubeItem]
    /// The "up next" suggestions beside a video that is not in a playlist.
    var upNext: [YouTubeItem] = []
}

enum YouTubeProbeResult: Sendable {
    /// The browser is not running, or none of its tabs is a YouTube page.
    case none
    /// macOS has not allowed Indra to control the browser.
    case denied
    case snapshot(YouTubeSnapshot)
}

/// v486: a browser Indra can read YouTube from. Safari and every Chromium browser (Chrome, Brave, Edge, Arc, Vivaldi,
/// Opera ...) can be scripted; Firefox cannot (it has no tab scripting), so for it only macOS Now Playing works.
struct YouTubeBrowser: Sendable, Equatable {
    enum Dialect: Sendable { case safari, chromium }
    let id: String
    let name: String
    let dialect: Dialect
    /// Where the person switches "Allow JavaScript from Apple Events" on.
    let javascriptHint: String

    /// AppleScript for the title of the tab `t` (Safari calls it `name`, Chromium browsers `title`).
    var tabNameExpression: String { dialect == .safari ? "name of t" : "title of t" }

    /// AppleScript that runs the (already escaped) JavaScript in the tab `t`.
    func runJavaScript(_ escaped: String) -> String {
        dialect == .safari ? "do JavaScript \"\(escaped)\" in t" : "execute t javascript \"\(escaped)\""
    }
}

enum YouTubeBrowsers {
    private static let safariHint = "Turn on Develop ▸ Allow JavaScript from Apple Events in Safari (Settings ▸ Advanced ▸ Show features for web developers)."
    private static let chromiumHint = "Turn on View ▸ Developer ▸ Allow JavaScript from Apple Events in the browser's menu bar."
    private static let developerMenuHint = "Turn on Allow JavaScript from Apple Events in the browser's Developer menu (menu bar)."

    static let all: [YouTubeBrowser] = [
        YouTubeBrowser(id: "com.apple.Safari", name: "Safari", dialect: .safari, javascriptHint: safariHint),
        YouTubeBrowser(id: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", dialect: .safari, javascriptHint: safariHint),
        YouTubeBrowser(id: "com.google.Chrome", name: "Google Chrome", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.google.Chrome.beta", name: "Google Chrome Beta", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.google.Chrome.dev", name: "Google Chrome Dev", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.google.Chrome.canary", name: "Google Chrome Canary", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.brave.Browser", name: "Brave", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.brave.Browser.beta", name: "Brave Beta", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.brave.Browser.nightly", name: "Brave Nightly", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.microsoft.edgemac", name: "Microsoft Edge", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.microsoft.edgemac.Beta", name: "Microsoft Edge Beta", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.microsoft.edgemac.Dev", name: "Microsoft Edge Dev", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.microsoft.edgemac.Canary", name: "Microsoft Edge Canary", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "company.thebrowser.Browser", name: "Arc", dialect: .chromium, javascriptHint: developerMenuHint),
        YouTubeBrowser(id: "company.thebrowser.dia", name: "Dia", dialect: .chromium, javascriptHint: developerMenuHint),
        YouTubeBrowser(id: "com.vivaldi.Vivaldi", name: "Vivaldi", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "com.operasoftware.Opera", name: "Opera", dialect: .chromium, javascriptHint: developerMenuHint),
        YouTubeBrowser(id: "com.operasoftware.OperaGX", name: "Opera GX", dialect: .chromium, javascriptHint: developerMenuHint),
        YouTubeBrowser(id: "org.chromium.Chromium", name: "Chromium", dialect: .chromium, javascriptHint: chromiumHint),
        YouTubeBrowser(id: "ru.yandex.desktop.yandex-browser", name: "Yandex Browser", dialect: .chromium, javascriptHint: chromiumHint),
    ]

    static let safari = all[0]

    /// The browser a bundle identifier belongs to. Helper processes ("com.google.Chrome.helper" ...) count as their
    /// browser; the longest matching identifier wins, so "com.google.Chrome.beta" is not taken for Chrome itself.
    static func browser(forBundleID id: String?) -> YouTubeBrowser? {
        guard let id, !id.isEmpty else { return nil }
        if let known = all
            .filter({ id == $0.id || id.hasPrefix($0.id + ".") })
            .max(by: { $0.id.count < $1.id.count }) {
            return known
        }
        return inferred(forBundleID: id)
    }

    // v564: any browser built on Chromium (Dia, Comet, Atlas, Helium, Sidekick, Thorium, a fork nobody has listed yet ...) is
    // recognised by the key every Chromium-based app carries in its Info.plist, and handled like Chrome. The answer is kept per app.
    private static let inferredLock = NSLock()
    private static var inferredFound: [String: YouTubeBrowser] = [:]
    private static var inferredNone = Set<String>()

    /// A helper process ("x.y.z.helper.renderer") counts as its app ("x.y.z"): the identifier is shortened until an app is found.
    private static func inferred(forBundleID id: String) -> YouTubeBrowser? {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if let found = inferredBrowser(exactly: parts.joined(separator: ".")) { return found }
            parts.removeLast()
        }
        return nil
    }

    private static func inferredBrowser(exactly id: String) -> YouTubeBrowser? {
        inferredLock.lock()
        defer { inferredLock.unlock() }
        if let found = inferredFound[id] { return found }
        if inferredNone.contains(id) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CrProductDirName") != nil else {
            inferredNone.insert(id)
            return nil
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let browser = YouTubeBrowser(id: id, name: name, dialect: .chromium, javascriptHint: developerMenuHint)
        inferredFound[id] = browser
        return browser
    }

    static func isRunning(_ browser: YouTubeBrowser) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty
    }

    static func isInstalled(_ browser: YouTubeBrowser) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) != nil
    }

    // The browser that last played something, remembered so a video can still be started from the side album bar
    // while a Spotify / Music song is playing (nothing in a browser is playing then).
    private static let lastKey = "lastPlayingBrowser"

    static func remember(_ browser: YouTubeBrowser) {
        guard UserDefaults.standard.string(forKey: lastKey) != browser.id else { return }
        UserDefaults.standard.set(browser.id, forKey: lastKey)
    }

    static var last: YouTubeBrowser? {
        browser(forBundleID: UserDefaults.standard.string(forKey: lastKey))
    }

    /// The browsers Indra should talk to, best first: the one that is playing, the one that played last, then every
    /// other running browser that Indra is ALREADY allowed to control (so nobody gets a permission question for a
    /// browser they only have open for something else). Blocking (asks macOS): call from a background queue only.
    static func targets(preferred: String?) -> [YouTubeBrowser] {
        var list: [YouTubeBrowser] = []
        func add(_ browser: YouTubeBrowser?) {
            guard let browser, !list.contains(browser), isRunning(browser) else { return }
            list.append(browser)
        }
        add(browser(forBundleID: preferred))
        add(last)
        if list.isEmpty { add(safari) }
        for other in all where !list.contains(other) && isRunning(other)
            && HealthMonitor.automationStatus(bundle: other.id) == 0 {
            list.append(other)
        }
        return list
    }
}

/// Talks to a browser (Safari or a Chromium browser) through Apple Events. Blocking: call from a background queue only.
/// Never launches a browser. Only YouTube tabs are touched.
enum YouTubeProbe {

    // MARK: - JavaScript run inside the tab (single quotes only, no backslashes)

    /// Returns JSON: {song, cur, playing, items:[{t, a, i}]}
    private static let readJS = [
        "(function(){try{",
        "var o={song:false,cur:-1,playing:false,items:[]};",
        "var v=document.querySelector('video');o.playing=!!(v&&!v.paused);",
        "function big(u){if(!u||u.indexOf('http')!==0)return '';return u.replace(/=w[0-9]+-h[0-9]+[^ ]*/,'=w300-h300');}",
        "if(location.host==='music.youtube.com'){",
        "o.song=true;var els=document.querySelectorAll('ytmusic-player-queue-item');var n=0;",
        "for(var k=0;k<els.length;k++){var e=els[k];if(e.closest('#counterpart-renderer'))continue;",
        "var t=e.querySelector('.song-title');var b=e.querySelector('.byline');var im=e.querySelector('img');",
        "var vid='';try{vid=e.data.videoId||'';}catch(x){}",
        "var pic=big(im?im.src:'');if(!pic&&vid)pic='https://i.ytimg.com/vi/'+vid+'/mqdefault.jpg';",
        "o.items.push({t:t?t.textContent.trim():'',a:b?b.textContent.trim():'',i:pic});",
        "if(e.hasAttribute('selected')||e.selected===true)o.cur=n;n++;}",
        "}else{",
        "var cat='';try{cat=document.getElementById('movie_player').getPlayerResponse().microformat.playerMicroformatRenderer.category;}catch(x){}",
        "o.song=(cat==='Music');",
        "var ps=document.querySelectorAll('ytd-playlist-panel-video-renderer');",
        "for(var m=0;m<ps.length;m++){var p=ps[m];",
        "var t2=p.querySelector('#video-title');var b2=p.querySelector('#byline');var im2=p.querySelector('img');",
        "var l2=p.querySelector('a#wc-endpoint');var m2=l2&&l2.href?l2.href.match(/[?&]v=([A-Za-z0-9_-]{6,})/):null;",
        "var pic2=m2?'https://i.ytimg.com/vi/'+m2[1]+'/mqdefault.jpg':(im2?big(im2.src):'');",
        "o.items.push({t:t2?t2.textContent.trim():'',a:b2?b2.textContent.trim():'',i:pic2});",
        "if(p.hasAttribute('selected'))o.cur=m;}",
        "var nx=[];var cs=document.querySelectorAll('ytd-compact-video-renderer,yt-lockup-view-model');",
        "for(var q=0;q<cs.length&&nx.length<6;q++){var c=cs[q];",
        "var a3=c.querySelector(\"a[href*='watch?v=']\");if(!a3||!a3.href)continue;",
        "var t3=c.querySelector('#video-title')||c.querySelector('h3');",
        "var b3=c.querySelector('ytd-channel-name #text')||c.querySelector('#channel-name');",
        "var im3=c.querySelector('img');",
        "var tt=t3?t3.textContent.trim():(a3.getAttribute('aria-label')||'');if(!tt)continue;",
        "nx.push({t:tt,a:b3?b3.textContent.trim():'',i:im3&&im3.src&&im3.src.indexOf('http')===0?im3.src:'',u:a3.href});}",
        "o.nx=nx;",
        "}",
        "return JSON.stringify(o);}catch(x){return '';}})()",
    ].joined()

    private static func playJS(index: Int) -> String {
        [
            "(function(){try{var target=null;",
            "if(location.host==='music.youtube.com'){",
            "var els=document.querySelectorAll('ytmusic-player-queue-item');var n=0;",
            "for(var k=0;k<els.length;k++){if(els[k].closest('#counterpart-renderer'))continue;if(n===\(index)){target=els[k];break;}n++;}",
            "if(target){var pb=target.querySelector('ytmusic-play-button-renderer');",
            "if(pb){var ib=pb.querySelector('#play-button')||pb;ib.click();}",
            "else{target.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));}}",
            "}else{var ps=document.querySelectorAll('ytd-playlist-panel-video-renderer');target=ps[\(index)];",
            "if(target){var a=target.querySelector('a#wc-endpoint');if(a){a.click();}}}",
            "return 'ok';}catch(x){return '';}})()",
        ].joined()
    }

    // MARK: - AppleScript

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs `js` in every YouTube tab (or only in tabs whose name contains `hint`) and returns
    /// "url ␟ name ␟ result" records separated by ␞.
    private static func script(browser: YouTubeBrowser, js: String, hint: String?) -> String {
        let filter = hint.map { "n contains \"\(escape($0))\"" } ?? "true"
        return """
        tell application id "\(browser.id)"
            set fs to character id 31
            set rs to character id 30
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set u to URL of t
                        if u contains "youtube.com" then
                            set n to \(browser.tabNameExpression)
                            if \(filter) then
                                set r to ""
                                try
                                    set r to (\(browser.runJavaScript(escape(js))))
                                end try
                                if r is missing value then set r to ""
                                set out to out & u & fs & n & fs & (r as text) & rs
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
    }

    private static func run(_ source: String) -> (text: String?, errorNumber: Int?) {
        // v419: one AppleScript at a time, across all of Indra. v491: with a time limit (see AppleScriptGate).
        guard AppleScriptGate.acquire() else { return (nil, -1) }
        defer { AppleScriptGate.lock.unlock() }
        guard let script = NSAppleScript(source: AppleScriptGate.bounded(source)) else { return (nil, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorNumber] as? Int ?? -1)
        }
        return (result.stringValue ?? "", nil)
    }

    // MARK: - Read

    /// `browserID`: the bundle identifier of the app that is playing (Safari when unknown). Only that browser is asked.
    static func snapshot(titleHint: String, browserID: String?) -> YouTubeProbeResult {
        let browser = YouTubeBrowsers.browser(forBundleID: browserID) ?? YouTubeBrowsers.safari
        guard YouTubeBrowsers.isRunning(browser) else { return .none }
        let reply = run(script(browser: browser, js: readJS, hint: nil))
        if reply.errorNumber == -1743 { return .denied }
        guard let text = reply.text, !text.isEmpty else { return .none }

        var candidates: [YouTubeSnapshot] = []
        for record in text.components(separatedBy: "\u{1E}") where !record.isEmpty {
            let fields = record.components(separatedBy: "\u{1F}")
            guard fields.count >= 3 else { continue }
            candidates.append(parse(url: fields[0], name: fields[1], json: fields[2]))
        }
        guard !candidates.isEmpty else { return .none }

        let wanted = titleHint.lowercased()
        let byName = wanted.isEmpty ? nil : candidates.first { $0.tabName.lowercased().contains(wanted) }
        let chosen = byName ?? candidates.first(where: { $0.playing }) ?? candidates[0]
        return .snapshot(chosen)
    }

    private static func parse(url: String, name: String, json: String) -> YouTubeSnapshot {
        let musicHost = url.contains("music.youtube.com")
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // JavaScript is switched off (or the page is not ready): the address still says a lot.
            return YouTubeSnapshot(url: url, tabName: name, scriptable: false, playing: false,
                                   isSong: musicHost, current: -1, items: [])
        }
        let items = (object["items"] as? [[String: Any]] ?? []).map { raw in
            YouTubeItem(title: raw["t"] as? String ?? "",
                        artist: raw["a"] as? String ?? "",
                        imageURL: (raw["i"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil })
        }
        let upNext = (object["nx"] as? [[String: Any]] ?? []).map { raw -> YouTubeItem in
            let link = raw["u"] as? String
            // The thumbnail made from the video id always works; the picture on the page may still be a lazy placeholder.
            let picture = link.flatMap { YouTubeProbe.thumbnail(forVideoURL: $0) }
                ?? (raw["i"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
            return YouTubeItem(title: raw["t"] as? String ?? "",
                               artist: raw["a"] as? String ?? "",
                               imageURL: picture,
                               url: link)
        }
        return YouTubeSnapshot(url: url, tabName: name, scriptable: true,
                               playing: object["playing"] as? Bool ?? false,
                               isSong: (object["song"] as? Bool ?? false) || musicHost,
                               current: (object["cur"] as? NSNumber)?.intValue ?? -1,
                               items: items,
                               upNext: upNext)
    }

    // MARK: - Video addresses

    /// The video id of a youtube.com / music.youtube.com watch address.
    static func videoID(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), parts.host?.hasSuffix("youtube.com") == true else { return nil }
        if parts.path == "/watch" {
            return parts.queryItems?.first(where: { $0.name == "v" })?.value
        }
        if parts.path.hasPrefix("/shorts/") { return String(parts.path.dropFirst("/shorts/".count)) }
        return nil
    }

    static func thumbnail(forVideoURL url: String) -> String? {
        videoID(url).map { "https://i.ytimg.com/vi/\($0)/mqdefault.jpg" }
    }

    // MARK: - Switching videos

    /// Looks at one tab: is a video playing in it right now?
    private static let playingJS = "(function(){try{var v=document.querySelector('video');return v&&!v.paused?'1':'0';}catch(x){return '0';}})()"

    /// Runs `js` in one YouTube tab at a time and stops at the first tab that answers "ok".
    /// `hint`: only tabs whose name contains it. `playingOnly`: only tabs that are playing a video right now.
    private static func firstScript(browser: YouTubeBrowser, js: String, hint: String?, playingOnly: Bool) -> String {
        let nameFilter = hint.map { "n contains \"\(escape($0))\"" } ?? "true"
        let playCheck: String
        if playingOnly {
            playCheck = """
            set p to ""
            try
                set p to (\(browser.runJavaScript(escape(playingJS))))
            end try
            set okTab to (p is "1")
            """
        } else {
            playCheck = "set okTab to true"
        }
        return """
        tell application id "\(browser.id)"
            set found to false
            repeat with w in windows
                repeat with t in tabs of w
                    if not found then
                        try
                            set u to URL of t
                            if u contains "youtube.com" then
                                set n to \(browser.tabNameExpression)
                                if \(nameFilter) then
                                    \(playCheck)
                                    if okTab then
                                        set r to ""
                                        try
                                            set r to (\(browser.runJavaScript(escape(js))))
                                        end try
                                        if r is missing value then set r to ""
                                        if (r as text) contains "ok" then set found to true
                                    end if
                                end if
                            end if
                        end try
                    end if
                end repeat
            end repeat
            if found then return "ok"
            return ""
        end tell
        """
    }

    /// Runs `js` in the best YouTube tab: the one named like the song, then any tab that is playing, then any
    /// YouTube tab. (Matching by name alone failed whenever the tab title and the song title differed, which is
    /// common with ad blockers and with videos that change their title.)
    private static func runOnFirstTab(browser: YouTubeBrowser, js: String, hint: String?) -> Bool {
        if let hint, run(firstScript(browser: browser, js: js, hint: hint, playingOnly: false)).text?.contains("ok") == true { return true }
        if run(firstScript(browser: browser, js: js, hint: nil, playingOnly: true)).text?.contains("ok") == true { return true }
        return run(firstScript(browser: browser, js: js, hint: nil, playingOnly: false)).text?.contains("ok") == true
    }

    /// The addresses of all YouTube tabs (read without JavaScript, so it works even when that is switched off).
    private static func youtubeURLs(browser: YouTubeBrowser) -> [String] {
        let source = """
        tell application id "\(browser.id)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set u to URL of t
                        if u contains "youtube.com" then set out to out & u & linefeed
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
        let text = run(source).text ?? ""
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Waits (up to about 2.4 s) until a YouTube tab shows the video with this id.
    private static func waitForTab(browser: YouTubeBrowser, showing id: String) -> Bool {
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.3)
            if youtubeURLs(browser: browser).contains(where: { $0.contains(id) }) { return true }
        }
        return false
    }

    /// Changes the address of a YouTube tab through Safari itself (needs no JavaScript permission).
    private static func nativeScript(browser: YouTubeBrowser, url: String, hint: String?) -> String {
        let nameFilter = hint.map { "(\(browser.tabNameExpression)) contains \"\(escape($0))\"" } ?? "true"
        return """
        tell application id "\(browser.id)"
            set target to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if target is missing value then
                            if (URL of t) contains "youtube.com" and \(nameFilter) then set target to t
                        end if
                    end try
                end repeat
            end repeat
            if target is missing value then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if target is missing value then
                                if (URL of t) contains "youtube.com" then set target to t
                            end if
                        end try
                    end repeat
                end repeat
            end if
            if target is missing value then return ""
            set URL of target to "\(escape(url))"
            return "ok"
        end tell
        """
    }

    /// Moves a youtube.com page to another video without reloading it (the page keeps its permission to play
    /// sound, so the new video starts at once). Nothing for YouTube Music.
    private static func inPageJS(url: String) -> String? {
        guard let id = videoID(url), id.count >= 6,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              let host = URLComponents(string: url)?.host, host.hasSuffix("youtube.com"),
              host != "music.youtube.com" else { return nil }
        return [
            "(function(){try{",
            "var app=document.querySelector('ytd-app');if(!app)return '';",
            "var ep={watchEndpoint:{videoId:'\(id)'},commandMetadata:{webCommandMetadata:{url:'/watch?v=\(id)',webPageType:'WEB_PAGE_TYPE_WATCH',rootVe:3832}}};",
            "if(typeof app.fire==='function'){app.fire('yt-navigate',{endpoint:ep});}",
            "else{app.dispatchEvent(new CustomEvent('yt-navigate',{detail:{endpoint:ep},bubbles:true,composed:true}));}",
            "return 'ok';}catch(x){return '';}})()",
        ].joined()
    }

    /// Opens another video in the tab that is playing, in the browser that is playing (or the one that played last).
    /// Tries three ways, each only if the one before did not get the tab onto the video: in-page navigation, a
    /// JavaScript address change, and the browser's own address.
    @discardableResult
    static func open(url: String, titleHint: String, browserID: String?) -> Bool {
        guard url.hasPrefix("https://"),
              !url.contains("'"), !url.contains("\\"), !url.contains("\"") else { return false }
        let hint = titleHint.isEmpty ? nil : titleHint
        for browser in YouTubeBrowsers.targets(preferred: browserID) where openIn(browser, url: url, hint: hint) {
            return true
        }
        return false
    }

    private static func openIn(_ browser: YouTubeBrowser, url: String, hint: String?) -> Bool {
        let id = videoID(url)
        if let js = inPageJS(url: url), let id, runOnFirstTab(browser: browser, js: js, hint: hint),
           waitForTab(browser: browser, showing: id) {
            return true
        }
        let href = "(function(){try{location.href='\(url)';return 'ok';}catch(x){return '';}})()"
        if runOnFirstTab(browser: browser, js: href, hint: hint) {
            guard let id else { return true }
            if waitForTab(browser: browser, showing: id) { return true }
        }
        return run(nativeScript(browser: browser, url: url, hint: hint)).text?.contains("ok") == true
    }

    /// Pauses every video playing in the YouTube tabs of the browsers Indra can control (used when another player
    /// takes over).
    @discardableResult
    static func pauseAll(browserID: String?) -> Bool {
        let js = "(function(){try{var v=document.querySelectorAll('video');for(var i=0;i<v.length;i++){v[i].pause();}return 'ok';}catch(x){return '';}})()"
        var paused = false
        for browser in YouTubeBrowsers.targets(preferred: browserID)
        where run(script(browser: browser, js: js, hint: nil)).text?.contains("ok") == true {
            paused = true
        }
        return paused
    }

    // MARK: - Play a queue item

    @discardableResult
    static func play(index: Int, titleHint: String, browserID: String?) -> Bool {
        guard index >= 0 else { return false }
        let hint = titleHint.isEmpty ? nil : titleHint
        for browser in YouTubeBrowsers.targets(preferred: browserID)
        where runOnFirstTab(browser: browser, js: playJS(index: index), hint: hint) {
            return true
        }
        return false
    }
}
