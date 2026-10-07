import AppKit
import AVFoundation
import Darwin
import Foundation
import Speech
import WebKit

// MARK: - Shared State Model

struct SpotifyPlayerState: Codable, Equatable {
    var trackId: String
    var kind: String                 // track, playlist, album, artist, episode
    var title: String
    var artist: String
    var audioUrl: String?            // Direct MP3/AAC stream URL when resolved
    var artworkUrl: String?          // Album cover URL (Spotify oEmbed or iTunes 600x600)
    var artworkGeneration: Int?      // Incremented whenever /tmp/claude-spotify-mod-cover.png is updated
    var controllerMode: String       // mini, side-panel, popup
    var position: String             // top-right, top-left, bottom-right, bottom-left, right-side, left-side, center, custom
    var sizePreset: String           // mini, compact, large, sidebar
    var customX: Double?
    var customY: Double?
    var customWidth: Double?
    var customHeight: Double?
    var opacity: Double
    var isPinned: Bool
    var isPaused: Bool
    var isMuted: Bool
    var isLoggedIn: Bool?
    var shouldShowLogin: Bool?
    var shouldLogout: Bool?
    var lastVoiceQuery: String?
    var shouldStartVoice: Bool?
    var ownerPid: Int?
    var ownerPids: [Int]?
    var commandSeq: Int
    var shouldQuit: Bool
    var updatedAt: Double

    static let stateFilePath = "/tmp/claude-spotify-mod-state.json"
    static let coverPngPath = "/tmp/claude-spotify-mod-cover.png"

    static func defaultState() -> SpotifyPlayerState {
        SpotifyPlayerState(
            trackId: "0VjIjW4GlUZAMYd2vXMi3b",
            kind: "track",
            title: "Blinding Lights",
            artist: "The Weeknd",
            audioUrl: nil,
            artworkUrl: nil,
            artworkGeneration: 1,
            controllerMode: "mini",
            position: "top-right",
            sizePreset: "mini",
            customX: nil,
            customY: nil,
            customWidth: nil,
            customHeight: nil,
            opacity: 0.96,
            isPinned: true,
            isPaused: false,
            isMuted: false,
            isLoggedIn: false,
            shouldShowLogin: false,
            shouldLogout: false,
            lastVoiceQuery: nil,
            shouldStartVoice: false,
            ownerPid: nil,
            ownerPids: nil,
            commandSeq: 1,
            shouldQuit: false,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    static func load() -> SpotifyPlayerState {
        let url = URL(fileURLWithPath: stateFilePath)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SpotifyPlayerState.self, from: data) else {
            return defaultState()
        }
        return decoded
    }

    func save() {
        let url = URL(fileURLWithPath: Self.stateFilePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Parser & Position Helpers

enum SpotifyParser {
    static func extractTarget(from raw: String, defaultKind: String = "track") -> (kind: String, id: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":").map(String.init)
            if parts.count >= 3 {
                return (parts[1].lowercased(), String(parts[2].prefix(22)))
            }
        }
        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host.contains("spotify") {
            let parts = url.pathComponents.filter { $0 != "/" && $0 != "embed" && !$0.hasPrefix("intl-") }
            if parts.count >= 2 {
                return (parts[0].lowercased(), String(parts[1].prefix(22)))
            }
        }
        return (defaultKind, String(trimmed.prefix(32)))
    }

    static func cleanSearchQuery(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "how about ",
            "what about ",
            "can you play ",
            "could you play ",
            "please play ",
            "play some ",
            "play ",
            "put on ",
            "listen to ",
            "search for ",
            "search ",
            "find ",
            "i want to hear ",
            "let's hear "
        ]
        let lower = q.lowercased()
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                q = String(q.dropFirst(prefix.count))
                break
            }
        }
        q = q.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return q.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : q
    }

    static func normalizePosition(_ raw: String) -> String {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "tr", "top-right", "topright", "ne": return "top-right"
        case "tl", "top-left", "topleft", "nw": return "top-left"
        case "br", "bottom-right", "bottomright", "se": return "bottom-right"
        case "bl", "bottom-left", "bottomleft", "sw": return "bottom-left"
        case "right", "right-side", "r", "east", "dock-right", "pull-right": return "right-side"
        case "left", "left-side", "l", "west", "dock-left", "pull-left": return "left-side"
        case "tc", "top-center", "top", "north": return "top-center"
        case "bc", "bottom-center", "bottom", "south": return "bottom-center"
        case "c", "center", "middle": return "center"
        case "custom": return "custom"
        default: return raw.lowercased()
        }
    }

    static func normalizeMode(_ raw: String) -> String {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "mini", "tiny", "pill", "bar", "controller", "inline": return "mini"
        case "side-panel", "panel", "side", "sidebar", "pull", "drawer": return "side-panel"
        case "popup", "pop-up", "window", "compact", "card", "compact-card", "float": return "popup"
        default: return "mini"
        }
    }
}

// MARK: - Album Cover PNG Writer (Writes real album cover PNG to /tmp/claude-spotify-mod-cover.png)

enum AlbumArtManager {
    static let targetSize = 360

