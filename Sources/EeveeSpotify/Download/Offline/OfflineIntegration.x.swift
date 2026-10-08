import Orion
import UIKit

// MARK: - Offline playback activation

/// Activate the offline playback system on tweak launch
func activateOfflinePlayback() {
    // Ensure the offline database is loaded
    _ = OfflineTrackDatabase.shared
    
    // Ensure the observer is registered with download manager
    _ = OfflineDownloadObserver.shared
    
    writeDebugLog("[Offline] Offline playback system activated")
}

// MARK: - Hook Group

struct OfflineIntegrationGroup: HookGroup {}
