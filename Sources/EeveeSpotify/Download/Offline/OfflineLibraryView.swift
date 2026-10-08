import SwiftUI
import UIKit

// MARK: - View model

final class OfflineLibraryViewModel: ObservableObject {
    @Published private(set) var tracks: [OfflineTrack] = []
    @Published private(set) var totalStorage: Int64 = 0
    @Published private(set) var playingTrackId: String?
    @Published var searchQuery = "" {
        didSet { refresh() }
    }
    @Published private(set) var errorText: String?

    private let database = OfflineTrackDatabase.shared
    private let player = OfflinePlaybackManager.shared
    private var observer: NSObjectProtocol?

    init() {
        playingTrackId = player.playingTrackId
        observer = NotificationCenter.default.addObserver(
            forName: .offlinePlaybackDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.playingTrackId = self?.player.playingTrackId
        }
        refresh()
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        tracks = database.search(query: searchQuery)
        totalStorage = database.totalStorageUsed()
    }

    func toggle(_ track: OfflineTrack) {
        switch player.toggle(trackId: track.trackId) {
        case .success:
            errorText = nil
        case .failure(.fileMissing), .failure(.notOffline):
            errorText = "dl_offline_missing".localized
            refresh()
        case .failure(.decodeFailed):
            errorText = "dl_offline_unplayable".localized
        }
    }

    func remove(_ track: OfflineTrack) {
        if player.playingTrackId == track.trackId { player.stop() }
        database.remove(trackId: track.trackId, deleteFile: true)
        refresh()
    }

    func removeAll() {
        player.stop()
        for track in database.allOfflineTracks() {
            database.remove(trackId: track.trackId, deleteFile: true)
        }
        refresh()
    }
}

// MARK: - Library screen

struct OfflineLibraryView: View {
    @StateObject private var model = OfflineLibraryViewModel()

    var body: some View {
        List {
            Section {
                TextField("dl_search".localized, text: $model.searchQuery)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            if let errorText = model.errorText {
                Section { Text(errorText).foregroundColor(.red) }
            }

            Section(
                header: Text("dl_offline_header".localized),
                footer: Text(String(
                    format: "dl_offline_storage".localized,
                    ByteCountFormatter.string(fromByteCount: model.totalStorage, countStyle: .file)))
            ) {
                if model.tracks.isEmpty {
                    Text("dl_offline_empty".localized).foregroundColor(.secondary)
                } else {
                    ForEach(model.tracks, id: \.trackId) { track in
                        OfflineTrackRow(
                            track: track,
                            isPlaying: model.playingTrackId == track.trackId,
                            onToggle: { model.toggle(track) },
                            onDelete: {
                                confirmDestructive(
                                    title: "dl_offline_delete_one".localized,
                                    message: track.trackName,
                                    confirm: "dl_offline_delete".localized
                                ) { model.remove(track) }
                            }
                        )
                    }
                }
            }

            if !model.tracks.isEmpty {
                Section {
                    Button {
                        confirmDestructive(
                            title: "dl_offline_delete_confirm_title".localized,
                            message: "dl_offline_delete_confirm_msg".localized,
                            confirm: "dl_offline_delete".localized
                        ) { model.removeAll() }
                    } label: {
                        Text("dl_offline_delete_all".localized).foregroundColor(.red)
                    }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear { model.refresh() }
    }
}

// MARK: - Row

private struct OfflineTrackRow: View {
    let track: OfflineTrack
    let isPlaying: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    private var detail: String {
        var parts: [String] = []
        if track.duration > 0 { parts.append(Self.format(durationMs: track.duration)) }
        parts.append(ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
        if track.playCount > 0 { parts.append(String(format: "dl_offline_plays".localized, track.playCount)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.trackName).lineLimit(1)
                Text(track.artistName).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                Text(detail).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 18) {
                Button(action: onToggle) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                }
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 2)
    }

    private static func format(durationMs: Int) -> String {
        let total = durationMs / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
