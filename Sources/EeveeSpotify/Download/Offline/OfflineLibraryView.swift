import SwiftUI
import UIKit

// MARK: - Offline Library ViewModel

final class OfflineLibraryViewModel: NSObject, ObservableObject {
    @Published private(set) var tracks: [OfflineTrack] = []
    @Published private(set) var totalStorage: Int64 = 0
    @Published private(set) var isSearching = false
    @Published var searchQuery = ""
    
    private let offlineDB = OfflineTrackDatabase.shared
    
    override init() {
        super.init()
        refreshTracks()
    }
    
    func refreshTracks() {
        let allTracks = offlineDB.allOfflineTracks()
        DispatchQueue.main.async {
            self.tracks = allTracks
            self.totalStorage = self.offlineDB.totalStorageUsed()
        }
    }
    
    func search(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshTracks()
            return
        }
        isSearching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = self?.offlineDB.search(query: query) ?? []
            DispatchQueue.main.async {
                self?.tracks = results
                self?.isSearching = false
            }
        }
    }
    
    func removeTrack(_ trackId: String, deleteFile: Bool = true) {
        offlineDB.removeOfflineTrack(trackId: trackId, deleteFile: deleteFile)
        refreshTracks()
    }
    
    func deleteAll() {
        for track in offlineDB.allOfflineTracks() {
            offlineDB.removeOfflineTrack(trackId: track.trackId, deleteFile: true)
        }
        refreshTracks()
    }
}

// MARK: - Offline Library View

struct OfflineLibraryView: View {
    @StateObject private var model = OfflineLibraryViewModel()
    @State private var showDeleteConfirm = false
    
    var body: some View {
        List {
            Section(
                header: Text("dl_offline_header".localized),
                footer: Text(String(format: "dl_offline_storage".localized, formatBytes(model.totalStorage)))
            ) {
                if model.tracks.isEmpty {
                    Text("dl_offline_empty".localized).foregroundColor(.secondary)
                } else {
                    ForEach(model.tracks, id: \.trackId) { track in
                        OfflineTrackRow(track: track, onDelete: { model.removeTrack(track.trackId) })
                    }
                }
            }
            
            if !model.tracks.isEmpty {
                Section {
                    Button("dl_offline_delete_all".localized, role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
                .alert("dl_offline_delete_confirm_title".localized, isPresented: $showDeleteConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { model.deleteAll() }
                } message: {
                    Text("dl_offline_delete_confirm_msg".localized)
                }
            }
            
            SpacerView()
        }
        .searchable(text: $model.searchQuery, prompt: "dl_search".localized)
        .onChange(of: model.searchQuery) { query in
            if !query.isEmpty {
                model.search(query: query)
            } else {
                model.refreshTracks()
            }
        }
        .eeveeSettingsStyle()
        .onAppear { model.refreshTracks() }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Offline Track Row

private struct OfflineTrackRow: View {
    let track: OfflineTrack
    let onDelete: () -> Void
    
    @State private var showDeleteConfirm = false
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.trackName).lineLimit(1).fontWeight(.semibold)
                Text(track.artistName).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(formatDuration(track.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(formatBytes(track.fileSize))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if let lastPlayed = track.lastPlayedAt {
                        Text("Played: \(formatDate(lastPlayed))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer(minLength: 8)
            
            HStack(spacing: 12) {
                Button(action: { playTrack() }) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(BorderlessButtonStyle())
                
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
        .alert("Delete Download?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will delete the offline copy of \(track.trackName).")
        }
    }
    
    private func playTrack() {
        if OfflinePlaybackManager.shared.playOffline(trackId: track.trackId) {
            writeDebugLog("[OfflineUI] Playing: \(track.trackName)")
        } else {
            writeDebugLog("[OfflineUI] Failed to play: \(track.trackName)")
        }
    }
    
    private func formatDuration(_ ms: Int) -> String {
        let seconds = ms / 1000
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}
