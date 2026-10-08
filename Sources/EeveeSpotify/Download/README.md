# Download Manager

A background download queue for the tweak. Its design borrows from SpotiFLAC-Mobile's queue
(FIFO queue, 1-3 concurrent downloads, debounced persistence, categorized errors, one retry).

## Status

- Compiles (typechecked with stubs for Orion/UIKit). Not yet run on a device.
- Disabled by default: `UserDefaults.downloadOptions.enabled` is `false`.
- There is no UI yet. Nothing calls `addToQueue` from inside Spotify.
- `DownloadManager.resolveDownloadURL` only returns `SpotifyTrack.previewURL`
  (a ~30s clip). Replace it with a real source to download full tracks.

## Files

- `Core/DownloadManager.swift`: singleton queue. All mutable state lives on one serial queue.
- `Core/DownloadManagerProtocol.swift`: protocol and observer API.
- `Models/`: `DownloadItem`, `DownloadQueueState` (immutable snapshot), `DownloadOptions`.
- `Storage/DownloadPersistence.swift`: `queue.json` / `history.json` in Application Support.
- `Storage/FilePathResolver.swift`: destination folder and filename.
- `DownloadManagerHooks.x.swift`: `DownloadManagerGroup` and activation helper.

## Behaviour

- Persisted: `queued` and `failed` items. In-flight items return to `queued` on relaunch.
- Background session id is fixed (`com.eevee.spotify.downloads`).
- Files are staged in `Application Support/EeveeSpotify/Downloads/staging`, then moved to
  `Documents/EeveeSpotify Downloads/` (or the bookmarked folder).

## Trying it

```swift
var o = UserDefaults.downloadOptions
o.enabled = true
UserDefaults.downloadOptions = o

let track = SpotifyTrack(id: "t1", isrc: nil, trackName: "Test", artistName: "Artist",
                         albumName: "Album", durationMs: 30000,
                         previewURL: "https://example.com/sample.mp3")
DownloadManager.shared.addToQueue(track: track, quality: nil)
```
