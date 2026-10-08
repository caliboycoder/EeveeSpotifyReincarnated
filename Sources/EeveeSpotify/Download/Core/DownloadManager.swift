import Foundation
import UIKit

/// Download queue orchestrator.
///
/// Concurrency model: every piece of mutable state (`_currentState`, `activeDownloads`,
/// `retryAttempts`, `retryNotBefore`, `lastProgressUpdate`) is only touched on `stateQueue`
/// (serial). Methods suffixed `Locked` must be called from `stateQueue`. The concurrency
/// limit is enforced by counting active items in `processQueueLocked()`, so there is no
/// semaphore to leak.
final class DownloadManager: NSObject, DownloadManagerProtocol {

    // MARK: - Singleton

    static let shared = DownloadManager()

    /// Stable identifier so a recreated session reattaches to the same background session.
    static let sessionIdentifier = "com.eevee.spotify.downloads"

    // MARK: - State (stateQueue only)

    private let stateQueue = DispatchQueue(label: "com.eevee.downloadmanager.state")
    private var _currentState: DownloadQueueState = .empty
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private var retryAttempts: [String: Int] = [:]
    private var retryNotBefore: [String: Date] = [:]
    private var lastProgressUpdate: [String: Date] = [:]
    private var persistWorkItem: DispatchWorkItem?

    /// Immutable snapshot. Do not call from `stateQueue` (would deadlock).
    var state: DownloadQueueState {
        return stateQueue.sync { _currentState }
    }

    // MARK: - Configuration

    var options: DownloadOptions {
        get { return UserDefaults.downloadOptions }
        set { UserDefaults.downloadOptions = newValue }
    }

    /// Maps a track to the URL that should be downloaded.
    ///
    /// Direct audio URLs (`sourceURL`) come first; `previewURL` is the fallback for
    /// preview-only tracks. Replace this closure to plug in another source.
    var resolveDownloadURL: (SpotifyTrack, DownloadQuality) -> URL? = { track, _ in
        return (track.sourceURL ?? track.previewURL).flatMap { URL(string: $0) }
    }

    // MARK: - Observers (guarded by observersLock)

    private let observersLock = NSLock()
    private let observers = NSHashTable<AnyObject>.weakObjects()

    // MARK: - Collaborators

    private let persistence = DownloadPersistence()
    private let filePathResolver = FilePathResolver()
    private let progressTracker = DownloadProgressTracker()
    private let persistenceDelay: TimeInterval = 0.35
    private let progressUpdateInterval: TimeInterval = 0.1
    private let maxRetryAttempts = 1
    private let retryDelay: TimeInterval = 2.0

    private var urlSession: URLSession!

    private static let stagingDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotify/Downloads/staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Init

