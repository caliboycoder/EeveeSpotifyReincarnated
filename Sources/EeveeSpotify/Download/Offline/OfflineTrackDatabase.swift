import Foundation

// MARK: - Offline Track Model

/// A locally downloaded audio file and its metadata.
struct OfflineTrack: Codable {
    let trackId: String
    /// Absolute path at download time. Use `resolvedFilePath`; the app container path can change.
    let filePath: String
    let trackName: String
    let artistName: String
    let albumName: String
    let fileSize: Int64
    /// Milliseconds, 0 when unknown.
    let duration: Int
    let fileExtension: String
    let artworkURL: String?
    let downloadedAt: Date
    var lastPlayedAt: Date?
    var playCount: Int

    init(
        trackId: String,
        filePath: String,
        trackName: String,
        artistName: String,
        albumName: String,
        fileSize: Int64,
        duration: Int,
        fileExtension: String,
        artworkURL: String? = nil,
        downloadedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        playCount: Int = 0
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
        self.downloadedAt = downloadedAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount
    }

    /// The stored path if the file is there, otherwise the same `Documents/...` location under the
    /// current container (iOS can change the container UUID when an app is reinstalled or updated).
    var resolvedFilePath: String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: filePath) { return filePath }

        let marker = "/Documents/"
        guard let range = filePath.range(of: marker, options: .backwards),
              let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let relative = String(filePath[range.upperBound...])
        let candidate = documents.appendingPathComponent(relative).path
        return fm.fileExists(atPath: candidate) ? candidate : nil
    }
}

// MARK: - Database

/// Persistent index of downloaded tracks. Thread-safe.
final class OfflineTrackDatabase {

    static let shared = OfflineTrackDatabase()

    private let fileManager = FileManager.default
    private let indexFile: URL
    private let lock = NSLock()
    private var index: [String: OfflineTrack] = [:]

    private let ioQueue = DispatchQueue(label: "com.eevee.offline.db", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private let writeDelay: TimeInterval

    /// - Parameter directory: where `index.json` lives. Defaults to Application Support.
    init(directory: URL? = nil, writeDelay: TimeInterval = 1.0) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotify/Offline", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.indexFile = dir.appendingPathComponent("index.json")
        self.writeDelay = writeDelay
        load()
    }

    // MARK: Query

    func offlineTrack(forTrackId trackId: String) -> OfflineTrack? {
        lock.lock(); defer { lock.unlock() }
        return index[trackId]
    }

    /// True when the track is indexed and its file can be found.
    func isOffline(trackId: String) -> Bool {
        return offlineTrack(forTrackId: trackId)?.resolvedFilePath != nil
    }

    /// Newest first. Entries whose file is gone are skipped (not deleted).
    func allOfflineTracks() -> [OfflineTrack] {
        lock.lock()
        let tracks = Array(index.values)
        lock.unlock()
        return tracks
            .filter { $0.resolvedFilePath != nil }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    func search(query: String) -> [OfflineTrack] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allOfflineTracks() }
        return allOfflineTracks().filter {
            $0.trackName.lowercased().contains(needle)
                || $0.artistName.lowercased().contains(needle)
                || $0.albumName.lowercased().contains(needle)
        }
    }

    func totalStorageUsed() -> Int64 {
        return allOfflineTracks().reduce(0) { $0 + $1.fileSize }
    }

    // MARK: Mutation

    func register(_ track: OfflineTrack) {
        lock.lock()
        // Keep play stats if the same track is downloaded again.
        var stored = track
        if let existing = index[track.trackId] {
            stored.lastPlayedAt = existing.lastPlayedAt
            stored.playCount = existing.playCount
        }
        index[track.trackId] = stored
        lock.unlock()
        schedulePersistence()
    }

    func recordPlayback(trackId: String) {
        lock.lock()
        guard var track = index[trackId] else { lock.unlock(); return }
        track.lastPlayedAt = Date()
        track.playCount += 1
        index[trackId] = track
        lock.unlock()
        schedulePersistence()
    }

    func remove(trackId: String, deleteFile: Bool) {
        lock.lock()
        let removed = index.removeValue(forKey: trackId)
        lock.unlock()
        guard let track = removed else { return }

        if deleteFile, let path = track.resolvedFilePath {
            try? fileManager.removeItem(atPath: path)
        }
        schedulePersistence()
    }

    /// Drops index entries whose file no longer exists. Returns how many were removed.
    @discardableResult
    func pruneMissing() -> Int {
        lock.lock()
        let before = index.count
        index = index.filter { $0.value.resolvedFilePath != nil }
        let removed = before - index.count
        lock.unlock()
        if removed > 0 { schedulePersistence() }
        return removed
    }

    // MARK: Persistence

    /// Writes the index now, on the calling thread.
    func flush() {
        ioQueue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeIndex()
        }
    }

    private func schedulePersistence() {
        ioQueue.async {
            self.pendingWrite?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writeIndex() }
            self.pendingWrite = work
            self.ioQueue.asyncAfter(deadline: .now() + self.writeDelay, execute: work)
        }
    }

    private func writeIndex() {
        lock.lock()
        let snapshot = index
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(snapshot).write(to: indexFile, options: .atomic)
        } catch {
            writeDebugLog("[OfflineDB] Failed to write index: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([String: OfflineTrack].self, from: data)
            lock.lock(); index = decoded; lock.unlock()
        } catch {
            writeDebugLog("[OfflineDB] Failed to read index: \(error.localizedDescription)")
        }
    }
}
