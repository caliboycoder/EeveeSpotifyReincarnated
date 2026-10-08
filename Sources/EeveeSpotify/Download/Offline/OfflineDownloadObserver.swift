import Foundation

/// Adds every finished download to the offline index.
final class OfflineDownloadObserver: NSObject, DownloadManagerObserver {

    static let shared = OfflineDownloadObserver()

    func downloadManager(_ manager: DownloadManagerProtocol, didCompleteItem itemId: String, filePath: String) {
        guard let item = manager.state.item(withId: itemId) else { return }
        OfflinePlaybackManager.shared.register(
            trackId: item.track.id,
            filePath: filePath,
            trackName: item.track.trackName,
            artistName: item.track.artistName,
            albumName: item.track.albumName,
            durationMs: item.track.durationMs,
            artworkURL: item.track.artworkURL
        )
    }
}

/// Called from `DownloadManager.activateDownloadManager()`, so it only runs when downloads are enabled.
/// Must run after `DownloadManager.shared` exists.
func activateOfflinePlayback() {
    DownloadManager.shared.addObserver(OfflineDownloadObserver.shared)

    // Pick up downloads finished before the offline index existed.
    DispatchQueue.global(qos: .utility).async {
        let history = DownloadPersistence().loadHistory()
        DispatchQueue.main.async {
            let added = OfflinePlaybackManager.shared.backfill(from: history)
            if added > 0 { writeDebugLog("[Offline] Backfilled \(added) earlier downloads") }
        }
    }
}