    @discardableResult
    static func writeCoverPng(from imageData: Data) -> Bool {
        guard let image = NSImage(data: imageData) else { return false }
        let size = targetSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32
        ) else {
            return false
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            image.draw(
                in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        let fileUrl = URL(fileURLWithPath: SpotifyPlayerState.coverPngPath)
        do {
            try pngData.write(to: fileUrl, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func writeFallbackCoverPng(title: String, artist: String) {
        let size = targetSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32
        ) else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let rect = NSRect(x: 0, y: 0, width: size, height: size)
            NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.07, alpha: 1.0).setFill()
            NSBezierPath(rect: rect).fill()

            let discRect = NSRect(x: 36, y: 36, width: size - 72, height: size - 72)
            NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.12, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: discRect).fill()

            NSColor(calibratedRed: 0.11, green: 0.73, blue: 0.33, alpha: 0.85).setStroke()
            let ring = NSBezierPath(ovalIn: discRect)
            ring.lineWidth = 4
            ring.stroke()

            let innerRect = NSRect(x: size / 2 - 44, y: size / 2 - 44, width: 88, height: 88)
            NSColor(calibratedRed: 0.11, green: 0.73, blue: 0.33, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: innerRect).fill()

            let holeRect = NSRect(x: size / 2 - 12, y: size / 2 - 12, width: 24, height: 24)
            NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.07, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: holeRect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        if let pngData = rep.representation(using: .png, properties: [:]) {
            let fileUrl = URL(fileURLWithPath: SpotifyPlayerState.coverPngPath)
            try? pngData.write(to: fileUrl, options: .atomic)
        }
    }

    static func upgradeArtworkResolution(_ urlString: String) -> String {
        return urlString
            .replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
            .replacingOccurrences(of: "60x60bb.jpg", with: "600x600bb.jpg")
    }

    @discardableResult
    static func fetchAndSaveCoverSynchronously(urlString: String, timeout: TimeInterval = 2.0) -> Bool {
        let hiRes = upgradeArtworkResolution(urlString)
        guard let url = URL(string: hiRes) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ok = false

        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data {
                ok = writeCoverPng(from: data)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout)
        return ok
    }

    @discardableResult
    static func fetchAndSaveCoverAsync(urlString: String) async -> Bool {
        let hiRes = upgradeArtworkResolution(urlString)
        guard let url = URL(string: hiRes) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return false }
        return writeCoverPng(from: data)
    }
}

// MARK: - AppleScript Bridge to Native Spotify.app (when installed)

enum NativeSpotifyAppBridge {
    static func isSpotifyRunning() -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    static func sendCommand(_ scriptBody: String) {
        guard isSpotifyRunning() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Spotify\" to \(scriptBody)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    static func playURI(_ uri: String) {
        sendCommand("play track \"\(uri)\"")
    }

    static func setPaused(_ paused: Bool) {
        sendCommand(paused ? "pause" : "play")
    }
}

// MARK: - Audio Stream & Artwork Resolver

struct ResolvedAudioQueue {
    var urls: [URL]
    var title: String?
    var artist: String?
    var trackId: String?
    var artworkUrl: String?
    var updatedCoverPng: Bool
}

enum AudioStreamResolver {
    private struct ITunesResponse: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let previewUrl: String?
            let artworkUrl100: String?
        }
        let results: [Item]?
    }

    static func resolveStreams(for state: SpotifyPlayerState) async -> ResolvedAudioQueue {
        var collected: [URL] = []
        var bestTitle: String? = nil
        var bestArtist: String? = nil
        var bestId: String? = nil
        var bestArtworkUrl: String? = state.artworkUrl

        if let direct = state.audioUrl, !direct.isEmpty, let u = URL(string: direct) {
            collected.append(u)
        }

        let isSpotifyId = state.trackId.count == 22 && state.trackId.allSatisfy { $0.isLetter || $0.isNumber }
        if isSpotifyId, let embedUrl = URL(string: "https://open.spotify.com/embed/\(state.kind)/\(state.trackId)") {
            var req = URLRequest(url: embedUrl)
            req.timeoutInterval = 5.0
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let html = String(data: data, encoding: .utf8) {
                let pattern = #"https://p\.scdn\.co/mp3-preview/[A-Za-z0-9]+"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
                    let matches = regex.matches(in: html, range: nsRange)
                    for m in matches {
                        if let r = Range(m.range, in: html), let u = URL(string: String(html[r])) {
                            if !collected.contains(u) {
                                collected.append(u)
                            }
                        }
                    }
                }
                if bestArtworkUrl == nil || bestArtworkUrl?.isEmpty == true {
                    let imgPattern = #"https://i\.scdn\.co/image/[A-Za-z0-9]+"#
                    if let imgRegex = try? NSRegularExpression(pattern: imgPattern),
                       let match = imgRegex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                       let r = Range(match.range, in: html) {
                        bestArtworkUrl = String(html[r])
                    }
                }
            }
        }

        var rawQuery = state.title
        let genericArtists: Set<String> = ["spotify", "spotify search", "spotify voice / search", ""]
        if !genericArtists.contains(state.artist.lowercased()) {
            rawQuery = "\(state.title) \(state.artist)"
        }
        let cleanedQuery = SpotifyParser.cleanSearchQuery(rawQuery)
        if !cleanedQuery.isEmpty,
           let encoded = cleanedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let searchUrl = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=10&term=\(encoded)") {
            var req = URLRequest(url: searchUrl)
            req.timeoutInterval = 5.0
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let parsed = try? JSONDecoder().decode(ITunesResponse.self, from: data),
               let items = parsed.results {
                for (idx, item) in items.enumerated() {
                    if idx == 0 {
                        bestTitle = item.trackName
                        bestArtist = item.artistName
                        if let tid = item.trackId {
                            bestId = String(tid)
                        }
                        if bestArtworkUrl == nil || bestArtworkUrl?.isEmpty == true, let art = item.artworkUrl100 {
                            bestArtworkUrl = AlbumArtManager.upgradeArtworkResolution(art)
                        }
                    }
                    if let p = item.previewUrl, let u = URL(string: p), !collected.contains(u) {
                        collected.append(u)
                    }
                }
            }
        }

        var wroteCover = false
        if let artUrl = bestArtworkUrl, !artUrl.isEmpty {
            wroteCover = await AlbumArtManager.fetchAndSaveCoverAsync(urlString: artUrl)
        }
        if !wroteCover && !FileManager.default.fileExists(atPath: SpotifyPlayerState.coverPngPath) {
            AlbumArtManager.writeFallbackCoverPng(title: bestTitle ?? state.title, artist: bestArtist ?? state.artist)
            wroteCover = true
        }

        return ResolvedAudioQueue(
            urls: collected,
            title: bestTitle,
            artist: bestArtist,
            trackId: bestId,
            artworkUrl: bestArtworkUrl,
            updatedCoverPng: wroteCover
        )
    }
}

