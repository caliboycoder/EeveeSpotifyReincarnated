import Foundation

// MARK: - Observer that bridges download completions to offline system

/// Observes DownloadManager for completions and registers them for offline playback.
final class OfflineDownloadObserver: NSObject, DownloadManagerObserver {
    static let shared = OfflineDownloadObserver()
    
    private override init() {
        super.init()
        // Auto-register with the download manager
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DownloadManager.shared.addObserver(self)
        }
    }
    
    func downloadManager(_ manager: DownloadManagerProtocol, didCompleteItem itemId: String, filePath: String) {
        guard let item = manager.state.item(withId: itemId) else { return }
        
        // Register this downloaded track for offline playback
        OfflinePlaybackManager.shared.registerDownloadedTrack(
            trackId: item.track.id,
            filePath: filePath,
            trackName: item.track.trackName,
            artistName: item.track.artistName,
            albumName: item.track.albumName,
            duration: item.track.durationMs,
            artworkURL: item.track.artworkURL
        )
        
        writeDebugLog("[OfflineObserver] Registered for offline: \(item.track.displayName)")
    }
    
    // Default empty implementations
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateState state: DownloadQueueState) {}
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateProgress itemId: String, progress: DownloadProgress) {}
    func downloadManager(_ manager: DownloadManagerProtocol, didFailItem itemId: String, error: DownloadError) {}
}
