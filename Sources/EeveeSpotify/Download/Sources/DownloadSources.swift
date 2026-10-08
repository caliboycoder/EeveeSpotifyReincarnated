import Foundation
import CryptoKit

// MARK: - Errors

enum DownloadSourceError: LocalizedError {
    case invalidURL
    case network(String)
    case http(Int)
    case tooLarge
    case notAFeed
    case noEpisodes

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "dl_err_invalid_url".localized
        case .network(let message): return message
        case .http(let code): return "HTTP \(code)"
        case .tooLarge: return "dl_err_too_large".localized
        case .notAFeed: return "dl_err_not_feed".localized
        case .noEpisodes: return "dl_err_no_episodes".localized
        }
    }
}

// MARK: - Direct URLs

/// Builds queue entries for plain audio files the user already has a link to.
enum DownloadSources {

    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "flac", "wav", "aiff"]

    /// Returns an http(s) URL with a host, or nil.
    static func validatedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Stable id so the same URL is not queued twice.
    static func trackId(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "url-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func fileExtension(mimeType: String?, url: URL) -> String {
        if let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() {
            switch mime {
            case "audio/mpeg", "audio/mp3": return "mp3"
            case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
            case "audio/aac", "audio/aacp": return "aac"
            case "audio/ogg", "application/ogg": return "ogg"
            case "audio/opus": return "opus"
            case "audio/flac", "audio/x-flac": return "flac"
            case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
            default: break
            }
        }
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) ? ext : "mp3"
    }

    static func makeTrack(directURL url: URL) -> SpotifyTrack {
        let rawName = url.deletingPathExtension().lastPathComponent
        let name = rawName.removingPercentEncoding ?? rawName
        return SpotifyTrack(
            id: trackId(for: url),
            isrc: nil,
            trackName: name.isEmpty ? (url.host ?? "Audio") : name,
            artistName: "Imported",
            albumName: url.host ?? "Imported",
            durationMs: 0,
            sourceURL: url.absoluteString,
            fileExtension: fileExtension(mimeType: nil, url: url)
        )
    }

    static func makeTrack(episode: PodcastEpisode, show: PodcastFeed) -> SpotifyTrack {
        return SpotifyTrack(
            id: trackId(for: episode.audioURL),
            isrc: nil,
            trackName: episode.title,
            artistName: show.author ?? show.title,
            albumName: show.title,
            durationMs: episode.durationSeconds * 1000,
            artworkURL: show.imageURL,
            sourceURL: episode.audioURL.absoluteString,
            fileExtension: fileExtension(mimeType: episode.mimeType, url: episode.audioURL)
        )
    }
}

// MARK: - Podcast models

struct PodcastShow: Identifiable {
    let name: String
    let author: String?
    let feedURL: URL
    let artworkURL: String?

    var id: String { feedURL.absoluteString }
}

struct PodcastEpisode: Identifiable {
    let title: String
    let audioURL: URL
    let mimeType: String?
    let durationSeconds: Int
    let published: String?

    var id: String { audioURL.absoluteString }
}

struct PodcastFeed {
    var title: String
    var author: String?
    var imageURL: String?
    var episodes: [PodcastEpisode]
}

// MARK: - Network

/// Public, documented sources only: the iTunes Search API (to find a show's RSS feed) and the RSS
/// feed itself (whose `<enclosure>` tags link to the episode audio files).
enum PodcastDirectory {

