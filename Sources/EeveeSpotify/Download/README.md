# Download Manager

A background download queue for the tweak. Its design borrows from SpotiFLAC-Mobile's queue
(FIFO queue, 1-3 concurrent downloads, debounced persistence, categorized errors, one retry).

## What it downloads

Plain audio files only. It does not download Spotify's own streams (those are encrypted).

- **Direct links:** paste an http(s) link to an audio file.
- **Podcasts:** search Apple's public iTunes Search API for a show (or paste its RSS link), then
  download episodes from the `<enclosure>` URLs in the show's RSS feed.

## Offline Playback

Downloaded tracks are automatically registered for offline playback. Users can:
- Browse all downloaded tracks in Settings → Advanced → "My Downloaded Music"
- Search downloaded tracks by title, artist, or album
- Play offline tracks directly (uses AVAudioPlayer)
- See storage used by offline tracks
- Delete individual tracks or all downloads at once

Downloaded tracks will eventually be integrated into:
- Spotify's Now Playing screen (with "Available Offline" badge)
- Playlist views (marking tracks as downloaded)
- Search results (prioritizing offline versions when available)

## Status

- Core and sources layer typechecked on macOS with stubs. The SwiftUI screens are only compiled by
  the CI build; nothing has been run on a device yet.
- Disabled by default. Enable it in Settings → Downloads (experimental), then restart.
- There is no download button inside Spotify's own screens.
- Responses that are text/JSON/XML are rejected instead of being saved as audio.

## Files

- `Core/DownloadManager.swift`: singleton queue. All mutable state lives on one serial queue.
- `Core/DownloadManagerProtocol.swift`: protocol and observer API.
- `Models/`: `DownloadItem`, `DownloadQueueState` (immutable snapshot), `DownloadOptions`.
- `Sources/DownloadSources.swift`: URL validation, iTunes search, RSS parser.
- `Storage/DownloadPersistence.swift`: `queue.json` / `history.json` in Application Support.
- `Storage/FilePathResolver.swift`: destination folder and filename.
- `Offline/OfflineTrackDatabase.swift`: persistent index of downloaded tracks.
- `Offline/OfflinePlaybackManager.swift`: playback and playback event observer API.
- `Offline/OfflineDownloadObserver.swift`: bridges download completions to offline registration.
- `Offline/OfflineLibraryView.swift`: SwiftUI UI for browsing and playing offline tracks.
- `DownloadManagerHooks.x.swift`: activation helper and launch-time flags.
- UI: `Settings/Sections/Downloads/Views/EeveeDownloadsSettingsView.swift`.

## Behaviour

- Persisted: `queued` and `failed` items. In-flight items return to `queued` on relaunch.
- Background session id is fixed (`com.eevee.spotify.downloads`).
- Files are staged in `Application Support/EeveeSpotify/Downloads/staging`, then moved to
  `Documents/EeveeSpotify Downloads/` (or the bookmarked folder). Use the share button on a
  finished item to export it.
- "Enabled" and "Wi-Fi only" are read at launch, so changing them needs a restart.
