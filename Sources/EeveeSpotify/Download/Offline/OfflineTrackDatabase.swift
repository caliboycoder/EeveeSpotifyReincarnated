import Foundation

// MARK: - Offline Track Models

/// Metadata for a locally-downloaded track
struct OfflineTrack: Codable {
    /// Unique ID: matches DownloadItem.track.id for correlation
    let trackId: String
    
    /// Local file path (full path to saved audio file)
    let filePath: String
    
    /// Track metadata for display/search
    let trackName: String
    let artistName: String
    let albumName: String
    
    /// Audio file details
    let fileSize: Int64
    let duration: Int         // milliseconds
    let fileExtension: String // "mp3", "m4a", "ogg", etc.
    
    /// Artwork URL or embedded data
    let artworkURL: String?
    
    /// When the track was downloaded
    let downloadedAt: Date
    
    /// Last time it was played (for sort/filter)
    var lastPlayedAt: Date?
    
    /// Play count for this local track
    var playCount: Int = 0
    
    /// Track status
    var isAvailable: Bool = true  // File still exists
    
    /// MARK: - Codable keys (exclude lastPlayedAt/playCount during init)
    enum CodingKeys: String, CodingKey {
        case trackId, filePath, trackName, artistName, albumName
        case fileSize, duration, fileExtension, artworkURL, downloadedAt
    }
    
    init(
        trackId: String,
        filePath: String,
        trackName: String,
        artistName: String,
        albumName: String,
        fileSize: Int64,
        duration: Int,
        fileExtension: String,
        artworkURL: String? = nil
    ) {
        self.trackId = trackId
        self.filePath = filePath
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.fileSize = fileSize
        self.duration = duration
        self.fileExtension = fileExtension
        self.artworkURL = artworkURL
        self.downloadedAt = Date()
    }
    
    /// Check if file still exists on disk
    mutating func validateAvailability() {
        isAvailable = FileManager.default.fileExists(atPath: filePath)
    }
}

// MARK: - Database

/// Local database of downloaded/available offline tracks.
final class OfflineTrackDatabase {
    static let shared = OfflineTrackDatabase()
    
    private let fileManager = FileManager.default
    private let databasePath: URL
    private let indexLock = NSLock()
    
    /// In-memory index: trackId → OfflineTrack
    private var index: [String: OfflineTrack] = [:]
    
    /// Reverse index: filePath → trackId (for deduplication)
    private var pathIndex: [String: String] = [:]
    
    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        databasePath = appSupport.appendingPathComponent("EeveeSpotify/OfflineTracksDB", isDirectory: true)
        
        try? fileManager.createDirectory(at: databasePath, withIntermediateDirectories: true)
        loadIndex()
    }
    
    // MARK: - Query
    
    /// Get offline track by Spotify track ID
    func offlineTrack(forTrackId trackId: String) -> OfflineTrack? {
        indexLock.lock(); defer { indexLock.unlock() }
        return index[trackId]
    }
    
    /// Check if a track is available offline
    func isOffline(trackId: String) -> Bool {
        indexLock.lock(); defer { indexLock.unlock() }
        guard let track = index[trackId] else { return false }
        return track.isAvailable && fileManager.fileExists(atPath: track.filePath)
    }
    
    /// Get all offline tracks
    func allOfflineTracks() -> [OfflineTrack] {
        indexLock.lock(); defer { indexLock.unlock() }
        return index.values.filter { $0.isAvailable }.sorted { $0.downloadedAt > $1.downloadedAt }
    }
    
    /// Search offline tracks by name
    func search(query: String) -> [OfflineTrack] {
        let lower = query.lowercased()
        indexLock.lock(); defer { indexLock.unlock() }
        return index.values.filter { track in
            track.isAvailable && (
                track.trackName.lowercased().contains(lower) ||
                track.artistName.lowercased().contains(lower) ||
                track.albumName.lowercased().contains(lower)
            )
        }.sorted { $0.downloadedAt > $1.downloadedAt }
    }
    
    /// Get total offline storage used
    func totalStorageUsed() -> Int64 {
        indexLock.lock(); defer { indexLock.unlock() }
        return index.values.filter { $0.isAvailable }.reduce(0) { $0 + $1.fileSize }
    }
    
    /// Get offline tracks by artist
    func offlineTracks(byArtist artist: String) -> [OfflineTrack] {
        indexLock.lock(); defer { indexLock.unlock() }
        return index.values.filter { $0.isAvailable && $0.artistName == artist }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }
    
    // MARK: - Mutation
    
    /// Register a newly downloaded track
    func registerOfflineTrack(_ track: OfflineTrack) {
        indexLock.lock(); defer { indexLock.unlock() }
        
        index[track.trackId] = track
        pathIndex[track.filePath] = track.trackId
        schedulePersistence()
        
        writeDebugLog("[OfflineDB] Registered: \(track.trackName) → \(track.filePath)")
    }
    
    /// Update play metadata
    func recordPlayback(trackId: String) {
        indexLock.lock()
        guard var track = index[trackId] else { indexLock.unlock(); return }
        track.lastPlayedAt = Date()
        track.playCount += 1
        index[trackId] = track
        indexLock.unlock()
        
        schedulePersistence()
    }
    
    /// Remove offline track (delete metadata, optionally delete file)
    func removeOfflineTrack(trackId: String, deleteFile: Bool = false) {
        indexLock.lock()
        guard let track = index.removeValue(forKey: trackId) else { indexLock.unlock(); return }
        pathIndex.removeValue(forKey: track.filePath)
        indexLock.unlock()
        
        if deleteFile {
            try? fileManager.removeItem(atPath: track.filePath)
        }
        
        schedulePersistence()
        writeDebugLog("[OfflineDB] Removed: \(track.trackName)")
    }
    
    /// Validate all offline tracks (remove stale entries)
    func validateAllTracks() {
        indexLock.lock()
        let before = index.count
        index = index.filter { _, track in
            fileManager.fileExists(atPath: track.filePath)
        }
        let after = index.count
        indexLock.unlock()
        
        if before != after {
            schedulePersistence()
            writeDebugLog("[OfflineDB] Validation: removed \(before - after) stale entries")
        }
    }
    
    // MARK: - Persistence
    
    private var persistTimer: DispatchSourceTimer?
    private static let persistDelay = 2.0
    
    private func schedulePersistence() {
        persistTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.persistDelay)
        timer.setEventHandler { [weak self] in self?.persist() }
        timer.resume()
        persistTimer = timer
    }
    
    private func persist() {
        indexLock.lock()
        let indexCopy = index
        indexLock.unlock()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(indexCopy) else {
            writeDebugLog("[OfflineDB] Failed to encode index")
            return
        }
        
        let indexFile = databasePath.appendingPathComponent("index.json")
        try? data.write(to: indexFile, options: .atomic)
    }
    
    private func loadIndex() {
        let indexFile = databasePath.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexFile) else {
            writeDebugLog("[OfflineDB] No persisted index found")
            return
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let decoded = try? decoder.decode([String: OfflineTrack].self, from: data) {
            indexLock.lock()
            index = decoded
            pathIndex = decoded.reduce(into: [:]) { $0[$1.value.filePath] = $1.key }
            indexLock.unlock()
            
            // Lazy validate: run in background on first load
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.validateAllTracks()
            }
            
            writeDebugLog("[OfflineDB] Loaded \(index.count) offline tracks")
        }
    }
}
