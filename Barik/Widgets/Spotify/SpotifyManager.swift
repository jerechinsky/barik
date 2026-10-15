import Foundation
import Combine
import AppKit
import Darwin
import ApplicationServices

struct SpotifyTrack {
    let id: String
    let name: String
    let artist: String
    let isPlaying: Bool
    let artworkURL: String?
}

private struct SpotifyPlaybackSnapshot: Decodable {
    let progressMs: Double?
    let isPlaying: Bool
    let item: SpotifyPlaybackItem?
}

private struct SpotifyPlaybackItem: Decodable {
    let id: String
    let name: String
    let durationMs: Double
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
}

private struct SpotifyArtist: Decodable {
    let name: String
}

private struct SpotifyAlbum: Decodable {
    let images: [SpotifyImage]
}

private struct SpotifyImage: Decodable {
    let url: String
}

private enum SpotifyPlaybackFetchResult {
    case snapshot(SpotifyPlaybackSnapshot)
    case noPlayback
    case unavailable
    case unchanged
}

/// Uses Spotify's own library button without activating its window or sending keys.
/// No broad keyboard shortcut can accidentally reach another app.
private enum SpotifyNativeLibrary {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func text(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { attribute(element, $0) as? String }.joined(separator: "\n")
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/barik/spotify-native-saved.json")
    private static var confirmed: [String: Bool] = {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }()
    private static let lock = NSRecursiveLock()

    static func remember(_ saved: Bool, trackID: String) {
        confirmed[trackID] = saved
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(confirmed) { try? data.write(to: cacheURL, options: .atomic) }
    }

    static func button(name: String, artist: String, trackID: String? = nil) -> (AXUIElement, Bool?)? {
        lock.lock()
        defer { lock.unlock() }
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let deadline = Date().addingTimeInterval(1.5)
        let expected = "Now playing: \(name) by \(artist)"
        var queue = [root]
        var visited = 0
        while !queue.isEmpty && visited < 500 && Date() < deadline {
            let node = queue.removeFirst()
            visited += 1
            if text(node).components(separatedBy: "\n").contains(expected) {
                for child in children(node) {
                    guard attribute(child, kAXRoleAttribute) as? String == kAXButtonRole else { continue }
                    let label = text(child).components(separatedBy: "\n")
                    if label.contains("Add to Liked Songs") { return (child, false) }
                    if label.contains("Remove from Liked Songs") { return (child, true) }
                    // Spotify replaces the save button with a playlist picker.
                    // Its label alone does not tell us WHICH playlist is saved.
                    if label.contains("Add to playlist") { return (child, trackID.flatMap { confirmed[$0] }) }
                }
            }
            queue.append(contentsOf: children(node))
        }
        return nil
    }

    private static func find(in subtree: AXUIElement? = nil, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first else { return nil }
        let root = subtree ?? AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let deadline = Date().addingTimeInterval(1.5)
        var queue = [root]
        var index = 0
        while index < queue.count && index < 600 && Date() < deadline {
            let element = queue[index]
            index += 1
            if predicate(element) { return element }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func playlistItem() -> (AXUIElement, Bool)? {
        guard let menu = find({ text($0).components(separatedBy: "\n").contains("Add to playlist menu") }),
              let item = find(in: menu, { element in
            text(element).components(separatedBy: "\n").contains("Liked Songs")
                && attribute(element, kAXValueAttribute) is NSNumber
        }), let value = attribute(item, kAXValueAttribute) as? NSNumber else { return nil }
        return (item, value.boolValue)
    }

    private static func closePicker() {
        if let cancel = find({ attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
            && text($0).components(separatedBy: "\n").contains("Cancel") }) {
            _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
        }
    }

    static func setSaved(_ saved: Bool, name: String, artist: String, trackID: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let (control, current) = button(name: name, artist: artist, trackID: trackID) else { return nil }
        if current == saved { return true }
        let picker = text(control).components(separatedBy: "\n").contains("Add to playlist")
        guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else { return false }
        if picker {
            // An existing save uses Spotify's playlist picker. Read the exact
            // Liked Songs selection, rather than treating any playlist as liked.
            guard let (item, selected) = playlistItem() else { closePicker(); return false }
            if selected == saved {
                remember(saved, trackID: trackID)
                closePicker()
                return true
            }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { closePicker(); return false }
            guard let done = find({ attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                && text($0).components(separatedBy: "\n").contains("Done") }),
                AXUIElementPerformAction(done, kAXPressAction as CFString) == .success else { closePicker(); return false }
        }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            // Spotify may REPLACE the button after saving. Re-acquire it each
            // time; a stale AX element can never confirm the new state.
            if let (fresh, _) = button(name: name, artist: artist, trackID: trackID) {
                let labels = text(fresh).components(separatedBy: "\n")
                if (!picker && saved && labels.contains("Add to playlist"))
                    || labels.contains(saved ? "Remove from Liked Songs" : "Add to Liked Songs") {
                    remember(saved, trackID: trackID)
                    return true
                }
                if picker && labels.contains("Add to playlist") {
                    if AXUIElementPerformAction(fresh, kAXPressAction as CFString) == .success {
                        let actual = playlistItem()?.1
                        closePicker()
                        if actual == saved { remember(saved, trackID: trackID); return true }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }
}

class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    @Published private(set) var track: SpotifyTrack? = nil
    @Published private(set) var isLiked: Bool = false
    @Published private(set) var libraryTrackID: String?
    @Published private(set) var likeRequestInFlight = false
    @Published private(set) var likeError: String?
    private var localLibraryIDs: [String: String] = [:]
    private var nextLocalIDLookup = Date.distantPast
    @Published private(set) var progressRatio: Double = 0.0
    @Published private(set) var albumArt: NSImage? = nil

    @Published private(set) var isGem: Bool = false

    private var currentArtworkURL: String?
    private var gemPlaylistId: String?
    private var gemTrackIDs: Set<String> = []
    private var gemOverrides: [String: Bool] = [:]
    private var spotifyUserId: String?

    private var lastProgressMs: Double = 0
    private var lastProgressTimestamp: Date = Date()
    private var durationMs: Double = 1
    private var displayTimer: Timer?
    private var lastPlayingAt: Date?

    private let playbackStopGraceInterval: TimeInterval = 6
    // Retain paused track and artwork until another track replaces them.
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/spotify-player/SavedTracks_cache.json")
    private let tokenURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/spotify-player/user_client_token.json")
    private let configURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/spotify-player/app.toml")

    private var accessToken: String?
    private var tokenExpiresAt: Date?
    private let tokenLock = NSLock()
    private var tokenRefreshBlockedUntil: Date?
    private var tokenRefreshFailureFileDate: Date?
    private let tokenRefreshRetryInterval: TimeInterval = 15 * 60
    private var playbackRateLimitBlockedUntil: Date?
    private var nextPlaybackAPIPoll = Date.distantPast
    private let apiRequestLock = NSLock()
    private var apiBlockedUntil = Date.distantPast

    /// Write to these files from skhd to instantly update the heart.
    /// Like:   spotify_player like && printf '1' > /tmp/.barik-spotify-like
    /// Unlike: spotify_player like --unlike && printf '1' > /tmp/.barik-spotify-unlike
    static let likeSignalPath   = "/tmp/.barik-spotify-like"
    static let unlikeSignalPath = "/tmp/.barik-spotify-unlike"

    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var savedTrackIDs: Set<String> = []
    private var savedStateAPICache: [String: (saved: Bool, checkedAt: Date)] = [:]
    private let savedStateCacheTTL: TimeInterval = 60
    // Local overrides set by the user until the cache confirms the new state
    private var likedOverrides: [String: Bool] = [:]
    private var likeWatcher: DispatchSourceFileSystemObject?
    private var unlikeWatcher: DispatchSourceFileSystemObject?

    private init() {
        loadSavedTrackIDs()
        refresh()
        startTimer()
        startSignalWatcher(path: Self.likeSignalPath, liked: true)
        startSignalWatcher(path: Self.unlikeSignalPath, liked: false)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadGemsPlaylistData()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(onSleep),
            name: NSNotification.Name("com.barik.willSleep"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWake),
            name: NSNotification.Name("com.barik.didWake"), object: nil)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.3
    }

    @objc private func onSleep() {
        timer?.invalidate()
        timer = nil
        stopDisplayTimer()
    }

    @objc private func onWake() {
        refresh()
        startTimer()
    }

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateProgressRatio()
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateProgressRatio() {
        guard durationMs > 0 else { return }
        let elapsed = Date().timeIntervalSince(lastProgressTimestamp) * 1000
        let current = lastProgressMs + elapsed
        progressRatio = min(max(current / durationMs, 0), 1)
    }

    @discardableResult
    private func startSignalWatcher(path: String, liked: Bool) -> DispatchSourceFileSystemObject? {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .attrib],
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.handleLibraryShortcut(liked: liked) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        if liked { likeWatcher = source } else { unlikeWatcher = source }
        return source
    }

    private func loadSavedTrackIDs() {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        savedTrackIDs = Set(json.keys)
    }

    private func refresh() {
        DispatchQueue.main.async { [weak self] in
            self?.beginRefresh()
        }
    }

    private func beginRefresh() {
        guard !refreshInFlight else {
            refreshPending = true
            return
        }

        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let playback = (self.fetchLocalPlayback() ?? self.fetchSpotifyDesktopPlayback()).map { SpotifyPlaybackFetchResult.snapshot($0) }
                ?? self.fetchPlayback()
            switch playback {
            case .snapshot(let snapshot):
                self.applyPlaybackSnapshot(snapshot)
            case .noPlayback:
                self.applyIdleVisibility()
            case .unchanged:
                break
            case .unavailable:
                // A timeout, helper failure, or malformed response says nothing
                // about whether playback stopped. Preserve the last known state
                // so a transient poll cannot make the progress bar flicker.
                if let local = self.fetchLocalPlayback() {
                    self.applyPlaybackSnapshot(local)
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        refreshInFlight = false
        guard refreshPending else { return }
        refreshPending = false
        beginRefresh()
    }

    private func resolvedSavedState(trackId: String) -> Bool {
        let rawId = "spotify:track:\(trackId)"
        if savedTrackIDs.contains(rawId) {
            return true
        }

        if let cached = savedStateAPICache[trackId],
           Date().timeIntervalSince(cached.checkedAt) < savedStateCacheTTL {
            return cached.saved
        }

        let saved = checkTrackSavedViaAPI(trackId: trackId)
        savedStateAPICache[trackId] = (saved, Date())
        return saved
    }

    func nextTrack() {
        if track?.id.hasPrefix("local:") == true {
            performLocalAction("next-track")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.performPlaybackAction(path: "next", method: "POST")
            self.nextPlaybackAPIPoll = .distantPast
            self.refresh()
        }
    }

    func togglePlayPause() {
        if track?.id.hasPrefix("local:") == true {
            performLocalAction("toggle-play-pause")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if case .snapshot(let snapshot) = self.fetchPlayback(force: true) {
                let path = snapshot.isPlaying ? "pause" : "play"
                _ = self.performPlaybackAction(path: path, method: "PUT")
                self.nextPlaybackAPIPoll = .distantPast
            }
            self.refresh()
        }
    }

    private func localMediaCommand(_ arguments: [String], executable: String = "/opt/homebrew/bin/media-control") -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    private func libraryID(for item: SpotifyPlaybackItem) -> String? {
        guard item.id.hasPrefix("local:") else { return item.id }
        if let cached = localLibraryIDs[item.id] { return cached }
        guard Date() >= nextLocalIDLookup else { return nil }
        nextLocalIDLookup = Date().addingTimeInterval(15)
        // Read a real Spotify ID; never infer it from a song title or send a
        // synthetic local ID to the library API. Do not launch a closed app.
        let script = """
        const app = Application('Spotify');
        if (app.running()) {
            const track = app.currentTrack();
            JSON.stringify({id: track.id(), name: track.name(), artist: track.artist()});
        }
        """
        guard let data = localMediaCommand(["-l", "JavaScript", "-e", script], executable: "/usr/bin/osascript"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["name"] as? String == item.name,
              json["artist"] as? String == item.artists.map(\.name).joined(separator: ", "),
              let uri = json["id"] as? String,
              uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        // Only the current local track needs a cache entry.
        localLibraryIDs = [item.id: id]
        return id
    }

    private func fetchLocalPlayback() -> SpotifyPlaybackSnapshot? {
        guard let data = localMediaCommand(["get", "--now"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["bundleIdentifier"] as? String == "com.spotify.client",
              let title = json["title"] as? String,
              let artist = json["artist"] as? String,
              let playing = json["playing"] as? Bool else { return nil }
        if let base64 = json["artworkData"] as? String,
           let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            DispatchQueue.main.async { self.albumArt = image }
        }
        let localIdentity = json["contentItemIdentifier"] as? String ?? "\(artist):\(title)"
        return SpotifyPlaybackSnapshot(
            progressMs: (json["elapsedTimeNow"] as? Double ?? json["elapsedTime"] as? Double ?? 0) * 1000,
            isPlaying: playing,
            item: SpotifyPlaybackItem(id: "local:\(localIdentity)", name: title,
                durationMs: (json["duration"] as? Double ?? 0) * 1000,
                artists: [SpotifyArtist(name: artist)], album: SpotifyAlbum(images: [])))
    }

    /// The system media owner may be a browser even while Spotify has a paused song.
    /// Query Spotify itself without launching it or changing any playback.
    private func fetchSpotifyDesktopPlayback() -> SpotifyPlaybackSnapshot? {
        let script = """
        const app = Application('Spotify');
        if (app.running()) {
            const track = app.currentTrack();
            JSON.stringify({id: track.id(), name: track.name(), artist: track.artist(),
                artwork: track.artworkUrl(), duration: track.duration(),
                position: app.playerPosition(), playing: app.playerState() === 'playing'});
        }
        """
        guard let data = localMediaCommand(["-l", "JavaScript", "-e", script], executable: "/usr/bin/osascript"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uri = json["id"] as? String, uri.hasPrefix("spotify:track:"),
              let name = json["name"] as? String,
              let artist = json["artist"] as? String else { return nil }
        let images = (json["artwork"] as? String).flatMap { $0.isEmpty ? nil : [SpotifyImage(url: $0)] } ?? []
        return SpotifyPlaybackSnapshot(
            progressMs: (json["position"] as? Double ?? 0) * 1000,
            isPlaying: json["playing"] as? Bool ?? false,
            item: SpotifyPlaybackItem(id: String(uri.dropFirst("spotify:track:".count)), name: name,
                durationMs: json["duration"] as? Double ?? 0,
                artists: [SpotifyArtist(name: artist)], album: SpotifyAlbum(images: images)))
    }

    private func performLocalAction(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Never send a generic media command to a different app (such as TV playback).
            guard self.fetchLocalPlayback() != nil else { return }
            _ = self.localMediaCommand([command])
            self.refresh()
        }
    }

    private func fetchPlayback(force: Bool = false) -> SpotifyPlaybackFetchResult {
        if let blockedUntil = playbackRateLimitBlockedUntil, Date() < blockedUntil {
            return .unavailable
        }

        guard force || Date() >= nextPlaybackAPIPoll else {
            return .unchanged
        }
        nextPlaybackAPIPoll = Date().addingTimeInterval(15)
        guard let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/me/player") else {
            return .unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = performRequestWithResponse(request) else {
            return .unavailable
        }

        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 30
            playbackRateLimitBlockedUntil = Date().addingTimeInterval(max(retryAfter, 30))
            return .unavailable
        }
        guard (200..<300).contains(response.statusCode) else { return .unavailable }
        playbackRateLimitBlockedUntil = nil

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return .noPlayback }
        guard output != "null" else { return .noPlayback }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(SpotifyPlaybackSnapshot.self, from: data) else {
            return .unavailable
        }
        return .snapshot(snapshot)
    }

    private func performPlaybackAction(path: String, method: String) -> Bool {
        guard let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/me/player/\(path)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = performRequestWithResponse(request) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    private func applyPlaybackSnapshot(_ snapshot: SpotifyPlaybackSnapshot) {
        guard let item = snapshot.item else {
            applyIdleVisibility()
            return
        }

        let now = Date()
        if snapshot.isPlaying {
            lastPlayingAt = now
        }

        // Spotify can briefly report paused while buffering or moving between
        // tracks/devices. Keep the playing presentation through one poll cycle.
        let shouldDisplayAsPlaying = snapshot.isPlaying
            || now.timeIntervalSince(lastPlayingAt ?? .distantPast) <= playbackStopGraceInterval
        let artworkURL = item.album.images.first?.url
        let artist = item.artists.map(\.name).joined(separator: ", ")
        let newTrack = SpotifyTrack(
            id: item.id,
            name: item.name,
            artist: artist,
            isPlaying: shouldDisplayAsPlaying,
            artworkURL: artworkURL
        )

        if artworkURL != currentArtworkURL {
            currentArtworkURL = artworkURL
            if let artworkURL, let url = URL(string: artworkURL) {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let self, let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self.albumArt = image
                    }
                }.resume()
            }
        }

        loadSavedTrackIDs()
        let resolvedLibraryID = libraryID(for: item)
        let nativeSaved = SpotifyNativeLibrary.button(name: item.name, artist: artist, trackID: resolvedLibraryID)?.1
        let cacheHasTrack = nativeSaved ?? resolvedLibraryID.map { resolvedSavedState(trackId: $0) } ?? false
        let progressMs = snapshot.progressMs ?? 0

        DispatchQueue.main.async {
            if self.track?.id != newTrack.id { self.likeError = nil }
            self.track = newTrack
            defer { self.writeLibraryStatus() }
            self.libraryTrackID = resolvedLibraryID
            let stateID = resolvedLibraryID ?? item.id
            if let override = self.likedOverrides[stateID], override == cacheHasTrack {
                self.likedOverrides.removeValue(forKey: stateID)
            }
            self.isLiked = self.likedOverrides[stateID] ?? cacheHasTrack
            if nativeSaved != nil { self.likeError = nil }

            let isInGems = self.gemTrackIDs.contains(stateID)
            if let override = self.gemOverrides[stateID], override == isInGems {
                self.gemOverrides.removeValue(forKey: stateID)
            }
            self.isGem = self.isLiked && (self.gemOverrides[stateID] ?? isInGems)

            self.lastProgressMs = progressMs
            self.lastProgressTimestamp = now
            self.durationMs = max(item.durationMs, 1)
            self.updateProgressRatio()

            if shouldDisplayAsPlaying {
                self.startDisplayTimer()
            } else {
                self.stopDisplayTimer()
            }
        }
    }

    private func applyIdleVisibility() {
        let now = Date()

        // A single `null` response can occur during a Spotify transition. Let
        // the next poll confirm playback really stopped before hiding the bar.
        if now.timeIntervalSince(lastPlayingAt ?? .distantPast) <= playbackStopGraceInterval {
            return
        }

        DispatchQueue.main.async {
            if let track = self.track {
                self.track = SpotifyTrack(
                    id: track.id,
                    name: track.name,
                    artist: track.artist,
                    isPlaying: false,
                    artworkURL: track.artworkURL
                )
            }
            self.stopDisplayTimer()
        }
    }

    private func clearTrackState() {
        DispatchQueue.main.async {
            self.track = nil
            self.libraryTrackID = nil
            self.likeError = nil
            self.isLiked = false
            self.isGem = false
            self.stopDisplayTimer()
            self.progressRatio = 0
            self.albumArt = nil
            self.currentArtworkURL = nil
        }
    }

    func toggleLike() {
        guard let id = libraryTrackID, !likeRequestInFlight else { return }
        requestSavedState(!isLiked)
    }

    private func handleLibraryShortcut(liked: Bool) {
        // Saving/unsaving a song must use the same confirmed path as a click.
        // Gems retain their separate playlist action.
        guard let id = libraryTrackID, !likeRequestInFlight else { return }
        if liked && isLiked {
            requestGemState(true, trackID: id)
        } else if !liked && isGem {
            requestGemState(false, trackID: id)
        } else {
            requestSavedState(liked)
        }
    }

    private func requestGemState(_ saved: Bool, trackID: String) {
        likeRequestInFlight = true
        likeError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let success = saved ? self.addToGemsPlaylist(trackId: trackID) : self.removeFromGemsPlaylist(trackId: trackID)
            DispatchQueue.main.async {
                self.likeRequestInFlight = false
                defer { self.writeLibraryStatus() }
                guard self.libraryTrackID == trackID else { return }
                if success {
                    self.isGem = saved
                    self.gemOverrides[trackID] = saved
                } else {
                    self.likeError = "Spotify could not update Liked Gems. Try again after its API limit clears."
                }
            }
        }
    }

    private func requestSavedState(_ newLiked: Bool) {
        guard let id = libraryTrackID, let track, !likeRequestInFlight else { return }
        let wasGem = isGem
        likeRequestInFlight = true
        likeError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let nativeResult = SpotifyNativeLibrary.setSaved(newLiked, name: track.name, artist: track.artist, trackID: id)
            let success = nativeResult ?? self.setTrackSaved(trackId: id, saved: newLiked)
            if success && wasGem && !newLiked {
                self.removeFromGemsPlaylist(trackId: id)
            }
            DispatchQueue.main.async {
                self.likeRequestInFlight = false
                defer { self.writeLibraryStatus() }
                guard self.libraryTrackID == id else { return }
                if success {
                    self.isLiked = newLiked
                    self.likedOverrides[id] = newLiked
                    if !newLiked {
                        self.isGem = false
                        self.gemOverrides[id] = false
                    }
                } else {
                    self.likeError = "Spotify could not update your library. Please try again later."
                }
            }
        }
    }

    private func writeLibraryStatus() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/barik")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "track": track?.name ?? "", "trackID": libraryTrackID ?? "",
            "liked": isLiked, "gem": isGem,
            "accessibility": AXIsProcessTrusted(), "pending": likeRequestInFlight,
            "error": likeError ?? "", "updated": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("spotify-status.json"), options: .atomic)
        }
    }

    // MARK: - Spotify Web API

    private func performRequest(
        _ request: URLRequest,
        timeout: TimeInterval = 8
    ) -> Data? {
        performRequestWithResponse(request, timeout: timeout)?.data
    }

    private func performRequestWithResponse(
        _ request: URLRequest,
        timeout: TimeInterval = 8
    ) -> (data: Data, response: HTTPURLResponse)? {
        let isSpotifyAPI = request.url?.host == "api.spotify.com"
        if isSpotifyAPI { apiRequestLock.lock() }
        defer { if isSpotifyAPI { apiRequestLock.unlock() } }
        if isSpotifyAPI && Date() < apiBlockedUntil { return nil }
        var request = request
        request.timeoutInterval = timeout

        let completion = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if error == nil, let response = response as? HTTPURLResponse {
                responseData = data ?? Data()
                httpResponse = response
            }
            completion.signal()
        }
        task.resume()

        guard completion.wait(timeout: .now() + timeout + 0.5) == .success else {
            task.cancel()
            return nil
        }
        guard let responseData, let httpResponse else { return nil }
        if isSpotifyAPI && httpResponse.statusCode == 429 {
            let delay = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 30
            apiBlockedUntil = Date().addingTimeInterval(max(delay, 30))
        }
        return (responseData, httpResponse)
    }

    private func readClientId() -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("client_id") {
                let parts = trimmed.components(separatedBy: "=")
                guard parts.count >= 2 else { continue }
                return parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }

    private func readTokenFile() -> (accessToken: String, refreshToken: String, expiresAt: Date)? {
        guard let data = try? Data(contentsOf: tokenURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresStr = json["expires_at"] as? String,
              !token.isEmpty,
              !refresh.isEmpty
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = formatter.date(from: expiresStr) ?? .distantPast
        return (token, refresh, expires)
    }

    private func writeTokenFile(accessToken: String, refreshToken: String, expiresIn: Int, scope: String) {
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dict: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_in": expiresIn,
            "expires_at": formatter.string(from: expiresAt),
            "scope": scope,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: tokenURL, options: .atomic)
        }
    }

    private func getValidToken() -> String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }

        if let token = accessToken, let expires = tokenExpiresAt, Date() < expires {
            return token
        }
        guard let tokenInfo = readTokenFile() else { return nil }
        if Date() < tokenInfo.expiresAt {
            accessToken = tokenInfo.accessToken
            tokenExpiresAt = tokenInfo.expiresAt
            tokenRefreshBlockedUntil = nil
            tokenRefreshFailureFileDate = nil
            return tokenInfo.accessToken
        }

        let fileDate = try? FileManager.default.attributesOfItem(atPath: tokenURL.path)[.modificationDate] as? Date
        if let blockedUntil = tokenRefreshBlockedUntil,
           Date() < blockedUntil,
           fileDate == tokenRefreshFailureFileDate {
            return nil
        }

        // Token expired — refresh it
        guard let clientId = readClientId() else { return nil }
        let refreshToken = tokenInfo.refreshToken
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientId)"
        request.httpBody = body.data(using: .utf8)

        guard let data = performRequest(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            // Avoid hammering Spotify every three seconds when a refresh token
            // has expired or been revoked. A successful manual authentication
            // changes the token file mtime and immediately clears this guard.
            tokenRefreshFailureFileDate = fileDate
            tokenRefreshBlockedUntil = Date().addingTimeInterval(tokenRefreshRetryInterval)
            return nil
        }

        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let scope = json["scope"] as? String ?? ""
        writeTokenFile(accessToken: token, refreshToken: newRefresh, expiresIn: expiresIn, scope: scope)
        accessToken = token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        tokenRefreshBlockedUntil = nil
        tokenRefreshFailureFileDate = nil
        return token
    }

    private func checkTrackSavedViaAPI(trackId: String) -> Bool {
        guard let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackId)") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = performRequest(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Bool],
              let first = json.first else { return false }
        return first
    }

    @discardableResult
    private func setTrackSaved(trackId: String, saved: Bool) -> Bool {
        guard let token = getValidToken() else { return false }
        guard let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackId)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = saved ? "PUT" : "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = performRequestWithResponse(request) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    // MARK: - Liked Gems Playlist

    private func getSpotifyUserId(token: String) -> String? {
        if let id = spotifyUserId { return id }
        guard let url = URL(string: "https://api.spotify.com/v1/me") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = performRequest(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["id"] as? String else { return nil }
        spotifyUserId = userId
        return userId
    }

    private func findGemsPlaylist() -> String? {
        if let id = gemPlaylistId { return id }
        guard let token = getValidToken() else { return nil }
        var offset = 0
        while true {
            guard let url = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50&offset=\(offset)") else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let data = performRequest(request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return nil }
            let foundId = items.first { $0["name"] as? String == "liked gems" }?["id"] as? String
            if let id = foundId {
                gemPlaylistId = id
                return id
            }
            if items.count < 50 { break }
            offset += 50
        }
        return nil
    }

    private func findOrCreateGemsPlaylist() -> String? {
        if let id = findGemsPlaylist() { return id }
        guard let token = getValidToken(),
              let userId = getSpotifyUserId(token: token),
              let url = URL(string: "https://api.spotify.com/v1/users/\(userId)/playlists") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": "liked gems", "public": false]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let data = performRequest(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let createdId = json["id"] as? String else { return nil }
        gemPlaylistId = createdId
        return createdId
    }

    private func loadGemsPlaylistData() {
        guard let playlistId = findGemsPlaylist(),
              let token = getValidToken() else { return }
        var allIds = Set<String>()
        var offset = 0
        while true {
            guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks?limit=100&offset=\(offset)&fields=items(track(id)),total") else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let data = performRequest(request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { break }
            let batchIds = items.compactMap { item -> String? in
                (item["track"] as? [String: Any])?["id"] as? String
            }
            allIds.formUnion(batchIds)
            if items.count < 100 { break }
            offset += 100
        }
        gemTrackIDs = allIds
    }

    @discardableResult
    private func addToGemsPlaylist(trackId: String) -> Bool {
        guard let playlistId = findOrCreateGemsPlaylist(),
              let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uris": ["spotify:track:\(trackId)"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = performRequestWithResponse(request), (200..<300).contains(response.statusCode) else { return false }
        gemTrackIDs.insert(trackId)
        return true
    }

    @discardableResult
    private func removeFromGemsPlaylist(trackId: String) -> Bool {
        guard let playlistId = findOrCreateGemsPlaylist(),
              let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["tracks": [["uri": "spotify:track:\(trackId)"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = performRequestWithResponse(request), (200..<300).contains(response.statusCode) else { return false }
        gemTrackIDs.remove(trackId)
        return true
    }
}
