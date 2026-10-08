import SwiftUI
import UIKit

// MARK: - Main page

struct EeveeDownloadsSettingsView: View {
    @State private var enabled = UserDefaults.downloadOptions.enabled
    @State private var wifiOnly = UserDefaults.downloadOptions.wifiOnly

    var body: some View {
        List {
            Section(footer: Text("download_manager_footer".localized)) {
                Toggle("download_manager_toggle".localized, isOn: $enabled)
            }

            Section(footer: Text("dl_wifi_only_footer".localized)) {
                Toggle("dl_wifi_only".localized, isOn: $wifiOnly)
            }

            RestartSection(visible: enabled != DownloadFeature.launchEnabled || wifiOnly != DownloadFeature.launchWifiOnly)

            if DownloadFeature.launchEnabled {
                DownloadAddSection()

                Section {
                    SettingsLink(
                        title: "dl_podcasts".localized,
                        subtitle: "dl_podcasts_subtitle".localized,
                        icon: "mic.fill",
                        color: .purple
                    ) { PodcastBrowserView() }
                }

                DownloadQueueSection()
            } else {
                Section(footer: Text("dl_enable_hint".localized)) { EmptyView() }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onChange(of: enabled) { newValue in
            var options = UserDefaults.downloadOptions
            options.enabled = newValue
            UserDefaults.downloadOptions = options
        }
        .onChange(of: wifiOnly) { newValue in
            var options = UserDefaults.downloadOptions
            options.wifiOnly = newValue
            UserDefaults.downloadOptions = options
        }
    }
}

// MARK: - Add by link

private struct DownloadAddSection: View {
    @State private var urlText = ""
    @State private var message: String?

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section(
            header: Text("dl_add_header".localized),
            footer: Text(message ?? "dl_add_footer".localized)
        ) {
            TextField("https://example.com/audio.mp3", text: $urlText)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            HStack {
                Button("dl_paste".localized) {
                    if let pasted = UIPasteboard.general.string { urlText = pasted }
                }
                Spacer()
                Button("dl_add".localized, action: add)
                    .disabled(trimmed.isEmpty)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    private func add() {
        guard let url = DownloadSources.validatedURL(trimmed) else {
            message = "dl_err_invalid_url".localized
            return
        }
        let track = DownloadSources.makeTrack(directURL: url)
        if DownloadManager.shared.state.contains(trackId: track.id) {
            message = "dl_already".localized
            return
        }
        DownloadManager.shared.addToQueue(track: track, quality: nil)
        message = "dl_added".localized
        urlText = ""
    }
}

// MARK: - Queue

final class DownloadQueueViewModel: ObservableObject, DownloadManagerObserver {
    @Published private(set) var state: DownloadQueueState

    init() {
        state = DownloadManager.shared.state
        DownloadManager.shared.addObserver(self)
    }

    deinit {
        DownloadManager.shared.removeObserver(self)
    }

    // Observer callbacks arrive on the main queue.
    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateState state: DownloadQueueState) {
        self.state = state
    }

    func downloadManager(_ manager: DownloadManagerProtocol, didUpdateProgress itemId: String, progress: DownloadProgress) {
        // The manager has already folded the progress into its state; take a fresh snapshot.
        self.state = DownloadManager.shared.state
    }

    func togglePause() {
        if state.isPaused {
            DownloadManager.shared.resumeQueue()
        } else {
            DownloadManager.shared.pauseQueue()
        }
    }

    func retry(_ id: String) { DownloadManager.shared.retryDownload(itemId: id) }
    func remove(_ id: String) { DownloadManager.shared.cancelDownload(itemId: id) }
    func clearFinished() { DownloadManager.shared.clearCompleted() }

    func share(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            let view = WindowHelper.shared.rootViewController.view!
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        WindowHelper.shared.present(sheet)
    }
}

private struct DownloadQueueSection: View {
    @StateObject private var model = DownloadQueueViewModel()

    var body: some View {
        Section(
            header: Text("\("dl_queue_header".localized) (\(model.state.totalCount))"),
            footer: Text("dl_files_footer".localized)
        ) {
            if model.state.items.isEmpty {
                Text("dl_queue_empty".localized).foregroundColor(.secondary)
            } else {
                HStack {
                    Button((model.state.isPaused ? "dl_resume" : "dl_pause").localized) { model.togglePause() }
                    Spacer()
                    Button("dl_clear_finished".localized) { model.clearFinished() }
                        .disabled(model.state.completedCount + model.state.skippedCount == 0)
                }
                .buttonStyle(BorderlessButtonStyle())

                ForEach(model.state.items, id: \.id) { item in
                    DownloadRow(
                        item: item,
                        onShare: { if let path = item.filePath { model.share(path: path) } },
                        onRetry: { model.retry(item.id) },
                        onRemove: { model.remove(item.id) }
                    )
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let onShare: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    private var subtitle: String {
        switch item.status {
        case .queued:
            return "dl_status_queued".localized
        case .downloading:
            let percent = Int(item.progress * 100)
            if item.speedMBps > 0 {
                return String(format: "%d%% · %.1f MB/s", percent, item.speedMBps)
            }
            return "\(percent)%"
        case .finalizing:
            return "dl_status_saving".localized
        case .completed, .skipped:
            return "dl_status_done".localized
        case .failed:
            return item.error ?? "dl_status_failed".localized
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.track.trackName).lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(item.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                if item.status == .downloading {
                    ProgressView(value: min(max(item.progress, 0), 1))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 16) {
                if item.status == .completed {
                    Button(action: onShare) { Image(systemName: "square.and.arrow.up") }
                }
                if item.status == .failed {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                }
                Button(action: onRemove) { Image(systemName: "xmark.circle") }
                    .foregroundColor(.secondary)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Podcasts

struct PodcastBrowserView: View {
    @State private var query = ""
    @State private var shows: [PodcastShow] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searched = false

    var body: some View {
        List {
            Section(footer: Text("dl_podcast_footer".localized)) {
                TextField("dl_podcast_placeholder".localized, text: $query, onCommit: search)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("dl_search".localized, action: search)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if isLoading {
                Section { ProgressView() }
            }

            if let errorText {
                Section { Text(errorText).foregroundColor(.red) }
            } else if searched && !isLoading && shows.isEmpty {
                Section { Text("dl_no_results".localized).foregroundColor(.secondary) }
            }

            if !shows.isEmpty {
                Section {
                    ForEach(shows) { show in
                        SettingsLink(
                            title: show.name,
                            subtitle: show.author,
                            icon: "mic.fill",
                            color: .purple
                        ) { PodcastEpisodesView(feedURL: show.feedURL) }
                    }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !isLoading else { return }
        errorText = nil

        // A pasted RSS link goes straight to its episode list.
        if let feedURL = DownloadSources.validatedURL(term) {
            SettingsNavigator.push(PodcastEpisodesView(feedURL: feedURL), title: "dl_episodes_header".localized)
            return
        }

        isLoading = true
        PodcastDirectory.search(term: term) { result in
            isLoading = false
            searched = true
            switch result {
            case .success(let found): shows = found
            case .failure(let error): shows = []; errorText = error.localizedDescription
            }
        }
    }
}

struct PodcastEpisodesView: View {
    let feedURL: URL

    @State private var feed: PodcastFeed?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var addedIds: Set<String> = []
    @State private var didLoad = false

    var body: some View {
        List {
            if isLoading {
                Section { ProgressView() }
            }

            if let errorText {
                Section { Text(errorText).foregroundColor(.red) }
            }

            if let feed {
                Section(header: Text(feed.title), footer: Text("dl_files_footer".localized)) {
                    ForEach(feed.episodes) { episode in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(episode.title).lineLimit(2)
                                if let detail = detail(for: episode) {
                                    Text(detail).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Button {
                                add(episode, from: feed)
                            } label: {
                                Image(systemName: addedIds.contains(episode.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .disabled(addedIds.contains(episode.id))
                        }
                    }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            PodcastDirectory.loadFeed(url: feedURL) { result in
                isLoading = false
                switch result {
                case .success(let loaded): feed = loaded
                case .failure(let error): errorText = error.localizedDescription
                }
            }
        }
    }

    private func detail(for episode: PodcastEpisode) -> String? {
        var parts: [String] = []
        if episode.durationSeconds > 0 { parts.append(Self.format(duration: episode.durationSeconds)) }
        if let published = episode.published, !published.isEmpty {
            // RSS dates look like "Mon, 06 Oct 2025 10:00:00 +0000"; the first 16 characters are readable.
            parts.append(String(published.prefix(16)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func add(_ episode: PodcastEpisode, from feed: PodcastFeed) {
        let track = DownloadSources.makeTrack(episode: episode, show: feed)
        DownloadManager.shared.addToQueue(track: track, quality: nil)
        addedIds.insert(episode.id)
    }

    private static func format(duration seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
