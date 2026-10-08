import Foundation

// MARK: - Download Status

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case finalizing
    case completed
    case failed
    case skipped
    
    var isActive: Bool {
        return self == .downloading || self == .finalizing
    }
    
    var isPersistable: Bool {
        return self == .queued || self == .failed
    }
}

// MARK: - Download Error Type

enum DownloadErrorType: String, Codable {
    case unknown
    case notFound          // Track unavailable
    case rateLimit         // API throttling
    case network           // Connection failure
    case permission        // Storage access denied
    case verificationRequired  // CAPTCHA/login needed
    
    var isRetryable: Bool {
        switch self {
        case .network, .rateLimit:
            return true
        case .notFound, .permission, .verificationRequired, .unknown:
            return false
        }
    }
}

// MARK: - Download Quality

enum DownloadQuality: String, Codable, CaseIterable {
    case low = "Low (96 kbps)"
    case medium = "Medium (160 kbps)"
    case high = "High (320 kbps)"
    case veryHigh = "Very High (Ogg Vorbis 320)"
    
    var bitrateKbps: Int {
        switch self {
        case .low: return 96
        case .medium: return 160
        case .high, .veryHigh: return 320
        }
    }
    
    var displayName: String {
        return self.rawValue
    }
}

// MARK: - Download Item

struct DownloadItem: Codable {
    // MARK: - Identity
    
    /// Unique ID: {isrc}-{timestamp}-{sequence}
    let id: String
    
    /// Spotify track metadata
    let track: SpotifyTrack
    
    /// Download service/provider (e.g., "SpotifyAPI", "Deezer")
    let service: String
    
    // MARK: - State
    
    /// Current download state
    var status: DownloadStatus
    
    /// Progress 0.0 to 1.0 (volatile, not persisted)
    var progress: Double
    
    /// Transfer speed in MB/s (volatile)
    var speedMBps: Double
    
    /// Downloaded bytes (volatile)
    var bytesReceived: Int64
    
    /// Total bytes (if known)
    var bytesTotal: Int64
    
    /// URLSessionDownloadTask identifier for tracking
    var taskIdentifier: Int?
    
    // MARK: - Result
    
    /// Final file path (set after completion)
    var filePath: String?
    
    /// Error message (if failed)
    var error: String?
    
    /// Categorized error type
    var errorType: DownloadErrorType?
    
    /// Preparation stage label
    var preparationStage: String
    
    // MARK: - Metadata
    
    /// Queue insertion timestamp
    let createdAt: Date
    
    /// Per-item quality override
    let qualityOverride: DownloadQuality?
    
    /// Batch context
    let playlistName: String?
    let playlistPosition: Int?
    let fromBatch: Bool
    
    // MARK: - Initialization
    
    init(
        id: String,
        track: SpotifyTrack,
        service: String,
        status: DownloadStatus = .queued,
        qualityOverride: DownloadQuality? = nil,
        playlistName: String? = nil,
        playlistPosition: Int? = nil,
        fromBatch: Bool = false
    ) {
        self.id = id
        self.track = track
        self.service = service
        self.status = status
        self.progress = 0.0
        self.speedMBps = 0.0
        self.bytesReceived = 0
        self.bytesTotal = 0
        self.taskIdentifier = nil
        self.filePath = nil
        self.error = nil
        self.errorType = nil
        self.preparationStage = ""
        self.createdAt = Date()
        self.qualityOverride = qualityOverride
        self.playlistName = playlistName
        self.playlistPosition = playlistPosition
        self.fromBatch = fromBatch
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case id, track, service, status, filePath, error, errorType
        case preparationStage, createdAt, qualityOverride
        case playlistName, playlistPosition, fromBatch
        // Volatile fields NOT encoded: progress, speedMBps, bytesReceived, bytesTotal, taskIdentifier
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(String.self, forKey: .id)
        self.track = try container.decode(SpotifyTrack.self, forKey: .track)
        self.service = try container.decode(String.self, forKey: .service)
        self.status = try container.decode(DownloadStatus.self, forKey: .status)
        self.filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.errorType = try container.decodeIfPresent(DownloadErrorType.self, forKey: .errorType)
        self.preparationStage = try container.decode(String.self, forKey: .preparationStage)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.qualityOverride = try container.decodeIfPresent(DownloadQuality.self, forKey: .qualityOverride)
        self.playlistName = try container.decodeIfPresent(String.self, forKey: .playlistName)
        self.playlistPosition = try container.decodeIfPresent(Int.self, forKey: .playlistPosition)
        self.fromBatch = try container.decode(Bool.self, forKey: .fromBatch)
        
        // Initialize volatile fields to defaults
        self.progress = 0.0
        self.speedMBps = 0.0
        self.bytesReceived = 0
        self.bytesTotal = 0
        self.taskIdentifier = nil
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(track, forKey: .track)
        try container.encode(service, forKey: .service)
        
        // Normalize status: active states → queued for persistence
        let persistStatus = status.isActive ? DownloadStatus.queued : status
        try container.encode(persistStatus, forKey: .status)
        
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(errorType, forKey: .errorType)
        try container.encode(preparationStage, forKey: .preparationStage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(qualityOverride, forKey: .qualityOverride)
        try container.encodeIfPresent(playlistName, forKey: .playlistName)
        try container.encodeIfPresent(playlistPosition, forKey: .playlistPosition)
        try container.encode(fromBatch, forKey: .fromBatch)
        
        // Volatile fields NOT encoded
    }
    
    // MARK: - Helpers
    
    /// Generate unique download item ID
    static func generateId(trackId: String) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let sequence = Int.random(in: 1000...9999)
        return "\(trackId)-\(timestamp)-\(sequence)"
    }
    
    /// Create normalized copy for persistence (zero volatile fields)
    func normalized() -> DownloadItem {
        var copy = self
        copy.progress = 0.0
        copy.speedMBps = 0.0
        copy.bytesReceived = 0
        copy.bytesTotal = 0
        copy.taskIdentifier = nil
        copy.status = status.isActive ? .queued : status
        return copy
    }
}

// MARK: - Spotify Track Model

struct SpotifyTrack: Codable {
    let id: String              // Spotify track ID
    let isrc: String?           // International Standard Recording Code
    let trackName: String
    let artistName: String
    let albumName: String
    let durationMs: Int
    let artworkURL: String?
    let previewURL: String?
    /// Direct URL of a plain audio file (user-supplied URL or podcast RSS enclosure).
    let sourceURL: String?
    /// File extension for the saved file, without the dot (e.g. "mp3").
    let fileExtension: String?
    
    init(
        id: String,
        isrc: String?,
        trackName: String,
        artistName: String,
        albumName: String,
        durationMs: Int,
        artworkURL: String? = nil,
        previewURL: String? = nil,
        sourceURL: String? = nil,
        fileExtension: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.fileExtension = fileExtension
        self.id = id
        self.isrc = isrc
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.previewURL = previewURL
    }
    
    var displayName: String {
        return "\(artistName) - \(trackName)"
    }
    
    var durationSeconds: Int {
        return durationMs / 1000
    }
}
