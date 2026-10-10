import AppKit
import Combine

public struct NowPlaying: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var elapsed: Double
    public var isPlaying: Bool
    public var sourceBundleID: String?
    public var artworkKey: String

    public var progress: Double { duration > 0 ? (elapsed / duration).clamped(0, 1) : 0 }
}

/// Reads the current track. Tries the system MediaRemote framework first (works on older macOS and for any
/// player), then falls back to scripting Music and Spotify, which macOS still allows with user consent.
@MainActor
public final class NowPlayingService: ObservableObject {
    public static let shared = NowPlayingService()

    @Published public private(set) var current: NowPlaying?
    @Published public private(set) var artwork: NSImage?

    private var timer: Timer?
    private var consumers = 0
    private var lastArtworkKey = ""
    private var isPolling = false
    private var tickAnchor = Date()
    private let scriptQueue = DispatchQueue(label: "pier.nowplaying.script")
    private let remote = MediaRemote()

    private init() {}

    /// Widgets call start/stop so polling only happens while a Now Playing widget is visible.
    public func start() {
        consumers += 1
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Elapsed time interpolated between polls so the progress bar moves smoothly.
    public func interpolatedElapsed(at date: Date) -> Double {
        guard let current else { return 0 }
        guard current.isPlaying else { return current.elapsed }
        return min(current.duration, current.elapsed + date.timeIntervalSince(tickAnchor))
    }

    // MARK: Commands

    public func togglePlayPause() { send(.toggle) }
    public func next() { send(.next) }
    public func previous() { send(.previous) }

    /// Jumps to a position in the current track (seconds).
    public func seek(to seconds: Double) {
        guard var c = current else { return }
        let target = seconds.clamped(0, max(0, c.duration))
        if let id = c.sourceBundleID, let player = ScriptedPlayer(bundleID: id) {
            let value = String(format: "%.2f", target)
            scriptQueue.async { _ = ScriptedPlayer.run("tell application id \"\(player.bundleID)\" to set player position to \(value)") }
        } else {
            remote.seek(target)
        }
        c.elapsed = target
        tickAnchor = Date()
        current = c
    }

    public var sourceAppName: String? {
        guard let id = current?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    public func openSourceApp() {
        guard let id = current?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let ref = AppRef(url: url) else { return }
        AppActions.open(ref)
    }

    private enum Command { case toggle, next, previous }

    private func send(_ command: Command) {
        if let id = current?.sourceBundleID, let player = ScriptedPlayer(bundleID: id) {
            let verb: String
            switch command {
            case .toggle: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            scriptQueue.async { [weak self] in
                _ = ScriptedPlayer.run("tell application id \"\(player.bundleID)\" to \(verb)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
            }
            if command == .toggle, var c = current { c.isPlaying.toggle(); current = c }
            return
        }
        switch command {
        case .toggle: remote.send(2)
        case .next: remote.send(4)
        case .previous: remote.send(5)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    // MARK: Polling

    private func poll() {
        // One poll at a time: a hung player or a pending Automation prompt must not queue up scripts.
        guard !isPolling else { return }
        isPolling = true
        remote.fetch { [weak self] info in
            guard let self else { return }
            if let info {
                self.isPolling = false
                self.publish(info.nowPlaying, artwork: info.artwork)
            } else {
                self.pollScriptedPlayers()
            }
        }
    }

    private func pollScriptedPlayers() {
        let running = ScriptedPlayer.all.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
        guard !running.isEmpty else {
            isPolling = false
            return publish(nil, artwork: nil)
        }
        let lastKey = lastArtworkKey
        scriptQueue.async { [weak self] in
            // Prefer a player that is actually playing.
            let states = running.compactMap { $0.read() }
            let best = states.first(where: \.isPlaying) ?? states.first
            var art: NSImage?
            if let best, best.artworkKey != lastKey, let player = ScriptedPlayer(bundleID: best.sourceBundleID ?? "") {
                art = player.readArtwork(key: best.artworkKey)
            }
            DispatchQueue.main.async {
                self?.isPolling = false
                self?.publish(best, artwork: art, keepArtwork: best?.artworkKey == lastKey)
            }
        }
    }

    private func publish(_ info: NowPlaying?, artwork newArtwork: NSImage?, keepArtwork: Bool = false) {
        tickAnchor = Date()
        if info != current { current = info }
        guard let info else {
            artwork = nil
            lastArtworkKey = ""
            return
        }
        if !keepArtwork, info.artworkKey != lastArtworkKey {
            artwork = newArtwork
            lastArtworkKey = info.artworkKey
        }
    }
}

// MARK: - Scripted players

private struct ScriptedPlayer {
    let bundleID: String
    static let all = [ScriptedPlayer(bundleID: "com.apple.Music")!, ScriptedPlayer(bundleID: "com.spotify.client")!]

    init?(bundleID: String) {
        guard ["com.apple.Music", "com.spotify.client"].contains(bundleID) else { return nil }
        self.bundleID = bundleID
    }

    var isSpotify: Bool { bundleID == "com.spotify.client" }

    func read() -> NowPlaying? {
        let durationExpr = isSpotify ? "((duration of t) / 1000)" : "(duration of t)"
        let source = """
        tell application id "\(bundleID)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (\(durationExpr) as text) & linefeed & (player position as text)
        end tell
        """
        guard let output = Self.run(source)?.stringValue, output != "stopped" else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(title: parts[1], artist: parts[2], album: parts[3], duration: num(parts[4]),
                          elapsed: num(parts[5]), isPlaying: parts[0] == "playing", sourceBundleID: bundleID,
                          artworkKey: "\(bundleID)|\(parts[1])|\(parts[3])")
    }

    func readArtwork(key: String) -> NSImage? {
        if isSpotify {
            guard let urlString = Self.run("tell application id \"\(bundleID)\" to artwork url of current track")?.stringValue,
                  let url = URL(string: urlString), let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }
        guard let descriptor = Self.run("tell application id \"\(bundleID)\" to data of artwork 1 of current track")
        else { return nil }
        return NSImage(data: descriptor.data)
    }

    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

// MARK: - MediaRemote (private framework, loaded dynamically)

private final class MediaRemote {
    struct Info { let nowPlaying: NowPlaying; let artwork: NSImage? }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias SendFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias SeekFn = @convention(c) (Double) -> Void

    private let getInfo: GetInfoFn?
    private let getPID: GetPIDFn?
    private let sendCommand: SendFn?
    private let setElapsed: SeekFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }
        getInfo = load("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
        getPID = load("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPIDFn.self)
        sendCommand = load("MRMediaRemoteSendCommand", as: SendFn.self)
        setElapsed = load("MRMediaRemoteSetElapsedTime", as: SeekFn.self)
    }

    func seek(_ seconds: Double) {
        setElapsed?(seconds)
    }

    func send(_ command: Int32) {
        _ = sendCommand?(command, nil)
    }

    func fetch(_ completion: @escaping @MainActor (Info?) -> Void) {
        guard let getInfo else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
            return
        }
        getInfo(DispatchQueue.main) { [getPID] raw in
            guard let dict = raw as? [String: Any], let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                MainActor.assumeIsolated { completion(nil) }
                return
            }
            let artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            let duration = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            var elapsed = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            if rate > 0, let stamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                elapsed += Date().timeIntervalSince(stamp) * rate
            }
            let art = (dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap(NSImage.init(data:))
            let finish: (String?) -> Void = { bundleID in
                let info = NowPlaying(title: title, artist: artist, album: album, duration: duration,
                                      elapsed: elapsed, isPlaying: rate > 0, sourceBundleID: bundleID,
                                      artworkKey: "\(title)|\(album)|\(art != nil)")
                MainActor.assumeIsolated { completion(Info(nowPlaying: info, artwork: art)) }
            }
            if let getPID {
                getPID(DispatchQueue.main) { pid in
                    finish(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
                }
            } else {
                finish(nil)
            }
        }
    }
}