// MARK: - Floating Panel (Used for Popup mode and Spotify Login window)

final class FloatingSpotifyPanel: NSPanel {
    var isProgrammaticMove = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = true
        self.minSize = NSSize(width: 280, height: 120)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Daemon Application Delegate

@MainActor
final class SpotifyMiniAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, NSTextFieldDelegate {
    private var panel: FloatingSpotifyPanel!
    private var webView: WKWebView!
    private var titleLabel: NSTextField!
    private var searchField: NSTextField!
    private var voiceBtn: NSButton!
    private var loginBtn: NSButton!
    private var playPauseBtn: NSButton!
    private var currentState: SpotifyPlayerState = SpotifyPlayerState.load()
    private var loadedTargetKey: String = ""
    private var lastAppliedSeq: Int = -1
    private var pollTimer: Timer?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isListeningVoice = false
    private var isLoginWindowActive = false

    private var queuePlayer: AVQueuePlayer?
    private var currentStreamUrls: [URL] = []
    private var endObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        checkSpotifyCookieLoginState()
        applyState(currentState, forceReloadTrack: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStateFile()
            }
        }
    }

    private func setupWindow() {
        let rect = computeWindowRect(for: currentState)
        panel = FloatingSpotifyPanel(contentRect: rect)
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.06, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.0
        container.layer?.borderColor = NSColor(calibratedRed: 0.11, green: 0.73, blue: 0.33, alpha: 0.45).cgColor
        container.autoresizingMask = [.width, .height]

        let headerHeight: CGFloat = 56
        let header = NSView(frame: NSRect(x: 0, y: rect.height - headerHeight, width: rect.width, height: headerHeight))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.08, alpha: 0.98).cgColor
        header.autoresizingMask = [.width, .minYMargin]

        titleLabel = NSTextField(labelWithString: "Spotify")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 0.11, green: 0.73, blue: 0.33, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 10, y: 34, width: max(80, rect.width - 210), height: 16)
        titleLabel.autoresizingMask = [.width]
        header.addSubview(titleLabel)

        let controlsStack = NSStackView()
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 4
        controlsStack.frame = NSRect(x: rect.width - 198, y: 32, width: 190, height: 20)
        controlsStack.autoresizingMask = [.minXMargin]

        loginBtn = makeHeaderButton("Login", tooltip: "Login with Spotify", width: 48, action: #selector(openLoginSheet))
        voiceBtn = makeHeaderButton("Voice", tooltip: "Voice Search", width: 44, action: #selector(toggleVoiceSearch))
        playPauseBtn = makeHeaderButton("⏸", tooltip: "Play / Pause", width: 34, action: #selector(togglePlayPause))
        let closeBtn = makeHeaderButton("Close", tooltip: "Close Window", width: 44, action: #selector(closePlayer))

        for b in [loginBtn!, voiceBtn!, playPauseBtn!, closeBtn] {
            controlsStack.addArrangedSubview(b)
        }
        header.addSubview(controlsStack)

        searchField = NSTextField(frame: NSRect(x: 10, y: 6, width: rect.width - 20, height: 22))
        searchField.placeholderString = "Search song or artist..."
        searchField.font = NSFont.systemFont(ofSize: 11)
        searchField.textColor = .white
        searchField.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
        searchField.isBezeled = true
        searchField.bezelStyle = .roundedBezel
        searchField.target = self
        searchField.action = #selector(onSearchFieldSubmitted)
        searchField.autoresizingMask = [.width]
        header.addSubview(searchField)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: rect.width, height: max(40, rect.height - headerHeight)), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        container.addSubview(webView)
        container.addSubview(header)

        panel.contentView = container
        if currentState.controllerMode == "popup" {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func makeHeaderButton(_ title: String, tooltip: String, width: CGFloat, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        btn.contentTintColor = .white
        btn.toolTip = tooltip
        btn.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        return btn
    }

    // MARK: - Spotify Account Login Flow

    private func checkSpotifyCookieLoginState() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self else { return }
                let hasAuthCookie = cookies.contains { c in
                    c.domain.contains("spotify.com") && (c.name == "sp_dc" || c.name == "sp_key")
                }
                if self.currentState.isLoggedIn != hasAuthCookie {
                    var st = SpotifyPlayerState.load()
                    st.isLoggedIn = hasAuthCookie
                    st.save()
                    self.currentState = st
                }
                self.loginBtn?.title = hasAuthCookie ? "Logged In" : "Login"
            }
        }
    }

    @objc private func openLoginSheet() {
        isLoginWindowActive = true
        NSApp.setActivationPolicy(.regular)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let loginRect = NSRect(
            x: screen.midX - 220,
            y: screen.midY - 310,
            width: 440,
            height: 620
        )
        panel.isProgrammaticMove = true
        panel.setFrame(loginRect, display: true, animate: false)
        panel.isProgrammaticMove = false
        panel.alphaValue = 1.0
        titleLabel.stringValue = "Spotify Login - Sign in to your account"
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let loginUrl = URL(string: "https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F") {
            webView.load(URLRequest(url: loginUrl))
        }
    }

    private func performLogout() {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            for cookie in cookies where cookie.domain.contains("spotify") {
                store.httpCookieStore.delete(cookie)
            }
            Task { @MainActor in
                guard let self = self else { return }
                var st = SpotifyPlayerState.load()
                st.isLoggedIn = false
                st.shouldLogout = false
                st.save()
                self.currentState = st
                self.loginBtn?.title = "Login"
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self else { return }
                let hasAuthCookie = cookies.contains { c in
                    c.domain.contains("spotify.com") && (c.name == "sp_dc" || c.name == "sp_key")
                }
                self.loginBtn?.title = hasAuthCookie ? "Logged In" : "Login"
                if hasAuthCookie {
                    var st = SpotifyPlayerState.load()
                    if st.isLoggedIn != true {
                        st.isLoggedIn = true
                        st.shouldShowLogin = false
                        st.save()
                        self.currentState = st
                    }
                    if self.isLoginWindowActive,
                       let host = webView.url?.host?.lowercased(),
                       host.contains("open.spotify.com") {
                        // Login completed: return window to configured controllerMode
                        self.isLoginWindowActive = false
                        NSApp.setActivationPolicy(.accessory)
                        self.applyState(st, forceReloadTrack: true)
                    }
                }
            }
        }
    }

    @objc private func onSearchFieldSubmitted() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        applySearchOrVoiceQuery(query)
    }

    private func applySearchOrVoiceQuery(_ query: String) {
        let cleaned = SpotifyParser.cleanSearchQuery(query)
        var st = SpotifyPlayerState.load()
        st.lastVoiceQuery = cleaned
        st.shouldStartVoice = false
        st.title = cleaned
        st.artist = "Spotify Search"
        st.audioUrl = nil
        st.artworkUrl = nil
        let lower = cleaned.lowercased()
        if lower == "lofi" || lower == "lofi beats" {
            st.trackId = "37i9dQZF1DWWQRwui0ExPn"
            st.kind = "playlist"
            st.title = "lofi beats"
        } else if lower == "coding" || lower == "coding mode" {
            st.trackId = "37i9dQZF1DX5trt9i14X7j"
            st.kind = "playlist"
            st.title = "Coding Mode"
        } else {
            st.trackId = "search-\(Int(Date().timeIntervalSince1970))"
            st.kind = "track"
        }
        st.isPaused = false
        st.commandSeq += 1
        st.updatedAt = Date().timeIntervalSince1970
        st.save()
        applyState(st, forceReloadTrack: true)
    }

    @objc private func toggleVoiceSearch() {
        if isListeningVoice {
            stopVoiceCapture()
            return
        }
        startVoiceCapture()
    }

    private func startVoiceCapture() {
        isListeningVoice = true
        voiceBtn.title = "Stop"
        searchField.placeholderString = "Listening... Speak song or artist"
        if currentState.controllerMode == "popup" {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
        }

        queuePlayer?.pause()

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                if status != .authorized {
                    self.isListeningVoice = false
                    self.voiceBtn.title = "Voice"
                    self.searchField.placeholderString = "Search song or artist..."
                    if !self.currentState.isPaused {
                        self.queuePlayer?.play()
                    }
                    return
                }
                self.beginSpeechSession()
            }
        }
    }

    private func beginSpeechSession() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            stopVoiceCapture()
            return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            stopVoiceCapture()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let res = result {
                    let spoken = res.bestTranscription.formattedString
                    self.searchField.stringValue = spoken
                    if res.isFinal {
                        self.stopVoiceCapture()
                        self.applySearchOrVoiceQuery(spoken)
                    }
                }
                if error != nil {
                    self.stopVoiceCapture()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isListeningVoice else { return }
                let captured = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.stopVoiceCapture()
                if !captured.isEmpty {
                    self.applySearchOrVoiceQuery(captured)
                } else if !self.currentState.isPaused {
                    self.queuePlayer?.play()
                }
            }
        }
    }

    private func stopVoiceCapture() {
        isListeningVoice = false
        voiceBtn?.title = "Voice"
        searchField?.placeholderString = "Search song or artist..."
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    @objc private func togglePlayPause() {
        var st = SpotifyPlayerState.load()
        st.isPaused.toggle()
        st.commandSeq += 1
        st.updatedAt = Date().timeIntervalSince1970
        st.save()
        applyState(st, forceReloadTrack: false)
    }

    @objc private func closePlayer() {
        if isLoginWindowActive {
            isLoginWindowActive = false
            NSApp.setActivationPolicy(.accessory)
        }
        var st = SpotifyPlayerState.load()
        st.shouldShowLogin = false
        if st.controllerMode == "popup" {
            st.controllerMode = "mini"
        }
        st.commandSeq += 1
        st.updatedAt = Date().timeIntervalSince1970
        st.save()
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard !panel.isProgrammaticMove, !isLoginWindowActive else { return }
        let frame = panel.frame
        var st = SpotifyPlayerState.load()
        st.position = "custom"
        st.customX = Double(frame.origin.x)
        st.customY = Double(frame.origin.y)
        st.customWidth = Double(frame.size.width)
        st.customHeight = Double(frame.size.height)
        st.updatedAt = Date().timeIntervalSince1970
        st.save()
        currentState = st
    }

    private func checkStateFile() {
        var latest = SpotifyPlayerState.load()
        if latest.shouldQuit {
            queuePlayer?.pause()
            queuePlayer?.removeAllItems()
            NSApp.terminate(nil)
            return
        }
        var watchedPids = latest.ownerPids ?? []
        if let single = latest.ownerPid, !watchedPids.contains(single) {
            watchedPids.append(single)
        }
        for pid in watchedPids where pid > 1 {
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                queuePlayer?.pause()
                queuePlayer?.removeAllItems()
                NativeSpotifyAppBridge.setPaused(true)
                latest.shouldQuit = true
                latest.isPaused = true
                latest.save()
                NSApp.terminate(nil)
                return
            }
        }
        if latest.shouldShowLogin == true {
            latest.shouldShowLogin = false
            latest.save()
            currentState = latest
            lastAppliedSeq = latest.commandSeq
            openLoginSheet()
            return
        }
        if latest.shouldLogout == true {
            latest.shouldLogout = false
            latest.save()
            currentState = latest
            performLogout()
            return
        }
        if latest.shouldStartVoice == true {
            latest.shouldStartVoice = false
            latest.save()
            currentState = latest
            if !isListeningVoice {
                startVoiceCapture()
            }
            return
        }
        if latest != currentState || latest.commandSeq != lastAppliedSeq {
            let nextKey = "\(latest.kind):\(latest.trackId):\(latest.title):\(latest.audioUrl ?? "")"
            let trackChanged = nextKey != loadedTargetKey
            applyState(latest, forceReloadTrack: trackChanged)
        }
    }

    private func applyState(_ state: SpotifyPlayerState, forceReloadTrack: Bool) {
        let isNewCommand = state.commandSeq != lastAppliedSeq
        currentState = state
        lastAppliedSeq = state.commandSeq

        if isNewCommand && state.shouldShowLogin != true && isLoginWindowActive {
            isLoginWindowActive = false
            NSApp.setActivationPolicy(.accessory)
        }

        if !isLoginWindowActive {
            titleLabel.stringValue = "\(state.title) - \(state.artist)"
            playPauseBtn.title = state.isPaused ? "▶" : "⏸"
            loginBtn.title = (state.isLoggedIn == true) ? "Logged In" : "Login"
            panel.alphaValue = CGFloat(max(0.25, min(1.0, state.opacity)))
            panel.level = state.isPinned ? .floating : .normal

            let targetRect = computeWindowRect(for: state)
            if panel.frame != targetRect {
                panel.isProgrammaticMove = true
                panel.setFrame(targetRect, display: true, animate: false)
                panel.isProgrammaticMove = false
            }

            if state.controllerMode == "popup" {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }

        let targetKey = "\(state.kind):\(state.trackId):\(state.title):\(state.audioUrl ?? "")"
        if forceReloadTrack && !state.trackId.isEmpty {
            loadedTargetKey = targetKey
            if state.controllerMode == "popup" && !isLoginWindowActive {
                let isSpotifyId = state.trackId.count == 22 && state.trackId.allSatisfy { $0.isLetter || $0.isNumber }
                let embedId = isSpotifyId ? state.trackId : "0VjIjW4GlUZAMYd2vXMi3b"
                let embedKind = isSpotifyId ? state.kind : "track"
                let embedUrlStr = "https://open.spotify.com/embed/\(embedKind)/\(embedId)?utm_source=generator&theme=0"
                if let url = URL(string: embedUrlStr) {
                    webView.load(URLRequest(url: url))
                }
            }
        }

        syncAudioPlayback(state: state, forceReload: forceReloadTrack)
    }

    private func syncAudioPlayback(state: SpotifyPlayerState, forceReload: Bool) {
        let isSpotifyId = state.trackId.count == 22 && state.trackId.allSatisfy { $0.isLetter || $0.isNumber }
        if NativeSpotifyAppBridge.isSpotifyRunning() && isSpotifyId {
            queuePlayer?.pause()
            if forceReload {
                NativeSpotifyAppBridge.playURI("spotify:\(state.kind):\(state.trackId)")
            } else {
                NativeSpotifyAppBridge.setPaused(state.isPaused)
            }
            return
        }

        if state.isPaused {
            queuePlayer?.pause()
            return
        }

        if !forceReload, let player = queuePlayer, !player.items().isEmpty {
            player.isMuted = state.isMuted
            player.volume = 1.0
            player.play()
            return
        }

        let requestedSeq = state.commandSeq
        Task { @MainActor in
            let resolved = await AudioStreamResolver.resolveStreams(for: state)
            guard self.currentState.commandSeq == requestedSeq, !self.currentState.shouldQuit else { return }

            var updated = SpotifyPlayerState.load()
            var didChangeMetadata = false

            if let rTitle = resolved.title, let rArtist = resolved.artist {
                let genericArtists: Set<String> = ["spotify", "spotify search", "spotify voice / search"]
                if genericArtists.contains(self.currentState.artist.lowercased()) {
                    updated.title = rTitle
                    updated.artist = rArtist
                    didChangeMetadata = true
                }
            }
            if let firstUrl = resolved.urls.first, updated.audioUrl == nil {
                updated.audioUrl = firstUrl.absoluteString
                didChangeMetadata = true
            }
            if let artUrl = resolved.artworkUrl, updated.artworkUrl == nil {
                updated.artworkUrl = artUrl
                didChangeMetadata = true
            }
            if resolved.updatedCoverPng {
                updated.artworkGeneration = (updated.artworkGeneration ?? 1) + 1
                didChangeMetadata = true
            }

            if didChangeMetadata {
                let latestOnDisk = SpotifyPlayerState.load()
                updated.position = latestOnDisk.position
                updated.controllerMode = latestOnDisk.controllerMode
                updated.sizePreset = latestOnDisk.sizePreset
                updated.shouldShowLogin = latestOnDisk.shouldShowLogin
                updated.customX = latestOnDisk.customX
                updated.customY = latestOnDisk.customY
                updated.customWidth = latestOnDisk.customWidth
                updated.customHeight = latestOnDisk.customHeight
                updated.save()
                self.currentState = updated
                if !self.isLoginWindowActive {
                    self.titleLabel.stringValue = "\(updated.title) - \(updated.artist)"
                }
            }

            guard !resolved.urls.isEmpty else { return }
            self.currentStreamUrls = resolved.urls
            self.rebuildAndPlayQueue(urls: resolved.urls, muted: self.currentState.isMuted, paused: self.currentState.isPaused)
        }
    }

    private func rebuildAndPlayQueue(urls: [URL], muted: Bool, paused: Bool) {
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }

        let items = urls.map { AVPlayerItem(url: $0) }
        let player = AVQueuePlayer(items: items)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        player.isMuted = muted
        self.queuePlayer = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self = self,
                      let currentPlayer = self.queuePlayer,
                      let finishedItem = note.object as? AVPlayerItem else { return }
                if currentPlayer.items().count <= 1 && !self.currentStreamUrls.isEmpty && !self.currentState.isPaused {
                    for u in self.currentStreamUrls {
                        currentPlayer.insert(AVPlayerItem(url: u), after: nil)
                    }
                }
                _ = finishedItem
            }
        }

        if !paused {
            player.play()
        }
    }

    private func computeWindowRect(for state: SpotifyPlayerState) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pad: CGFloat = 16

        var width: CGFloat = 340
        var height: CGFloat = 220

        if state.sizePreset.lowercased() == "large" {
            width = 420
            height = 360
        }

        if let cw = state.customWidth, let ch = state.customHeight, state.position == "custom" {
            width = CGFloat(cw)
            height = CGFloat(ch)
        }

        let pos = SpotifyParser.normalizePosition(state.position)
        var x: CGFloat
        var y: CGFloat

        switch pos {
        case "top-left":
            x = screen.minX + pad
            y = screen.maxY - height - pad
        case "top-center":
            x = screen.midX - width / 2
            y = screen.maxY - height - pad
        case "top-right":
            x = screen.maxX - width - pad
            y = screen.maxY - height - pad
        case "bottom-left":
            x = screen.minX + pad
            y = screen.minY + pad
        case "bottom-center":
            x = screen.midX - width / 2
            y = screen.minY + pad
        case "bottom-right":
            x = screen.maxX - width - pad
            y = screen.minY + pad
        case "left-side":
            x = screen.minX + pad
            y = screen.midY - height / 2
        case "right-side":
            x = screen.maxX - width - pad
            y = screen.midY - height / 2
        case "center":
            x = screen.midX - width / 2
            y = screen.midY - height / 2
        case "custom":
            x = CGFloat(state.customX ?? Double(screen.maxX - width - pad))
            y = CGFloat(state.customY ?? Double(screen.maxY - height - pad))
        default:
            let parts = pos.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 2 {
                x = CGFloat(parts[0])
                y = CGFloat(parts[1])
                if parts.count >= 4 {
                    width = CGFloat(parts[2])
                    height = CGFloat(parts[3])
                }
            } else {
                x = screen.maxX - width - pad
                y = screen.maxY - height - pad
            }
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - CLI Entrypoint

func queryProcessParentAndArgs(pid: Int32) -> (ppid: Int32, args: String)? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-ww", "-o", "ppid=,args=", "-p", String(pid)]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return nil }
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
        return (ppid, String(parts[1]))
    } catch {
        return nil
    }
}

