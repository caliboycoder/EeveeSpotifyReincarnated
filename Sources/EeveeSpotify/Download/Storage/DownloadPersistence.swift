import Foundation

/// Handles persistence of download queue and history to JSON files
class DownloadPersistence {
    
    // MARK: - Directory Structure
    
    private static let downloadsDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotify/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private let queueFile: URL
    private let historyFile: URL
    
    // MARK: - Initialization
    
    init() {
        self.queueFile = Self.downloadsDirectory.appendingPathComponent("queue.json")
        self.historyFile = Self.downloadsDirectory.appendingPathComponent("history.json")
        
        writeDebugLog("[DownloadPersistence] Initialized at \(Self.downloadsDirectory.path)")
    }
    
    // MARK: - Queue Persistence
    
    func saveQueue(items: [DownloadItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            
            let data = try encoder.encode(items)
            try data.write(to: queueFile, options: .atomic)
            
            writeDebugLog("[DownloadPersistence] Saved \(items.count) items to queue")
        } catch {
            writeDebugLog("[DownloadPersistence] Failed to save queue: \(error.localizedDescription)")
        }
    }
    
    func loadQueue() -> [DownloadItem] {
        guard FileManager.default.fileExists(atPath: queueFile.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: queueFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let items = try decoder.decode([DownloadItem].self, from: data)
            writeDebugLog("[DownloadPersistence] Loaded \(items.count) items from queue")
            return items
        } catch {
            writeDebugLog("[DownloadPersistence] Failed to load queue: \(error.localizedDescription)")
            return []
        }
    }
    
    func clearQueue() {
        try? FileManager.default.removeItem(at: queueFile)
        writeDebugLog("[DownloadPersistence] Cleared queue file")
    }
    
    // MARK: - History Persistence
    
    func addToHistory(item: DownloadItem, filePath: String) {
        var history = loadHistory()
        
        let entry = DownloadHistoryEntry(
            id: item.id,
            trackId: item.track.id,
            trackName: item.track.trackName,
            artistName: item.track.artistName,
            albumName: item.track.albumName,
            filePath: filePath,
            quality: item.qualityOverride,
            completedAt: Date(),
            service: item.service
        )
        
        history.append(entry)
        
        // Keep only last 1000 entries
        if history.count > 1000 {
            history.removeFirst(history.count - 1000)
        }
        
        saveHistory(history)
    }
    
    func loadHistory() -> [DownloadHistoryEntry] {
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: historyFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            return try decoder.decode([DownloadHistoryEntry].self, from: data)
        } catch {
            writeDebugLog("[DownloadPersistence] Failed to load history: \(error.localizedDescription)")
            return []
        }
    }
    
    private func saveHistory(_ history: [DownloadHistoryEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            
            let data = try encoder.encode(history)
            try data.write(to: historyFile, options: .atomic)
            
            writeDebugLog("[DownloadPersistence] Saved history with \(history.count) entries")
        } catch {
            writeDebugLog("[DownloadPersistence] Failed to save history: \(error.localizedDescription)")
        }
    }
    
    func clearHistory() {
        try? FileManager.default.removeItem(at: historyFile)
        writeDebugLog("[DownloadPersistence] Cleared history file")
    }
}

// MARK: - Download History Entry

struct DownloadHistoryEntry: Codable {
    let id: String
    let trackId: String
    let trackName: String
    let artistName: String
    let albumName: String
    let filePath: String
    let quality: DownloadQuality?
    let completedAt: Date
    let service: String
    
    var displayName: String {
        return "\(artistName) - \(trackName)"
    }
}
