import Foundation

/// Resolves file paths for downloads based on folder organization settings
class FilePathResolver {
    
    // MARK: - Default Directory
    
    var defaultDownloadDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotify Downloads", isDirectory: true)
    }
    
    // MARK: - Path Construction
    
    func constructFilePath(
        for item: DownloadItem,
        options: DownloadOptions,
        baseDirectory: URL
    ) -> URL {
        var components: [String] = []
        
        // Playlist folder (if batch download and enabled)
        if let playlistName = item.playlistName, options.createPlaylistFolders, item.fromBatch {
            components.append(sanitize(playlistName))
        }
        
        // Folder organization
        switch options.folderOrganization {
        case .none:
            break
            
        case .artist:
            components.append(sanitize(item.track.artistName))
            
        case .album:
            components.append(sanitize(item.track.albumName))
            
        case .artistAlbum:
            components.append(sanitize(item.track.artistName))
            components.append(sanitize(item.track.albumName))
            
        case .playlist:
            // Already handled above
            break
        }
        
        // Separate singles (if enabled)
        if options.separateSingles && isSingle(item) {
            if components.isEmpty {
                components.append("Singles")
            } else {
                components.append("Singles")
            }
        }
        
        // Build directory path
        let directory = components.reduce(baseDirectory) { $0.appendingPathComponent($1, isDirectory: true) }
        
        // Construct filename
        let filename = constructFilename(for: item, options: options)
        
        return directory.appendingPathComponent(filename)
    }
    
    // MARK: - Filename Construction
    
    private func constructFilename(for item: DownloadItem, options: DownloadOptions) -> String {
        let artist = sanitize(item.track.artistName)
        let track = sanitize(item.track.trackName)
        
        // Determine extension
        let ext = options.autoConvertFormat?.fileExtension ?? "mp3"
        
        // Quality label (if enabled)
        var qualityLabel = ""
        if let quality = item.qualityOverride {
            qualityLabel = " [\(quality.bitrateKbps)kbps]"
        }
        
        return "\(artist) - \(track)\(qualityLabel).\(ext)"
    }
    
    // MARK: - Helpers
    
    private func sanitize(_ string: String) -> String {
        // Remove invalid filename characters
        let invalid: CharacterSet = .init(charactersIn: "<>:\"/\\|?*")
        let components = string.components(separatedBy: invalid)
        let cleaned = components.joined()
        
        // Trim whitespace and dots
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        // Ensure non-empty
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
    
    private func isSingle(_ item: DownloadItem) -> Bool {
        // Heuristic: Consider it a single if album name contains "Single" or matches track name
        let albumLower = item.track.albumName.lowercased()
        let trackLower = item.track.trackName.lowercased()
        
        return albumLower.contains("single") ||
               albumLower.contains(" - single") ||
               albumLower == trackLower
    }
    
    // MARK: - Path Validation
    
    func validateDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        
        if !exists {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return true
            } catch {
                writeDebugLog("[FilePathResolver] Failed to create directory: \(error.localizedDescription)")
                return false
            }
        }
        
        return isDirectory.boolValue
    }
    
    func isWritable(_ url: URL) -> Bool {
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}
