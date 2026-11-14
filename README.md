# YT Music for iOS

A native SwiftUI port of [ytm-native](https://github.com/Visxoz/ytm-native), the Windows YouTube Music client, for
iPhone. Same features, look and behaviour, built on Apple frameworks only, with no third-party code.

- **Audio:** Opus and AAC decoded natively (AudioToolbox, AVAudioEngine).
  - 256 kbps Premium streams, solved with JavaScriptCore.
  - Gapless playback and a 6-second crossfade.
  - A six-band equaliser, volume normalisation, and a disk cache.
- **Music:**
  - Home, Explore, moods and genres, charts, new releases.
  - Search with suggestions and recent searches.
  - Albums, artists with their full discography, playlists, Library and History.
- **Playback:**
  - Radio, autoplay, Smart Shuffle and repeat.
  - A queue you drag into order and save as a playlist.
  - Synced lyrics you tap to jump to.
  - Lock-screen controls.
  - Reopens on the song you left, at the second you left it.
- **Account:** Google sign-in, likes, playlists, YouTube history and Last.fm scrobbling.
- **Looks:** ytm-native's dark, light and pure black looks, its seven accents or one taken from the artwork, and its
  own icons.

## Layout

| Path | What it holds |
| --- | --- |
| `App/` | The SwiftUI app. The Xcode project syncs this folder. |
| `Packages/YTMKit/Sources/YTMCore` | Models, the InnerTube API, page parsing, streams and Premium, persistence, Last.fm, artwork |
| `Packages/YTMKit/Sources/YTMAudio` | Streaming download, WebM/MP4 demuxers, the decoder and the AVAudioEngine graph |
| `Packages/YTMKit/Sources/YTMPlayback` | The queue, the player controller, Now Playing, the audio session, Smart Shuffle, scrobbling |
| `Packages/YTMKit/Sources/ytmcheck` | A macOS tool that checks every page, stream and decode path against live YouTube |

## Building

Requires Xcode 27.2 and iOS 27.2.

```sh
cd Packages/YTMKit && swift test && swift run ytmcheck all      # unit tests, then live checks
scripts/build-ipa.sh                                            # unsigned build/YTMusic.ipa
```

Install `build/YTMusic.ipa` with SideStore, which signs it with your own Apple ID.

## Licence

GPL-3.0, as ytm-native.