func isPidAlive(_ pid: Int) -> Bool {
    guard pid > 1 else { return false }
    return kill(pid_t(pid), 0) == 0
}

func findForegroundClaudeClientPids() -> [Int] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-ww", "-Ao", "pid=,ppid=,args="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var ptyHostPids = Set<Int>()
        var rows: [(pid: Int, ppid: Int, args: String)] = []

        for rawLine in text.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else { continue }
            let argsStr = String(parts[2])
            let lower = argsStr.lowercased()
            if lower.contains("bg-pty-host") || lower.contains("daemon run") {
                ptyHostPids.insert(pid)
            }
            rows.append((pid, ppid, argsStr))
        }

        var foregroundClients: [Int] = []
        for row in rows {
            let lower = row.args.lowercased()
            guard lower.contains("claude") else { continue }
            if lower.contains("bg-pty-host") || lower.contains("daemon run") || lower.contains("bg-spare") || lower.contains("spotify-pip") {
                continue
            }
            if row.ppid > 1 && !ptyHostPids.contains(row.ppid) {
                if lower.contains("spotify-mod") {
                    return [row.pid]
                }
                foregroundClients.append(row.pid)
            }
        }
        return foregroundClients
    } catch {
        return []
    }
}

func resolveOwnerSessionPids() -> [Int] {
    var result: [Int] = []
    let directParent = getppid()
    var current = directParent
    var fallbackShellPid: Int? = nil
    var isUnderCcDaemon = false

    for _ in 0..<8 {
        guard current > 1, let info = queryProcessParentAndArgs(pid: current) else { break }
        let lower = info.args.lowercased()

        if lower.contains("bg-pty-host") || lower.contains("daemon run") {
            isUnderCcDaemon = true
        }

        if lower.contains("claude") && !lower.contains("bg-pty-host") && !lower.contains("daemon run") && !lower.contains("bg-spare") {
            let p = Int(current)
            if isPidAlive(p) && !result.contains(p) {
                result.append(p)
            }
        }

        if lower.contains("--spawned-by"),
           let range = info.args.range(of: #""pid"\s*:\s*(\d+)"#, options: .regularExpression) {
            let matchStr = String(info.args[range])
            let digits = matchStr.filter { $0.isNumber }
            if let spawnedByPid = Int(digits), isPidAlive(spawnedByPid), !result.contains(spawnedByPid) {
                result.append(spawnedByPid)
            }
        }

        if fallbackShellPid == nil && (lower.contains("zsh") || lower.contains("bash") || lower.contains("fish") || lower.contains("node") || lower.contains("bun")) {
            let p = Int(current)
            if isPidAlive(p) {
                fallbackShellPid = p
            }
        }

        if info.ppid <= 1 || info.ppid == current {
            break
        }
        current = info.ppid
    }

    if isUnderCcDaemon {
        for clientPid in findForegroundClaudeClientPids() where isPidAlive(clientPid) && !result.contains(clientPid) {
            result.append(clientPid)
        }
    }

    if result.isEmpty {
        if let shell = fallbackShellPid {
            result.append(shell)
        } else if isPidAlive(Int(directParent)) {
            result.append(Int(directParent))
        }
    }
    return result
}

func isDaemonRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "spotify-pip --daemon"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

func ensureDaemonLaunched() {
    guard !isDaemonRunning() else { return }
    let execPath = CommandLine.arguments[0]
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: execPath)
    proc.arguments = ["--daemon"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--daemon" {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { SpotifyMiniAppDelegate() }
    app.delegate = delegate
    app.run()
    exit(0)
}

var state = SpotifyPlayerState.load()
let subcommand = args.first?.lowercased() ?? "status"
if subcommand != "stop" && subcommand != "quit" && subcommand != "close" && subcommand != "status" {
    let owners = resolveOwnerSessionPids()
    state.ownerPid = owners.first
    state.ownerPids = owners
}

switch subcommand {
case "play", "open":
    state.shouldQuit = false
    state.isPaused = false
    state.shouldStartVoice = false
    state.shouldShowLogin = false
    state.audioUrl = nil
    state.artworkUrl = nil
    if args.count >= 2 {
        let parsed = SpotifyParser.extractTarget(from: args[1], defaultKind: state.kind)
        state.kind = parsed.kind
        state.trackId = parsed.id
    }
    var i = 2
    while i < args.count {
        let flag = args[i]
        if (flag == "--kind" || flag == "-k"), i + 1 < args.count {
            state.kind = args[i + 1].lowercased()
            i += 2
        } else if (flag == "--mode" || flag == "-m"), i + 1 < args.count {
            state.controllerMode = SpotifyParser.normalizeMode(args[i + 1])
            i += 2
        } else if (flag == "--position" || flag == "-p"), i + 1 < args.count {
            state.position = SpotifyParser.normalizePosition(args[i + 1])
            i += 2
        } else if (flag == "--size" || flag == "-s"), i + 1 < args.count {
            state.sizePreset = args[i + 1].lowercased()
            i += 2
        } else if (flag == "--title" || flag == "-t"), i + 1 < args.count {
            state.title = args[i + 1]
            i += 2
        } else if (flag == "--artist" || flag == "-a"), i + 1 < args.count {
            state.artist = args[i + 1]
            i += 2
        } else if (flag == "--audio-url" || flag == "-u"), i + 1 < args.count {
            state.audioUrl = args[i + 1]
            i += 2
        } else if (flag == "--artwork-url" || flag == "-i"), i + 1 < args.count {
            state.artworkUrl = args[i + 1]
            i += 2
        } else if (flag == "--opacity" || flag == "-o"), i + 1 < args.count, let v = Double(args[i + 1]) {
            state.opacity = max(0.25, min(1.0, v))
            i += 2
        } else {
            i += 1
        }
    }
    var wroteCover = false
    if let artUrl = state.artworkUrl, !artUrl.isEmpty {
        wroteCover = AlbumArtManager.fetchAndSaveCoverSynchronously(urlString: artUrl)
    }
    if !wroteCover {
        AlbumArtManager.writeFallbackCoverPng(title: state.title, artist: state.artist)
    }
    state.artworkGeneration = (state.artworkGeneration ?? 1) + 1
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "login", "auth":
    state.shouldQuit = false
    state.shouldShowLogin = true
    state.customX = nil
    state.customY = nil
    state.customWidth = nil
    state.customHeight = nil
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "logout":
    state.shouldQuit = false
    state.isLoggedIn = false
    state.shouldLogout = true
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "mode", "mini", "panel", "side-panel", "popup":
    state.shouldQuit = false
    state.shouldShowLogin = false
    let targetMode = subcommand == "mode" ? (args.count >= 2 ? args[1] : "mini") : subcommand
    state.controllerMode = SpotifyParser.normalizeMode(targetMode)
    state.sizePreset = state.controllerMode == "side-panel" ? "sidebar" : state.controllerMode == "mini" ? "mini" : "compact"
    if state.controllerMode == "side-panel" && state.position != "left-side" {
        state.position = "right-side"
    }
    var i = 2
    var updatedArtwork = false
    while i < args.count {
        let flag = args[i]
        if (flag == "--position" || flag == "-p"), i + 1 < args.count {
            state.position = SpotifyParser.normalizePosition(args[i + 1])
            i += 2
        } else if (flag == "--size" || flag == "-s"), i + 1 < args.count {
            state.sizePreset = args[i + 1].lowercased()
            i += 2
        } else if (flag == "--title" || flag == "-t"), i + 1 < args.count {
            state.title = args[i + 1]
            i += 2
        } else if (flag == "--artist" || flag == "-a"), i + 1 < args.count {
            state.artist = args[i + 1]
            i += 2
        } else if (flag == "--artwork-url" || flag == "-i"), i + 1 < args.count {
            let newArt = args[i + 1]
            if !newArt.isEmpty && newArt != state.artworkUrl {
                state.artworkUrl = newArt
                updatedArtwork = true
            }
            i += 2
        } else {
            i += 1
        }
    }
    if updatedArtwork || !FileManager.default.fileExists(atPath: SpotifyPlayerState.coverPngPath) {
        var wrote = false
        if let artUrl = state.artworkUrl, !artUrl.isEmpty {
            wrote = AlbumArtManager.fetchAndSaveCoverSynchronously(urlString: artUrl)
        }
        if !wrote {
            AlbumArtManager.writeFallbackCoverPng(title: state.title, artist: state.artist)
        }
        state.artworkGeneration = (state.artworkGeneration ?? 1) + 1
    }
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "position", "pos", "move":
    state.shouldQuit = false
    if args.count >= 2 {
        let rawPos = args[1]
        let normalized = SpotifyParser.normalizePosition(rawPos)
        state.position = normalized
        if args.count >= 3 && !args[2].hasPrefix("--") {
            state.sizePreset = args[2].lowercased()
        }
        let coords = rawPos.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if coords.count >= 2 {
            state.position = "custom"
            state.customX = coords[0]
            state.customY = coords[1]
            if coords.count >= 4 {
                state.customWidth = coords[2]
                state.customHeight = coords[3]
            }
        }
    }
    var i = 2
    while i < args.count {
        if args[i] == "--mode", i + 1 < args.count {
            state.controllerMode = SpotifyParser.normalizeMode(args[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "size":
    if args.count >= 2 {
        state.sizePreset = args[1].lowercased()
    }
    var i = 2
    while i < args.count {
        if args[i] == "--mode", i + 1 < args.count {
            state.controllerMode = SpotifyParser.normalizeMode(args[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "voice", "listen":
    state.shouldQuit = false
    let previousQuery = state.lastVoiceQuery
    let prevUpdated = state.updatedAt
    state.shouldStartVoice = true
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

    if args.contains("--listen") {
        let deadline = Date().addingTimeInterval(4.8)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let latest = SpotifyPlayerState.load()
            if latest.shouldStartVoice == false && latest.updatedAt > prevUpdated && latest.lastVoiceQuery != previousQuery {
                state = latest
                break
            }
        }
        state = SpotifyPlayerState.load()
    }

case "pause":
    state.isPaused = true
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()

case "resume":
    state.shouldQuit = false
    state.isPaused = false
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "toggle":
    state.shouldQuit = false
    state.isPaused.toggle()
    state.commandSeq += 1
    state.updatedAt = Date().timeIntervalSince1970
    state.save()
    ensureDaemonLaunched()

case "stop", "quit", "close":
    state.shouldQuit = true
    state.updatedAt = Date().timeIntervalSince1970
    state.save()

default:
    break
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
if let out = try? encoder.encode(state), let str = String(data: out, encoding: .utf8) {
    print(str)
}
