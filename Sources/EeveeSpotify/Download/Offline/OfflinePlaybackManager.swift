import Foundation
import AVFoundation

// MARK: - Offline Playback Manager

/// Bridges between downloaded tracks and Spotify's player.
/// Redirects playback to local files when available.
final class OfflinePlaybackManager: NSObject {
    static let shared = OfflinePlaybackManager()
    
    private let offlineDB = OfflineTrackDatabase.shared
    private let lock = NSLock()
    
    // Track currently playing via offline system
    private var currentOfflineTrackId: String?
    private var currentPlayer: AVAudioPlayer?
    
    // Observer for playback events
    private var playbackObservers: NSHashTable<AnyObject> = .weakObjects()
    
    override private init() {
        super.init()
        setupAudioSession()
    }
    
    // MARK: - Query
    
    /// Check if a track has a local download available for playback
    func hasOfflineVersion(trackId: String) -> Bool {
        return offlineDB.isOffline(trackId: trackId)
    }
    
    /// Get the offline track if available
    func offlineTrack(for trackId: String) -> OfflineTrack? {
        return offlineDB.offlineTrack(forTrackId: trackId)
    }
    
    /// Get all offline tracks for playlist/library view
    func allOfflineTracks() -> [OfflineTrack] {
        return offlineDB.allOfflineTracks()
    }
    
    /// Search offline tracks
    func searchOfflineTracks(query: String) -> [OfflineTrack] {
        return offlineDB.search(query: query)
    }
    
    /// Storage info
    func storageUsedByOfflineTracks() -> Int64 {
        return offlineDB.totalStorageUsed()
    }
    
    // MARK: - Playback
    
    /// Attempt to play a track from offline storage
    /// Returns true if offline playback was initiated, false if file not available
    @discardableResult
    func playOffline(trackId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        
        guard let offlineTrack = offlineDB.offlineTrack(forTrackId: trackId) else {
            return false
        }
        
        guard FileManager.default.fileExists(atPath: offlineTrack.filePath) else {
            offlineDB.removeOfflineTrack(trackId: trackId, deleteFile: false)
            return false
        }
        
        do {
            let url = URL(fileURLWithPath: offlineTrack.filePath)
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            
            currentOfflineTrackId = trackId
            currentPlayer = player
            
            // Record playback
            offlineDB.recordPlayback(trackId: trackId)
            notifyPlaybackStarted(trackId: trackId, offlineTrack: offlineTrack)
            
            writeDebugLog("[OfflinePlayback] Playing offline: \(offlineTrack.trackName)")
            return true
        } catch {
            writeDebugLog("[OfflinePlayback] Failed to play: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Stop offline playback
    func stopOfflinePlayback() {
        lock.lock(); defer { lock.unlock() }
        
        currentPlayer?.stop()
        currentPlayer = nil
        currentOfflineTrackId = nil
    }
    
    /// Check if currently playing offline
    func isPlayingOffline() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentOfflineTrackId != nil && currentPlayer?.isPlaying ?? false
    }
    
    // MARK: - Observer API
    
    protocol OfflinePlaybackObserver: AnyObject {
        func offlinePlaybackManager(_ manager: OfflinePlaybackManager, didStartPlayback trackId: String, track: OfflineTrack)
        func offlinePlaybackManager(_ manager: OfflinePlaybackManager, didStopPlayback trackId: String)
    }
    
    func addObserver(_ observer: OfflinePlaybackObserver) {
        lock.lock(); defer { lock.unlock() }
        playbackObservers.add(observer as AnyObject)
    }
    
    func removeObserver(_ observer: OfflinePlaybackObserver) {
        lock.lock(); defer { lock.unlock() }
        playbackObservers.remove(observer as AnyObject)
    }
    
    private func notifyPlaybackStarted(trackId: String, offlineTrack: OfflineTrack) {
        lock.lock()
        let observers = playbackObservers.allObjects.compactMap { $0 as? OfflinePlaybackObserver }
        lock.unlock()
        
        DispatchQueue.main.async {
            observers.forEach { $0.offlinePlaybackManager(self, didStartPlayback: trackId, track: offlineTrack) }
        }
    }
    
    // MARK: - Download Integration
    
    /// Called by DownloadManager when a download completes
    func registerDownloadedTrack(
        trackId: String,
        filePath: String,
        trackName: String,
        artistName: String,
        albumName: String,
        duration: Int,
        artworkURL: String?
    ) {
        guard FileManager.default.fileExists(atPath: filePath) else {
            writeDebugLog("[OfflinePlayback] File not found: \(filePath)")
            return
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
        let ext = URL(fileURLWithPath: filePath).pathExtension.isEmpty ? "mp3" : URL(fileURLWithPath: filePath).pathExtension
        
        let offlineTrack = OfflineTrack(
            trackId: trackId,
            filePath: filePath,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            fileSize: fileSize,
            duration: duration,
            fileExtension: ext,
            artworkURL: artworkURL
        )
        
        offlineDB.registerOfflineTrack(offlineTrack)
        writeDebugLog("[OfflinePlayback] Registered for offline: \(trackName)")
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            writeDebugLog("[OfflinePlayback] Audio session setup failed: \(error.localizedDescription)")
        }
    }
}
