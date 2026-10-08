import Foundation

extension UserDefaults {
    
    // MARK: - Download Configuration
    
    @UserDefault(key: "eeveeDownloadOptions", defaultValue: DownloadOptions())
    static var downloadOptions
    
    // MARK: - Download History (Lightweight - Last 100 entries)
    
    private static let downloadHistoryKey = "eeveeDownloadHistoryLightweight"
    
    static var recentDownloadHistory: [DownloadHistoryEntry] {
        get {
            guard let data = container.data(forKey: downloadHistoryKey) else {
                return []
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            return (try? decoder.decode([DownloadHistoryEntry].self, from: data)) ?? []
        }
        set {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            // Keep only last 100 entries for lightweight storage
            let limited = Array(newValue.suffix(100))
            
            if let data = try? encoder.encode(limited) {
                container.set(data, forKey: downloadHistoryKey)
            }
        }
    }
    
    // MARK: - Feature Flag
    
    private static let downloadFeatureEnabledKey = "eeveeDownloadFeatureEnabled"
    
    static var downloadFeatureEnabled: Bool {
        get {
            return container.object(forKey: downloadFeatureEnabledKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: downloadFeatureEnabledKey)
        }
    }
    
    // MARK: - Queue State
    
    private static let downloadQueuePausedKey = "eeveeDownloadQueuePaused"
    
    static var downloadQueuePaused: Bool {
        get {
            return container.bool(forKey: downloadQueuePausedKey)
        }
        set {
            container.set(newValue, forKey: downloadQueuePausedKey)
        }
    }
}
