import Foundation

/// Resolves Spotify track IDs to downloadable audio stream URLs.
///
/// Uses Spotify's internal spclient API to obtain playback manifests with CDN URLs.
/// Requires a valid OAuth token captured from Spotify's network traffic.
final class SpotifyAudioResolver {
    
    // MARK: - Errors
    
    enum ResolverError: Error {
        case noAccessToken
        case invalidTrackId
        case networkError(Error)
        case noManifest
        case noAudioFiles
        case unsupportedFormat
        case httpError(Int)
        
        var localizedDescription: String {
            switch self {
            case .noAccessToken: return "No Spotify access token available"
            case .invalidTrackId: return "Invalid track ID"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .noManifest: return "No playback manifest received"
            case .noAudioFiles: return "No audio files in manifest"
            case .unsupportedFormat: return "No compatible audio format found"
            case .httpError(let code): return "HTTP error \(code)"
            }
        }
    }
    
    // MARK: - Result
    
    struct AudioFile {
        let url: URL
        let format: AudioFormat
        let bitrate: Int  // kbps
        let fileId: String
        
        enum AudioFormat: String {
            case oggVorbis = "ogg_vorbis"
            case mp4Aac = "mp4_aac"
            case mp3 = "mp3"
        }
    }
    
    // MARK: - Properties
    
    private let session: URLSession
    private let baseURL = "https://spclient.wg.spotify.com"
    
