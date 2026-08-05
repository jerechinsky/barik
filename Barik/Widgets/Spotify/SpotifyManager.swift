import Foundation
import Combine
import AppKit
import Darwin

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
}

class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    @Published private(set) var track: SpotifyTrack? = nil
    @Published private(set) var isLiked: Bool = false
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

    private let executablePath = "/opt/homebrew/bin/spotify_player"
    private let playbackStopGraceInterval: TimeInterval = 6
    private let idleHideInterval: TimeInterval = 20 * 60
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/spotify-player/SavedTracks_cache.json")
    private let tokenURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cache/spotify-player/user_client_token.json")
    private let configURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/spotify-player/app.toml")

    private var accessToken: String?
    private var tokenExpiresAt: Date?

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
            guard let self else { return }
            guard let id = self.track?.id else { return }

            var currentlyLiked = false
            var currentlyGem = false
            DispatchQueue.main.sync {
                currentlyLiked = self.isLiked
                currentlyGem = self.isGem
            }

            if liked {
                if currentlyLiked {
                    // Already liked → add to gems
                    DispatchQueue.main.async {
                        self.isGem = true
                        self.gemOverrides[id] = true
                    }
                    self.addToGemsPlaylist(trackId: id)
                } else {
                    // Not liked → like
                    DispatchQueue.main.async {
                        self.isLiked = true
                        self.likedOverrides[id] = true
                    }
                    self.setTrackSaved(trackId: id, saved: true)
                }
            } else {
                if currentlyGem {
                    // Gem → remove gem, stay liked
                    DispatchQueue.main.async {
                        self.isGem = false
                        self.gemOverrides[id] = false
                    }
                    self.removeFromGemsPlaylist(trackId: id)
                } else if currentlyLiked {
                    // Liked → unlike
                    DispatchQueue.main.async {
                        self.isLiked = false
                        self.likedOverrides[id] = false
                    }
                    self.setTrackSaved(trackId: id, saved: false)
                }
            }
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

            switch self.fetchPlayback() {
            case .snapshot(let snapshot):
                self.applyPlaybackSnapshot(snapshot)
            case .noPlayback:
                self.applyIdleVisibility()
            case .unavailable:
                // A timeout, helper failure, or malformed response says nothing
                // about whether playback stopped. Preserve the last known state
                // so a transient poll cannot make the progress bar flicker.
                break
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
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runSpotifyPlayer(args: ["playback", "next"])
            self.refresh()
        }
    }

    func togglePlayPause() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runSpotifyPlayer(args: ["playback", "play-pause"])
            self.refresh()
        }
    }

    private func fetchPlayback() -> SpotifyPlaybackFetchResult {
        guard let data = runSpotifyPlayer(args: ["get", "key", "playback"]) else {
            return .unavailable
        }

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return .unavailable }
        guard output != "null" else { return .noPlayback }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(SpotifyPlaybackSnapshot.self, from: data) else {
            return .unavailable
        }
        return .snapshot(snapshot)
    }

    private func runSpotifyPlayer(args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let completion = DispatchSemaphore(value: 0)
        let dataLock = NSLock()
        var output = Data()
        let readHandle = stdout.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            dataLock.lock()
            output.append(chunk)
            dataLock.unlock()
        }
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return nil
        }

        var finished = completion.wait(timeout: .now() + 2) == .success
        if !finished {
            process.terminate()
            finished = completion.wait(timeout: .now() + 0.25) == .success
        }
        if !finished, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            finished = completion.wait(timeout: .now() + 0.25) == .success
        }

        guard finished else {
            readHandle.readabilityHandler = nil
            return nil
        }

        readHandle.readabilityHandler = nil
        let tail = readHandle.readDataToEndOfFile()
        dataLock.lock()
        output.append(tail)
        dataLock.unlock()

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output
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
        let shouldShowPausedTrack = now.timeIntervalSince(lastPlayingAt ?? now) <= idleHideInterval
        guard shouldDisplayAsPlaying || shouldShowPausedTrack else {
            clearTrackState()
            return
        }

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
            } else {
                DispatchQueue.main.async {
                    self.albumArt = nil
                }
            }
        }

        loadSavedTrackIDs()
        let cacheHasTrack = resolvedSavedState(trackId: item.id)
        let progressMs = snapshot.progressMs ?? 0

        DispatchQueue.main.async {
            self.track = newTrack
            if let override = self.likedOverrides[item.id], override == cacheHasTrack {
                self.likedOverrides.removeValue(forKey: item.id)
            }
            self.isLiked = self.likedOverrides[item.id] ?? cacheHasTrack

            let isInGems = self.gemTrackIDs.contains(item.id)
            if let override = self.gemOverrides[item.id], override == isInGems {
                self.gemOverrides.removeValue(forKey: item.id)
            }
            self.isGem = self.isLiked && (self.gemOverrides[item.id] ?? isInGems)

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

        let shouldKeepTrackVisible = now.timeIntervalSince(lastPlayingAt ?? now) <= idleHideInterval

        guard shouldKeepTrackVisible else {
            clearTrackState()
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
            self.isLiked = false
            self.isGem = false
            self.stopDisplayTimer()
            self.progressRatio = 0
            self.albumArt = nil
            self.currentArtworkURL = nil
        }
    }

    func toggleLike() {
        guard let track else { return }
        let wasGem = isGem
        let newLiked = !isLiked
        isLiked = newLiked
        likedOverrides[track.id] = newLiked
        if !newLiked && isGem {
            isGem = false
            gemOverrides[track.id] = false
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.setTrackSaved(trackId: track.id, saved: newLiked)
            if wasGem && !newLiked {
                self.removeFromGemsPlaylist(trackId: track.id)
            }
        }
    }

    // MARK: - Spotify Web API

    private func performRequest(
        _ request: URLRequest,
        timeout: TimeInterval = 8
    ) -> Data? {
        var request = request
        request.timeoutInterval = timeout

        let completion = DispatchSemaphore(value: 0)
        var responseData: Data?
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if error == nil {
                responseData = data ?? Data()
            }
            completion.signal()
        }
        task.resume()

        guard completion.wait(timeout: .now() + timeout + 0.5) == .success else {
            task.cancel()
            return nil
        }
        return responseData
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
              let expiresStr = json["expires_at"] as? String
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
        if let token = accessToken, let expires = tokenExpiresAt, Date() < expires {
            return token
        }
        guard let tokenInfo = readTokenFile() else { return nil }
        if Date() < tokenInfo.expiresAt {
            accessToken = tokenInfo.accessToken
            tokenExpiresAt = tokenInfo.expiresAt
            return tokenInfo.accessToken
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
              let expiresIn = json["expires_in"] as? Int else { return nil }

        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let scope = json["scope"] as? String ?? ""
        writeTokenFile(accessToken: token, refreshToken: newRefresh, expiresIn: expiresIn, scope: scope)
        accessToken = token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
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

    private func setTrackSaved(trackId: String, saved: Bool) {
        guard let token = getValidToken() else { return }
        guard let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = saved ? "PUT" : "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = performRequest(request)
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

    private func addToGemsPlaylist(trackId: String) {
        guard let playlistId = findOrCreateGemsPlaylist(),
              let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uris": ["spotify:track:\(trackId)"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if performRequest(request) != nil {
            gemTrackIDs.insert(trackId)
        }
    }

    private func removeFromGemsPlaylist(trackId: String) {
        guard let playlistId = findOrCreateGemsPlaylist(),
              let token = getValidToken(),
              let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["tracks": [["uri": "spotify:track:\(trackId)"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if performRequest(request) != nil {
            gemTrackIDs.remove(trackId)
        }
    }
}