    private static let maxFeedBytes = 20 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    // MARK: Search

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let collectionName: String?
            let artistName: String?
            let feedUrl: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Completion is always called on the main queue.
    static func search(term: String, completion: @escaping (Result<[PodcastShow], Error>) -> Void) {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "term", value: term),
        ]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(DownloadSourceError.invalidURL)) }
            return
        }

        fetch(url) { result in
            let mapped: Result<[PodcastShow], Error> = result.flatMap { (data: Data) -> Result<[PodcastShow], Error> in
                do {
                    let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
                    let shows: [PodcastShow] = decoded.results.compactMap { item in
                        guard let name = item.collectionName,
                              let feed = item.feedUrl.flatMap(DownloadSources.validatedURL) else { return nil }
                        return PodcastShow(name: name, author: item.artistName, feedURL: feed, artworkURL: item.artworkUrl100)
                    }
                    return .success(shows)
                } catch {
                    return .failure(error)
                }
            }
            DispatchQueue.main.async { completion(mapped) }
        }
    }

    // MARK: Feed

    /// Completion is always called on the main queue.
    static func loadFeed(url: URL, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        fetch(url) { result in
            let mapped: Result<PodcastFeed, Error> = result.flatMap { (data: Data) -> Result<PodcastFeed, Error> in
                let parser = PodcastFeedParser()
                if let feed = parser.parse(data) {
                    return feed.episodes.isEmpty ? .failure(DownloadSourceError.noEpisodes) : .success(feed)
                }
                return .failure(DownloadSourceError.notAFeed)
            }
            DispatchQueue.main.async { completion(mapped) }
        }
    }

    private static func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(DownloadSourceError.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(DownloadSourceError.http(http.statusCode)))
                return
            }
            guard let data = data else {
                completion(.failure(DownloadSourceError.notAFeed))
                return
            }
            guard data.count <= maxFeedBytes else {
                completion(.failure(DownloadSourceError.tooLarge))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

// MARK: - RSS parser

/// Minimal RSS 2.0 reader. Only reads channel title/author/image and per-item title, enclosure,
/// duration and date. External entities are not resolved (XMLParser default).
final class PodcastFeedParser: NSObject, XMLParserDelegate {

    static let maxEpisodes = 300

    private var feed = PodcastFeed(title: "", author: nil, imageURL: nil, episodes: [])
    private var text = ""
    private var inItem = false
    private var inChannelImage = false
    private var sawChannel = false
    private var reachedLimit = false

    private var itemTitle = ""
    private var itemEnclosureURL: URL?
    private var itemMime: String?
    private var itemDuration = 0
    private var itemDate: String?

    /// Returns nil when the data is not an RSS feed.
    func parse(_ data: Data) -> PodcastFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        guard sawChannel, ok || reachedLimit else { return nil }
        if feed.title.isEmpty { feed.title = "Podcast" }
        return feed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "channel":
            sawChannel = true
        case "item":
            inItem = true
            itemTitle = ""
            itemEnclosureURL = nil
            itemMime = nil
            itemDuration = 0
            itemDate = nil
        case "image":
            if !inItem { inChannelImage = true }
        case "enclosure":
            if inItem, let urlString = attributeDict["url"], let url = DownloadSources.validatedURL(urlString) {
                itemEnclosureURL = url
                itemMime = attributeDict["type"]
            }
        case "itunes:image":
            if !inItem, feed.imageURL == nil, let href = attributeDict["href"] {
                feed.imageURL = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if inItem { itemTitle = value } else if !inChannelImage && feed.title.isEmpty { feed.title = value }
        case "itunes:author":
            if !inItem && feed.author == nil && !value.isEmpty { feed.author = value }
        case "url":
            if inChannelImage && feed.imageURL == nil && !value.isEmpty { feed.imageURL = value }
        case "image":
            inChannelImage = false
        case "itunes:duration":
            if inItem { itemDuration = Self.seconds(from: value) }
        case "pubDate":
            if inItem { itemDate = value }
        case "item":
            inItem = false
            if let audioURL = itemEnclosureURL {
                feed.episodes.append(PodcastEpisode(
                    title: itemTitle.isEmpty ? audioURL.deletingPathExtension().lastPathComponent : itemTitle,
                    audioURL: audioURL,
                    mimeType: itemMime,
                    durationSeconds: itemDuration,
                    published: itemDate
                ))
                if feed.episodes.count >= Self.maxEpisodes {
                    reachedLimit = true
                    parser.abortParsing()
                }
            }
        default:
            break
        }
        text = ""
    }

    /// Accepts "SS", "MM:SS" and "HH:MM:SS".
    static func seconds(from string: String) -> Int {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}
