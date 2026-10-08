import Foundation
import AVFoundation

extension Notification.Name {
    /// Posted on the main queue whenever offline playback starts, stops or finishes.
    static let offlinePlaybackDidChange = Notification.Name("com.eevee.offline.playbackChanged")
}

/// Plays downloaded files with `AVAudioPlayer`, independent of Spotify's own player.
///
/// Main-thread only. Spotify's player is not paused or controlled, so both can play at once.
final class OfflinePlaybackManager: NSObject, AVAudioPlayerDelegate {

    static let shared = OfflinePlaybackManager(database: .shared)

    private let database: OfflineTrackDatabase
    private var player: AVAudioPlayer?

    /// Track currently playing through this manager, if any.
    private(set) var playingTrackId: String?

    init(database: OfflineTrackDatabase) {
        self.database = database
        super.init()
    }

    // MARK: - Playback

    enum PlaybackError: Error {
        case notOffline
        case fileMissing
        case decodeFailed(Error)
    }

    /// Starts playing a downloaded track, replacing anything this manager was already playing.
    @discardableResult
    func play(trackId: String) -> Result<Void, PlaybackError> {
        guard let track = database.offlineTrack(forTrackId: trackId) else { return .failure(.notOffline) }
        guard let path = track.resolvedFilePath else {
            database.pruneMissing()
            return .failure(.fileMissing)
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            newPlayer.delegate = self
            configureAudioSession()
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                return .failure(.decodeFailed(NSError(domain: "OfflinePlayback", code: -1)))
            }
            player?.stop()
            player = newPlayer
            playingTrackId = trackId
            database.recordPlayback(trackId: trackId)
            postChange()
            writeDebugLog("[OfflinePlayback] Playing \(track.trackName)")
            return .success(())
        } catch {
            writeDebugLog("[OfflinePlayback] Cannot play \(track.trackName): \(error.localizedDescription)")
            return .failure(.decodeFailed(error))
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        playingTrackId = nil
        postChange()
    }

    /// Stops if this track is playing, otherwise starts it.
    @discardableResult
    func toggle(trackId: String) -> Result<Void, PlaybackError> {
        if playingTrackId == trackId {
            stop()
            return .success(())
        }
        return play(trackId: trackId)
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        guard finished === player else { return }
        player = nil
        playingTrackId = nil
        postChange()
    }

    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        guard failed === player else { return }
        writeDebugLog("[OfflinePlayback] Decode error: \(error?.localizedDescription ?? "unknown")")
        stop()
    }

    // MARK: - Registration

    /// Adds a finished download to the offline index.
    func register(
        trackId: String,
        filePath: String,
        trackName: String,
        artistName: String,
        albumName: String,
        durationMs: Int,
        artworkURL: String?,
        downloadedAt: Date = Date()
    ) {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            writeDebugLog("[OfflinePlayback] Not registering missing file \(filePath)")
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        var duration = durationMs
        if duration <= 0, let probe = try? AVAudioPlayer(contentsOf: url) {
            duration = Int(probe.duration * 1000)
        }

        database.register(OfflineTrack(
            trackId: trackId,
            filePath: filePath,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            fileSize: size,
            duration: duration,
            fileExtension: url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased(),
            artworkURL: artworkURL,
            downloadedAt: downloadedAt
        ))
    }

    /// Registers finished downloads from before the offline index existed. Returns how many were added.
    @discardableResult
    func backfill(from history: [DownloadHistoryEntry]) -> Int {
        var added = 0
        for entry in history where database.offlineTrack(forTrackId: entry.trackId) == nil {
            guard FileManager.default.fileExists(atPath: entry.filePath) else { continue }
            register(
                trackId: entry.trackId,
                filePath: entry.filePath,
                trackName: entry.trackName,
                artistName: entry.artistName,
                albumName: entry.albumName,
                durationMs: 0,
                artworkURL: nil,
                downloadedAt: entry.completedAt
            )
            added += 1
        }
        return added
    }

    // MARK: - Helpers

    private func postChange() {
        NotificationCenter.default.post(name: .offlinePlaybackDidChange, object: self)
    }

    private func configureAudioSession() {
        #if os(iOS)
        // Spotify already runs a .playback session; only make sure it is active. Options are left alone.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default)
        }
        try? session.setActive(true)
        #endif
    }
}
