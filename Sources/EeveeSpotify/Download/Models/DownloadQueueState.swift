import Foundation

/// Immutable download queue state container with pre-computed lookup tables
/// Inspired by SpotiFLAC's efficient state management pattern
struct DownloadQueueState {
    // MARK: - Data
    
    /// All download items (immutable snapshot)
    let items: [DownloadItem]
    
    /// Pre-computed lookup: trackId → item index
    let trackIdLookup: [String: Int]
    
    /// Pre-computed lookup: itemId → item index
    let itemIdLookup: [String: Int]
    
    /// Pre-computed lookup: taskIdentifier → item index
    let taskIdLookup: [Int: Int]
    
    // MARK: - Cached Counters
    
    /// Cached status counters for efficient access
    let queuedCount: Int
    let activeCount: Int
    let completedCount: Int
    let failedCount: Int
    let skippedCount: Int
    
    /// Queue paused flag
    let isPaused: Bool
    
    /// Last update timestamp
    let lastUpdate: Date
    
    // MARK: - Initialization
    
    init(items: [DownloadItem], isPaused: Bool = false) {
        self.items = items
        self.isPaused = isPaused
        self.lastUpdate = Date()
        
        // Build lookups and counters in a single pass
        var trackLookup: [String: Int] = [:]
        var itemLookup: [String: Int] = [:]
        var taskLookup: [Int: Int] = [:]
        var queued = 0, active = 0, completed = 0, failed = 0, skipped = 0
        
        for (index, item) in items.enumerated() {
            // Track ID lookup (may overwrite if multiple items for same track)
            trackLookup[item.track.id] = index
            
            // Item ID lookup (unique)
            itemLookup[item.id] = index
            
            // Task identifier lookup (if available)
            if let taskId = item.taskIdentifier {
                taskLookup[taskId] = index
            }
            
            // Count by status
            switch item.status {
            case .queued:
                queued += 1
            case .downloading, .finalizing:
                active += 1
            case .completed:
                completed += 1
            case .failed:
                failed += 1
            case .skipped:
                skipped += 1
            }
        }
        
        self.trackIdLookup = trackLookup
        self.itemIdLookup = itemLookup
        self.taskIdLookup = taskLookup
        self.queuedCount = queued
        self.activeCount = active
        self.completedCount = completed
        self.failedCount = failed
        self.skippedCount = skipped
    }
    
    // MARK: - Empty State
    
    static var empty: DownloadQueueState {
        return DownloadQueueState(items: [], isPaused: false)
    }
    
    // MARK: - Query Methods
    
    /// Check if track is already in queue
    func contains(trackId: String) -> Bool {
        return trackIdLookup[trackId] != nil
    }
    
    /// Get item by item ID
    func item(withId id: String) -> DownloadItem? {
        guard let index = itemIdLookup[id] else { return nil }
        return items[index]
    }
    
    /// Get item by track ID
    func item(withTrackId trackId: String) -> DownloadItem? {
        guard let index = trackIdLookup[trackId] else { return nil }
        return items[index]
    }
    
    /// Get item by task identifier
    func item(withTaskId taskId: Int) -> DownloadItem? {
        guard let index = taskIdLookup[taskId] else { return nil }
        return items[index]
    }
    
    /// Get all items with specific status
    func items(withStatus status: DownloadStatus) -> [DownloadItem] {
        return items.filter { $0.status == status }
    }
    
    /// Get next queued item (FIFO)
    var nextQueuedItem: DownloadItem? {
        return items.first { $0.status == .queued }
    }
    
    /// Get all active downloads
    var activeDownloads: [DownloadItem] {
        return items.filter { $0.status.isActive }
    }
    
    /// Total item count
    var totalCount: Int {
        return items.count
    }
    
    /// Check if queue has any active work
    var hasActiveWork: Bool {
        return activeCount > 0 || (!isPaused && queuedCount > 0)
    }
    
    // MARK: - State Mutations (Return New State)
    
    /// Add new item to queue
    func adding(_ item: DownloadItem) -> DownloadQueueState {
        var newItems = items
        newItems.append(item)
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Add multiple items to queue
    func adding(_ newItems: [DownloadItem]) -> DownloadQueueState {
        var combined = items
        combined.append(contentsOf: newItems)
        return DownloadQueueState(items: combined, isPaused: isPaused)
    }
    
    /// Update existing item
    func updating(itemId: String, transform: (inout DownloadItem) -> Void) -> DownloadQueueState {
        guard let index = itemIdLookup[itemId] else { return self }
        
        var newItems = items
        transform(&newItems[index])
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Update multiple items by ID
    func updatingMultiple(_ updates: [(String, (inout DownloadItem) -> Void)]) -> DownloadQueueState {
        var newItems = items
        
        for (itemId, transform) in updates {
            guard let index = itemIdLookup[itemId] else { continue }
            transform(&newItems[index])
        }
        
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Remove item by ID
    func removing(itemId: String) -> DownloadQueueState {
        let newItems = items.filter { $0.id != itemId }
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Remove all items matching predicate
    func removing(where predicate: (DownloadItem) -> Bool) -> DownloadQueueState {
        let newItems = items.filter { !predicate($0) }
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Clear completed and skipped items
    func clearingCompleted() -> DownloadQueueState {
        let newItems = items.filter { $0.status != .completed && $0.status != .skipped }
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Toggle pause state
    func toggling(pause: Bool) -> DownloadQueueState {
        return DownloadQueueState(items: items, isPaused: pause)
    }
    
    // MARK: - Batch Operations
    
    /// Update all items with status matching filter
    func updatingAll(
        matching filter: (DownloadItem) -> Bool,
        transform: (inout DownloadItem) -> Void
    ) -> DownloadQueueState {
        var newItems = items
        
        for (index, item) in newItems.enumerated() where filter(item) {
            transform(&newItems[index])
        }
        
        return DownloadQueueState(items: newItems, isPaused: isPaused)
    }
    
    /// Reset all active downloads to queued (for app restart recovery)
    func recoveringActiveDownloads() -> DownloadQueueState {
        return updatingAll(matching: { $0.status.isActive }) { item in
            item.status = .queued
            item.progress = 0.0
            item.speedMBps = 0.0
            item.bytesReceived = 0
            item.bytesTotal = 0
            item.taskIdentifier = nil
        }
    }
    
    // MARK: - Persistence Helpers
    
    /// Get only persistable items (queued, failed)
    var persistableItems: [DownloadItem] {
        return items.filter { $0.status.isPersistable }.map { $0.normalized() }
    }
    
    // MARK: - Description
    
    var summary: String {
        return """
        DownloadQueueState(
          total: \(totalCount),
          queued: \(queuedCount),
          active: \(activeCount),
          completed: \(completedCount),
          failed: \(failedCount),
          paused: \(isPaused)
        )
        """
    }
}