    private override init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: DownloadManager.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = !UserDefaults.downloadOptions.wifiOnly
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // The persisted queue resets in-flight items to `queued`, so any task left over from a
        // previous process would be a duplicate. Cancel them; stale callbacks are ignored.
        urlSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)

        restoreQueue()
    }

    // MARK: - Queue control

    func resumeQueue() {
        stateQueue.async {
            if self._currentState.isPaused {
                self._currentState = self._currentState.toggling(pause: false)
                self.notifyStateChanged()
            }
            self.processQueueLocked()
        }
    }

    func pauseQueue() {
        stateQueue.async {
            guard !self._currentState.isPaused else { return }
            self._currentState = self._currentState.toggling(pause: true)

            let activeIds = Array(self.activeDownloads.keys)
            for (_, task) in self.activeDownloads { task.cancel() }
            self.activeDownloads.removeAll()
            for id in activeIds {
                self._currentState = self._currentState.updating(itemId: id) { Self.resetToQueued(&$0) }
            }

            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
        }
    }

    @discardableResult
    func addToQueue(track: SpotifyTrack, quality: DownloadQuality? = nil) -> String {
        return stateQueue.sync {
            if let existing = _currentState.item(withTrackId: track.id) {
                return existing.id
            }
            let item = DownloadItem(
                id: DownloadItem.generateId(trackId: track.id),
                track: track,
                service: "SpotifyAPI",
                qualityOverride: quality
            )
            _currentState = _currentState.adding(item)
            scheduleQueuePersistenceLocked()
            notifyStateChanged()
            processQueueLocked()
            return item.id
        }
    }

    func addBatch(tracks: [SpotifyTrack], playlistName: String? = nil, quality: DownloadQuality? = nil) {
        stateQueue.async {
            var seen = Set<String>()
            var newItems: [DownloadItem] = []
            for (index, track) in tracks.enumerated() {
                guard !self._currentState.contains(trackId: track.id), seen.insert(track.id).inserted else { continue }
                newItems.append(DownloadItem(
                    id: DownloadItem.generateId(trackId: track.id),
                    track: track,
                    service: "SpotifyAPI",
                    qualityOverride: quality,
                    playlistName: playlistName,
                    playlistPosition: index + 1,
                    fromBatch: true
                ))
            }
            guard !newItems.isEmpty else { return }

            self._currentState = self._currentState.adding(newItems)
            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
            self.processQueueLocked()
        }
    }

    func retryDownload(itemId: String) {
        stateQueue.async {
            guard let item = self._currentState.item(withId: itemId), item.status == .failed else { return }

            self._currentState = self._currentState.updating(itemId: itemId) { item in
                Self.resetToQueued(&item)
                item.error = nil
                item.errorType = nil
            }
            self.retryAttempts[itemId] = 0
            self.retryNotBefore[itemId] = nil
            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
            self.processQueueLocked()
        }
    }

    func cancelDownload(itemId: String) {
        stateQueue.async {
            guard self._currentState.item(withId: itemId) != nil else { return }
            self.forgetLocked(itemId: itemId)
            self._currentState = self._currentState.removing(itemId: itemId)
            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
            self.processQueueLocked()
        }
    }

    func clearCompleted() {
        stateQueue.async {
            let before = self._currentState.totalCount
            self._currentState = self._currentState.clearingCompleted()
            guard self._currentState.totalCount != before else { return }
            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
        }
    }

    func clearAll() {
        stateQueue.async {
            for id in Array(self.activeDownloads.keys) { self.forgetLocked(itemId: id) }
            self._currentState = DownloadQueueState(items: [], isPaused: self._currentState.isPaused)
            self.retryAttempts.removeAll()
            self.retryNotBefore.removeAll()
            self.scheduleQueuePersistenceLocked()
            self.notifyStateChanged()
        }
    }

    // MARK: - Observers

    func addObserver(_ observer: DownloadManagerObserver) {
        observersLock.lock(); defer { observersLock.unlock() }
        observers.add(observer as AnyObject)
    }

    func removeObserver(_ observer: DownloadManagerObserver) {
        observersLock.lock(); defer { observersLock.unlock() }
        observers.remove(observer as AnyObject)
    }

    // MARK: - Scheduling (stateQueue only)

    private func processQueueLocked() {
        guard !_currentState.isPaused else { return }

        let limit = max(1, min(3, options.concurrentDownloads))
        var free = limit - _currentState.activeCount
        guard free > 0 else { return }

        let now = Date()
        var earliestRetry: Date?

        for item in _currentState.items(withStatus: .queued) where free > 0 {
            if let notBefore = retryNotBefore[item.id], notBefore > now {
                earliestRetry = min(earliestRetry ?? notBefore, notBefore)
                continue
            }
            retryNotBefore[item.id] = nil
            if startLocked(item) { free -= 1 }
        }

        if let earliestRetry = earliestRetry {
            stateQueue.asyncAfter(deadline: .now() + max(0.1, earliestRetry.timeIntervalSinceNow)) { [weak self] in
                self?.processQueueLocked()
            }
        }
    }

    /// Returns true if a task was started.
    @discardableResult
    private func startLocked(_ item: DownloadItem) -> Bool {
        let quality = item.qualityOverride ?? options.defaultQuality
        guard let url = resolveDownloadURL(item.track, quality) else {
            failLocked(itemId: item.id, error: DownloadError(type: .notFound, message: "No download URL available"))
            return false
        }

        let task = urlSession.downloadTask(with: url)
        task.taskDescription = item.id
        activeDownloads[item.id] = task

        _currentState = _currentState.updating(itemId: item.id) {
            $0.status = .downloading
            $0.preparationStage = "downloading"
            $0.taskIdentifier = task.taskIdentifier
        }
        progressTracker.reset(itemId: item.id)
        notifyStateChanged()
        task.resume()
        writeDebugLog("[DownloadManager] Started \(item.track.displayName) (task \(task.taskIdentifier))")
        return true
    }

    /// Cancel any running task for the item and drop its bookkeeping.
    private func forgetLocked(itemId: String) {
        if let task = activeDownloads.removeValue(forKey: itemId) { task.cancel() }
        retryNotBefore[itemId] = nil
        lastProgressUpdate[itemId] = nil
        progressTracker.reset(itemId: itemId)
    }

    private func failLocked(itemId: String, error: DownloadError) {
        activeDownloads.removeValue(forKey: itemId)
        lastProgressUpdate[itemId] = nil

        let attempts = retryAttempts[itemId, default: 0]
        if error.isRetryable && attempts < maxRetryAttempts {
            retryAttempts[itemId] = attempts + 1
            retryNotBefore[itemId] = Date().addingTimeInterval(retryDelay)
            _currentState = _currentState.updating(itemId: itemId) { Self.resetToQueued(&$0) }
            writeDebugLog("[DownloadManager] Retrying \(itemId) after \(error.type.rawValue)")
        } else {
            _currentState = _currentState.updating(itemId: itemId) {
                $0.status = .failed
                $0.error = error.message
                $0.errorType = error.type
                $0.progress = 0
                $0.speedMBps = 0
                $0.taskIdentifier = nil
            }
            writeDebugLog("[DownloadManager] Failed \(itemId): \(error.type.rawValue) \(error.message)")
            notifyObservers { $0.downloadManager(self, didFailItem: itemId, error: error) }
        }

        scheduleQueuePersistenceLocked()
        notifyStateChanged()
        processQueueLocked()
    }

    private static func resetToQueued(_ item: inout DownloadItem) {
        item.status = .queued
        item.progress = 0
        item.speedMBps = 0
        item.bytesReceived = 0
        item.bytesTotal = 0
        item.taskIdentifier = nil
        item.preparationStage = ""
    }

    // MARK: - Persistence

    private func scheduleQueuePersistenceLocked() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistQueueLocked() }
        persistWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + persistenceDelay, execute: work)
    }

    private func persistQueueLocked() {
        persistence.saveQueue(items: _currentState.persistableItems)
    }

    private func restoreQueue() {
        stateQueue.async {
            let items = self.persistence.loadQueue().map { item -> DownloadItem in
                var copy = item
                if copy.status.isActive { Self.resetToQueued(&copy) }
                return copy
            }
            guard !items.isEmpty else { return }

            self._currentState = DownloadQueueState(items: items, isPaused: false)
            self.notifyStateChanged()
            self.stateQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.options.enabled else { return }
                self.processQueueLocked()
            }
        }
    }

    // MARK: - Notifications

    private func notifyStateChanged() {
        let snapshot = _currentState
        notifyObservers { $0.downloadManager(self, didUpdateState: snapshot) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .downloadQueueStateDidChange,
                object: self,
                userInfo: [DownloadManagerNotificationKeys.state: snapshot])
        }
    }

    private func notifyObservers(_ call: @escaping (DownloadManagerObserver) -> Void) {
        observersLock.lock()
        let current = observers.allObjects.compactMap { $0 as? DownloadManagerObserver }
        observersLock.unlock()
        guard !current.isEmpty else { return }
        DispatchQueue.main.async { current.forEach(call) }
    }

    // MARK: - Lifecycle

    @objc private func appDidEnterBackground() {
        stateQueue.async {
            self.persistWorkItem?.cancel()
            self.persistQueueLocked()
        }
    }

    // MARK: - Destination

    private func resolveDownloadDirectory() -> URL {
        if let bookmark = options.downloadLocationBookmark {
            var isStale = false
            // iOS has no `.withSecurityScope`; bookmarks from the document picker carry scope implicitly.
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return filePathResolver.defaultDownloadDirectory
    }

    private func finalizeLocked(itemId: String, stagedFile: URL) {
        guard let item = _currentState.item(withId: itemId) else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }

        _currentState = _currentState.updating(itemId: itemId) {
            $0.status = .finalizing
            $0.progress = 0.95
            $0.preparationStage = "moving file"
        }
        notifyStateChanged()

        let baseDirectory = resolveDownloadDirectory()
        let scoped = baseDirectory.startAccessingSecurityScopedResource()
        defer { if scoped { baseDirectory.stopAccessingSecurityScopedResource() } }

        let destination = filePathResolver.constructFilePath(for: item, options: options, baseDirectory: baseDirectory)

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: stagedFile, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: stagedFile)
            failLocked(itemId: itemId, error: DownloadError(
                type: .permission, message: "Failed to save file: \(error.localizedDescription)", underlyingError: error))
            return
        }

        activeDownloads.removeValue(forKey: itemId)
        retryAttempts[itemId] = nil
        _currentState = _currentState.updating(itemId: itemId) {
            $0.status = .completed
            $0.progress = 1.0
            $0.speedMBps = 0
            $0.filePath = destination.path
            $0.taskIdentifier = nil
        }
        persistence.addToHistory(item: item, filePath: destination.path)
        scheduleQueuePersistenceLocked()
        notifyStateChanged()
        notifyObservers { $0.downloadManager(self, didCompleteItem: itemId, filePath: destination.path) }
        processQueueLocked()
    }

    // MARK: - Error mapping

    fileprivate static func categorize(_ error: Error) -> DownloadErrorType {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            if nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileWriteOutOfSpaceError) {
                return .permission
            }
            return .unknown
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed:
            return .network
        case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable, NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return .notFound
        default:
            return .unknown
        }
    }

    fileprivate static func categorize(httpStatus: Int) -> DownloadErrorType {
        switch httpStatus {
        case 404, 410: return .notFound
        case 429: return .rateLimit
        case 401, 403: return .verificationRequired
        case 500...599: return .network
        default: return .unknown
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemId = downloadTask.taskDescription else { return }

        // `location` is deleted as soon as this method returns, so it has to be moved synchronously.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        var staged: URL?
        var stagingError: Error?

        // A link to a web page (or an error page served with 200) is not audio; don't save it as one.
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""
        let notAudio = mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml"

        if (200..<300).contains(status) && !notAudio {
            let target = DownloadManager.stagingDirectory.appendingPathComponent("\(itemId).part")
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                staged = target
            } catch {
                stagingError = error
            }
        }

        let taskId = downloadTask.taskIdentifier
        stateQueue.async {
            // Ignore callbacks from tasks we no longer track (cancelled, or left over from a previous launch).
            guard self.activeDownloads[itemId]?.taskIdentifier == taskId else {
                if let staged = staged { try? FileManager.default.removeItem(at: staged) }
                return
            }

            if let staged = staged {
                self.finalizeLocked(itemId: itemId, stagedFile: staged)
            } else if let stagingError = stagingError {
                self.failLocked(itemId: itemId, error: DownloadError(
                    type: .permission, message: stagingError.localizedDescription, underlyingError: stagingError))
            } else if notAudio && (200..<300).contains(status) {
                self.failLocked(itemId: itemId, error: DownloadError(
                    type: .notFound, message: "The link is not an audio file (\(mime))"))
            } else {
                self.failLocked(itemId: itemId, error: DownloadError(
                    type: DownloadManager.categorize(httpStatus: status), message: "HTTP \(status)"))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let itemId = downloadTask.taskDescription else { return }
        let taskId = downloadTask.taskIdentifier

        stateQueue.async {
            guard self.activeDownloads[itemId]?.taskIdentifier == taskId else { return }

            let now = Date()
            if let last = self.lastProgressUpdate[itemId], now.timeIntervalSince(last) < self.progressUpdateInterval {
                return
            }
            self.lastProgressUpdate[itemId] = now

            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
            let fraction = total > 0 ? min(0.94, Double(totalBytesWritten) / Double(total)) : 0
            let speed = self.progressTracker.record(itemId: itemId, bytesReceived: totalBytesWritten)
            let remaining = self.progressTracker.estimateTimeRemaining(
                itemId: itemId, bytesReceived: totalBytesWritten, bytesTotal: total)

            self._currentState = self._currentState.updating(itemId: itemId) {
                $0.progress = fraction
                $0.bytesReceived = totalBytesWritten
                $0.bytesTotal = total
                $0.speedMBps = speed
            }

            let info = DownloadProgress(
                itemId: itemId, bytesReceived: totalBytesWritten, bytesTotal: total,
                progress: fraction, speedMBps: speed, timeRemaining: remaining)
            self.notifyObservers { $0.downloadManager(self, didUpdateProgress: itemId, progress: info) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo.
        guard let error = error, let itemId = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }

        let taskId = task.taskIdentifier
        stateQueue.async {
            guard self.activeDownloads[itemId]?.taskIdentifier == taskId else { return }
            self.failLocked(itemId: itemId, error: DownloadError(
                type: DownloadManager.categorize(error), message: error.localizedDescription, underlyingError: error))
        }
    }
}

// MARK: - Progress tracker

/// Rolling-average speed estimator. Internally synchronized.
private final class DownloadProgressTracker {
    private struct Sample {
        var lastBytes: Int64 = 0
        var lastUpdate = Date()
        var speeds: [Double] = []
    }

    private let maxSamples = 10
    private let lock = NSLock()
    private var samples: [String: Sample] = [:]

    func reset(itemId: String) {
        lock.lock(); defer { lock.unlock() }
        samples[itemId] = nil
    }

    /// Records a byte count and returns the smoothed speed in MB/s.
    func record(itemId: String, bytesReceived: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        var sample = samples[itemId] ?? Sample()
        let now = Date()
        let elapsed = now.timeIntervalSince(sample.lastUpdate)
        if elapsed > 0 {
            let delta = max(0, bytesReceived - sample.lastBytes)
            sample.speeds.append(Double(delta) / elapsed / 1_048_576)
            if sample.speeds.count > maxSamples { sample.speeds.removeFirst() }
            sample.lastBytes = bytesReceived
            sample.lastUpdate = now
        }
        samples[itemId] = sample
        return sample.speeds.isEmpty ? 0 : sample.speeds.reduce(0, +) / Double(sample.speeds.count)
    }

    func estimateTimeRemaining(itemId: String, bytesReceived: Int64, bytesTotal: Int64) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let sample = samples[itemId], !sample.speeds.isEmpty, bytesTotal > bytesReceived else { return nil }
        let avg = sample.speeds.reduce(0, +) / Double(sample.speeds.count)
        guard avg > 0 else { return nil }
        return Double(bytesTotal - bytesReceived) / (avg * 1_048_576)
    }
}
