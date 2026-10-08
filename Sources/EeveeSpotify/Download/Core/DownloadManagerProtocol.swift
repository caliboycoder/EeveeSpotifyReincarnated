import Foundation

// MARK: - Download Manager Protocol

protocol DownloadManagerProtocol: AnyObject {
    /// Current queue state (immutable snapshot)
    var state: DownloadQueueState { get }
    
    /// Configuration options
    var options: DownloadOptions { get set }
    
    /// Start/resume the download queue
    func resumeQueue()
    
    /// Pause all active downloads
    func pauseQueue()
    
    /// Add single track to queue
    /// - Returns: Item ID of queued download
    @discardableResult
    func addToQueue(track: SpotifyTrack, quality: DownloadQuality?) -> String
    
    /// Add multiple tracks (playlist/album)
    func addBatch(tracks: [SpotifyTrack], playlistName: String?, quality: DownloadQuality?)
    
    /// Retry failed download
    func retryDownload(itemId: String)
    
    /// Cancel and remove from queue
    func cancelDownload(itemId: String)
    
    /// Remove completed/failed items
    func clearCompleted()
    
    /// Clear all items from queue
    func clearAll()
    
    /// Register observer for state changes
    func addObserver(_ observer: DownloadManagerObserver)
    
    /// Unregister observer
    func removeObserver(_ observer: DownloadManagerObserver)
}

// MARK: - Download Manager Observer

protocol DownloadManagerObserver: AnyObject {
    /// Queue state changed (item added, removed, status updated)
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateState state: DownloadQueueState)
    
    /// Individual item progress updated
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateProgress itemId: String, progress: DownloadProgress)
    
    /// Download completed successfully
    func downloadManager(_ manager: DownloadManagerProtocol, didCompleteItem itemId: String, filePath: String)
    
    /// Download failed
    func downloadManager(_ manager: DownloadManagerProtocol, didFailItem itemId: String, error: DownloadError)
}

// MARK: - Optional Observer Methods (Default Empty Implementations)

extension DownloadManagerObserver {
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateState state: DownloadQueueState) {}
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateProgress itemId: String, progress: DownloadProgress) {}
    func downloadManager(_ manager: DownloadManagerProtocol, didCompleteItem itemId: String, filePath: String) {}
    func downloadManager(_ manager: DownloadManagerProtocol, didFailItem itemId: String, error: DownloadError) {}
}

// MARK: - Notification Names

extension Notification.Name {
    static let downloadQueueStateDidChange = Notification.Name("com.eevee.downloadmanager.stateChanged")
    static let downloadProgressDidUpdate = Notification.Name("com.eevee.downloadmanager.progressUpdated")
    static let downloadDidComplete = Notification.Name("com.eevee.downloadmanager.completed")
    static let downloadDidFail = Notification.Name("com.eevee.downloadmanager.failed")
}

// MARK: - Notification UserInfo Keys

struct DownloadManagerNotificationKeys {
    static let state = "state"
    static let itemId = "itemId"
    static let progress = "progress"
    static let filePath = "filePath"
    static let error = "error"
}