    // MARK: - Init
    
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Spotify/iOS"
        ]
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Resolution
    
    /// Resolves a track to its audio stream URLs.
    ///
    /// - Parameters:
    ///   - track: The Spotify track to resolve
    ///   - quality: Desired download quality
    ///   - accessToken: OAuth Bearer token from Spotify session
    /// - Returns: Audio file URL for download
    func resolveAudioURL(
        for track: SpotifyTrack,
        quality: DownloadQuality,
        accessToken: String
    ) throws -> URL {
        // Extract hex GID from Spotify URI (spotify:track:XXXX)
        guard let gid = extractGID(from: track.id) else {
            throw ResolverError.invalidTrackId
        }
        
        // Fetch playback manifest
        let manifest = try fetchPlaybackManifest(gid: gid, accessToken: accessToken)
        
        // Parse audio files
        let audioFiles = try parseAudioFiles(from: manifest)
        
        // Select best matching file
        guard let selected = selectAudioFile(from: audioFiles, preferredQuality: quality) else {
            throw ResolverError.noAudioFiles
        }
        
        writeDebugLog("[AudioResolver] Resolved \(track.displayName) → \(selected.format.rawValue) @ \(selected.bitrate)kbps")
        return selected.url
    }
    
    // MARK: - Manifest Fetching
    
    private func fetchPlaybackManifest(gid: String, accessToken: String) throws -> Data {
        // Spotify's track playback manifest endpoint
        let urlString = "\(baseURL)/track-playback/v1/audio/track/\(gid)?product=9"
        guard let url = URL(string: urlString) else {
            throw ResolverError.invalidTrackId
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        var result: (Data?, URLResponse?, Error?)?
        let semaphore = DispatchSemaphore(value: 0)
        
        session.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        
        semaphore.wait()
        
        guard let (data, response, error) = result else {
            throw ResolverError.networkError(NSError(domain: "AudioResolver", code: -1))
        }
        
        if let error = error {
            throw ResolverError.networkError(error)
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else {
                writeDebugLog("[AudioResolver] HTTP \(httpResponse.statusCode) from \(url.absoluteString)")
                throw ResolverError.httpError(httpResponse.statusCode)
            }
        }
        
        guard let data = data, !data.isEmpty else {
            throw ResolverError.noManifest
        }
        
        return data
    }
    
    // MARK: - Parsing
    
    private func parseAudioFiles(from data: Data) throws -> [AudioFile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolverError.noManifest
        }
        
        // Manifest structure: { "cdnurl": [...], "file_id": "...", ... }
        guard let cdnUrls = json["cdnurl"] as? [[String: Any]] else {
            writeDebugLog("[AudioResolver] No cdnurl array in manifest")
            throw ResolverError.noAudioFiles
        }
        
        var files: [AudioFile] = []
        
        for entry in cdnUrls {
            guard let urlString = entry["url"] as? String,
                  let url = URL(string: urlString),
                  let fileIdHex = entry["file_id"] as? String else {
                continue
            }
            
            // Detect format from URL or file extension
            let format: AudioFile.AudioFormat
            let bitrate: Int
            
            if urlString.contains(".ogg") || urlString.contains("vorbis") {
                format = .oggVorbis
                bitrate = inferBitrate(from: entry) ?? 320
            } else if urlString.contains(".mp4") || urlString.contains("m4a") || urlString.contains("aac") {
                format = .mp4Aac
                bitrate = inferBitrate(from: entry) ?? 256
            } else if urlString.contains(".mp3") {
                format = .mp3
                bitrate = inferBitrate(from: entry) ?? 320
            } else {
                continue  // Unknown format
            }
            
            files.append(AudioFile(
                url: url,
                format: format,
                bitrate: bitrate,
                fileId: fileIdHex
            ))
        }
        
        guard !files.isEmpty else {
            throw ResolverError.noAudioFiles
        }
        
        return files
    }
    
    private func inferBitrate(from entry: [String: Any]) -> Int? {
        // Try to extract bitrate from manifest metadata
        if let bitrate = entry["bitrate"] as? Int {
            return bitrate / 1000  // Convert bps to kbps
        }
        
        // Check for quality indicators
        if let quality = entry["quality"] as? String {
            switch quality.lowercased() {
            case "low", "96": return 96
            case "normal", "160": return 160
            case "high", "320": return 320
            case "very_high", "vorbis": return 320
            default: break
            }
        }
        
        return nil
    }
    
    // MARK: - Selection
    
    private func selectAudioFile(from files: [AudioFile], preferredQuality: DownloadQuality) -> AudioFile? {
        let targetBitrate = preferredQuality.bitrateKbps
        
        // Prefer Ogg Vorbis (higher quality, better compression)
        let vorbisFiles = files.filter { $0.format == .oggVorbis }
        let aacFiles = files.filter { $0.format == .mp4Aac }
        let mp3Files = files.filter { $0.format == .mp3 }
        
        // Try Vorbis first
        if let best = selectClosestBitrate(from: vorbisFiles, target: targetBitrate) {
            return best
        }
        
        // Fall back to AAC
        if let best = selectClosestBitrate(from: aacFiles, target: targetBitrate) {
            return best
        }
        
        // Last resort: MP3
        if let best = selectClosestBitrate(from: mp3Files, target: targetBitrate) {
            return best
        }
        
        // Return any file if nothing matches
        return files.first
    }
    
    private func selectClosestBitrate(from files: [AudioFile], target: Int) -> AudioFile? {
        guard !files.isEmpty else { return nil }
        
        return files.min(by: { file1, file2 in
            abs(file1.bitrate - target) < abs(file2.bitrate - target)
        })
    }
    
    // MARK: - Helpers
    
    private func extractGID(from trackId: String) -> String? {
        // Handle both URIs (spotify:track:XXXX) and IDs (XXXX)
        let id = trackId.replacingOccurrences(of: "spotify:track:", with: "")
        
        // Spotify track IDs are base62-encoded
        // For the API, we need the hex GID (globally unique identifier)
        // If ID is already 22 chars, it's likely base62
        guard id.count == 22 else {
            return id  // Assume it's already in the right format
        }
        
        // Convert base62 to hex GID
        return base62ToHex(id)
    }
    
    private func base62ToHex(_ base62: String) -> String? {
        // Spotify's base62 alphabet
        let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let base = UInt64(62)
        
        var number: UInt64 = 0
        
        for char in base62 {
            guard let index = alphabet.firstIndex(of: char) else {
                return nil
            }
            let value = UInt64(alphabet.distance(from: alphabet.startIndex, to: index))
            number = number * base + value
        }
        
        // Convert to 32-character hex string (16 bytes)
        return String(format: "%032llx", number)
    }
}
