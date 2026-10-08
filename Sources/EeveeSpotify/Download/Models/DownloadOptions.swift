import Foundation

// MARK: - Download Options

struct DownloadOptions: Codable {
    /// Feature enabled flag
    var enabled: Bool
    
    /// Default download quality
    var defaultQuality: DownloadQuality
    
    /// Concurrent download limit (1-3)
    var concurrentDownloads: Int
    
    /// WiFi-only restriction
    var wifiOnly: Bool
    
    /// Download location (security-scoped bookmark data)
    var downloadLocationBookmark: Data?
    
    /// Folder organization mode
    var folderOrganization: FolderOrganizationMode
    
    /// Create playlist folders for batch downloads
    var createPlaylistFolders: Bool
    
    /// Separate singles from albums
    var separateSingles: Bool
    
    /// Auto-convert to format (optional)
    var autoConvertFormat: AudioFormat?
    
    /// Embed album artwork
    var embedArtwork: Bool
    
    /// Show download notifications
    var showNotifications: Bool
    
    // MARK: - Defaults
    
    init(
        enabled: Bool = false,
        defaultQuality: DownloadQuality = .high,
        concurrentDownloads: Int = 2,
        wifiOnly: Bool = true,
        downloadLocationBookmark: Data? = nil,
        folderOrganization: FolderOrganizationMode = .artistAlbum,
        createPlaylistFolders: Bool = true,
        separateSingles: Bool = false,
        autoConvertFormat: AudioFormat? = nil,
        embedArtwork: Bool = true,
        showNotifications: Bool = true
    ) {
        self.enabled = enabled
        self.defaultQuality = defaultQuality
        self.concurrentDownloads = max(1, min(3, concurrentDownloads))  // Clamp 1-3
        self.wifiOnly = wifiOnly
        self.downloadLocationBookmark = downloadLocationBookmark
        self.folderOrganization = folderOrganization
        self.createPlaylistFolders = createPlaylistFolders
        self.separateSingles = separateSingles
        self.autoConvertFormat = autoConvertFormat
        self.embedArtwork = embedArtwork
        self.showNotifications = showNotifications
    }
    
    /// Validate and clamp concurrent downloads
    mutating func validateConcurrency() {
        concurrentDownloads = max(1, min(3, concurrentDownloads))
    }
}

// MARK: - Folder Organization Mode

enum FolderOrganizationMode: String, Codable, CaseIterable {
    case none = "Flat"
    case artist = "By Artist"
    case album = "By Album"
    case artistAlbum = "Artist / Album"
    case playlist = "By Playlist"
    
    var displayName: String {
        return self.rawValue
    }
    
    var description: String {
        switch self {
        case .none:
            return "All files in download folder"
        case .artist:
            return "Artist Name/Track.mp3"
        case .album:
            return "Album Name/Track.mp3"
        case .artistAlbum:
            return "Artist Name/Album Name/Track.mp3"
        case .playlist:
            return "Playlist Name/Track.mp3"
        }
    }
}

// MARK: - Audio Format

enum AudioFormat: String, Codable, CaseIterable {
    case mp3 = "MP3"
    case aac = "AAC"
    case flac = "FLAC"
    case opus = "Opus"
    
    var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .aac: return "m4a"
        case .flac: return "flac"
        case .opus: return "opus"
        }
    }
    
    var displayName: String {
        return self.rawValue
    }
    
    var supportsConversion: Bool {
        // FLAC is lossless source, others are lossy targets
        return self != .flac
    }
}

// MARK: - Download Progress

struct DownloadProgress {
    let itemId: String
    let bytesReceived: Int64
    let bytesTotal: Int64
    let progress: Double
    let speedMBps: Double
    let timeRemaining: TimeInterval?
    
    var progressPercentage: Int {
        return Int(progress * 100)
    }
    
    var formattedSpeed: String {
        if speedMBps < 1.0 {
            return String(format: "%.0f KB/s", speedMBps * 1024)
        } else {
            return String(format: "%.1f MB/s", speedMBps)
        }
    }
    
    var formattedBytesReceived: String {
        return ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
    }
    
    var formattedBytesTotal: String {
        return ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
    }
    
    var formattedTimeRemaining: String? {
        guard let remaining = timeRemaining, remaining > 0 else { return nil }
        
        if remaining < 60 {
            return "\(Int(remaining))s"
        } else if remaining < 3600 {
            let minutes = Int(remaining / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}

// MARK: - Download Error

struct DownloadError {
    let type: DownloadErrorType
    let message: String
    let underlyingError: Error?
    
    init(type: DownloadErrorType, message: String, underlyingError: Error? = nil) {
        self.type = type
        self.message = message
        self.underlyingError = underlyingError
    }
    
    var localizedDescription: String {
        switch type {
        case .notFound:
            return "Track not available for download"
        case .rateLimit:
            return "Rate limit exceeded. Please try again later."
        case .network:
            return "Network error: \(message)"
        case .permission:
            return "Storage permission denied"
        case .verificationRequired:
            return "Verification required"
        case .unknown:
            return "Download failed: \(message)"
        }
    }
    
    var isRetryable: Bool {
        return type.isRetryable
    }
}
