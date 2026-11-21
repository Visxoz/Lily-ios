<div align="center">

<img src="docs/banner.svg" width="100%" alt="Lily: a native YouTube Music client for iPhone">

<br>

[![Release](https://img.shields.io/github/v/release/Visxoz/Lily-ios?style=flat&labelColor=18181b&color=d65db1&label=release)](https://github.com/Visxoz/Lily-ios/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Visxoz/Lily-ios/total?style=flat&labelColor=18181b&color=d65db1&label=downloads)](https://github.com/Visxoz/Lily-ios/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/Visxoz/Lily-ios/ci.yml?branch=main&style=flat&labelColor=18181b&label=CI)](https://github.com/Visxoz/Lily-ios/actions/workflows/ci.yml)
[![iOS 26](https://img.shields.io/badge/iOS-26-0a84ff?style=flat&labelColor=18181b&logo=apple&logoColor=white)](#install)
[![iPhone Duo](https://img.shields.io/badge/iPhone%20Duo-made%20for%20the%20fold-d65db1?style=flat&labelColor=18181b&logo=apple&logoColor=white)](#made-for-iphone-duo)
[![Swift 6.4](https://img.shields.io/badge/Swift-6.4-f05138?style=flat&labelColor=18181b&logo=swift&logoColor=white)](#under-the-hood)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0a84ff?style=flat&labelColor=18181b&logo=swift&logoColor=white)](#under-the-hood)
[![Licence](https://img.shields.io/github/license/Visxoz/Lily-ios?style=flat&labelColor=18181b&color=3f3f46&label=licence)](LICENSE)

<br>

<a href="https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://github.com/Visxoz/Lily-ios/releases/latest/download/source.json"><img src="docs/add-altstore.svg" height="44" alt="Add to AltStore"></a>
<a href="https://intradeus.github.io/http-protocol-redirector?r=sidestore://source?url=https://github.com/Visxoz/Lily-ios/releases/latest/download/source.json"><img src="docs/add-sidestore.svg" height="44" alt="Add to SideStore"></a>
<a href="https://intradeus.github.io/http-protocol-redirector?r=feather://source/https://github.com/Visxoz/Lily-ios/releases/latest/download/source.json"><img src="docs/add-feather.svg" height="44" alt="Add to Feather"></a>
<a href="https://github.com/Visxoz/Lily-ios/releases/latest"><img src="docs/get-github.svg" height="44" alt="Download from GitHub"></a>

<sub>Free, for iOS 26 and later · open this page on your iPhone and tap a store to add Lily, with updates as they come</sub>

<br>

<img src="docs/hero.jpg" width="100%" alt="Lily: an artist page with its banner, synced lyrics in the artwork's colours, and the queue">

<sub>Artist pages with their banner · lyrics that follow the song, in its artwork's colours · a queue you drag into order</sub>

</div>

<br>

<table>
<tr>
<td width="33%" valign="top">

### Sounds better
256 kbps Opus with Premium, gapless playback, a crossfade of your chosen length, volume levelling, a ten-band equaliser, and crossfeed, mono and balance for headphones.

</td>
<td width="33%" valign="top">

### Truly native
Swift and SwiftUI from top to bottom, on Apple's own audio engine. No web views, no wrappers, nothing but the app.

</td>
<td width="33%" valign="top">

### Looks the part
Pure black and orchid out of the box, or dark or light, in eight other accents including one that follows the song's artwork. Pages are tinted to match, and Now Playing takes on the artwork's colours.

</td>
</tr>
<tr>
<td width="33%" valign="top">

### All of YouTube Music
Radio, autoplay, Smart Shuffle, repeat, history and search with recent searches. Speed dial on Home, and artist pages with the whole discography. Songs, albums and playlists download to play offline.

</td>
<td width="33%" valign="top">

### Lyrics and queue
Swipe up from the artwork for synced lyrics you can tap to jump to, and a queue you drag into order, edit several songs at a time, and save as a playlist.

</td>
<td width="33%" valign="top">

### At home on iPhone
The lock screen, Control Center, the volume buttons and your AirPods, Last.fm, a Liquid Glass tab bar and icon, and [layouts of its own](#made-for-iphone-duo) on iPhone Duo. Reopens on the song you left, at the second you left it.

</td>
</tr>
</table>

## Make it yours

<table>
<tr>
<td width="25%"><img src="docs/home.jpg" alt="Home in the dark theme, tinted with the accent"></td>
<td width="25%"><img src="docs/home-light.jpg" alt="Home in the light theme"></td>
<td width="25%"><img src="docs/album-black.jpg" alt="Discovery's album page in the pure black theme"></td>
<td width="25%"><img src="docs/album.jpg" alt="An album page tinted from its cover"></td>
</tr>
<tr>
<td align="center"><b>Dark</b> · Home, tinted with your accent</td>
<td align="center"><b>Light</b> · for daytime</td>
<td align="center"><b>Black</b> · for OLED screens</td>
<td align="center"><b>Albums</b> · tinted from the cover</td>
</tr>
<tr>
<td width="25%"><img src="docs/explore.jpg" alt="Explore's moods and moments"></td>
<td width="25%"><img src="docs/search.jpg" alt="Search results with the top result"></td>
<td width="25%"><img src="docs/nowplaying.jpg" alt="Now Playing, coloured from the artwork"></td>
<td width="25%"><img src="docs/library.jpg" alt="Library, asking to sign in, with the Downloads button"></td>
</tr>
<tr>
<td align="center"><b>Explore</b> · moods, moments and more</td>
<td align="center"><b>Search</b> · with a top result</td>
<td align="center"><b>Now Playing</b> · in the artwork's colours</td>
<td align="center"><b>Library</b> · yours when signed in, with downloads</td>
</tr>
</table>

Lily starts in pure black with its own orchid. Pick another look and accent in **Settings ▸ Appearance**: Lily, Red, Orange, Green, Teal, Blue, Purple, Pink, or **From the artwork**.

## Sounds as good as YouTube gets

<table>
<tr>
<td width="62%"><img src="docs/quality.svg" alt="Audio quality: Low about 50 kbps, Normal about 130 kbps, High up to 256 kbps with Premium"></td>
<td width="38%"><img src="docs/equaliser.jpg" alt="The equaliser with the Bass boost preset"></td>
</tr>
</table>

| Feature | What it does |
| --- | --- |
| **Premium streams** | Signed in with Premium on High, songs play in YouTube's 256 kbps formats, and Now Playing says so. Music videos swap to their song versions to get them. |
| **Gapless** | The next song is lined up 15 seconds early and follows without a gap, and the screen changes the moment the sound does. |
| **Crossfade** | Fades each song into the next over 6 seconds, or a length you choose from 1 to 12, cutting the silence at the joins. An album played in order still runs straight on, and skipping never fades. |
| **Equaliser** | Ten bands from 31 Hz to 16 kHz, ±12 dB each, with presets: Flat, Bass boost, Treble boost, Vocal, Rock, Electronic and Acoustic. Boosting turns the rest down to leave headroom. |
| **Normalise volume** | Plays every track at a similar loudness, from YouTube's own measurement: loud ones turned down and quiet ones up, at Normal or a Quiet level 6 dB lower, with a limiter so nothing clips. |
| **No clicks, no drop-outs** | Pausing ramps the sound down, and seeks and skips fade in. Unplug your headphones and the music pauses rather than carrying on through the speaker; plug a pair in and it plays on through them. |
| **Rides out a lost connection** | A connection that drops is waited on for a minute. Gone longer, the song opens again where it stopped, a few times, then waits for you to press play, rather than skipping. |

## Take it offline

<table>
<tr>
<td width="62%" valign="top">

Tap the download button on an album or playlist, or **Download** in any song's menu, and it plays from the phone after that, online or not. Offline, the queue skips what isn't downloaded, and downloaded albums and playlists still open.

| Feature | What it does |
| --- | --- |
| **Smart downloads** | Keeps 25 to 200 songs downloaded, from what you play and more like it, picked afresh each day. |
| **Stays current** | Downloaded albums and playlists pick up YouTube's changes once a day. |
| **Wi-Fi only** | Downloads wait for Wi-Fi rather than use mobile data or a hotspot, unless you say otherwise. |
| **Download quality** | Set apart from streaming: Low, Normal or High, which is 256 kbps Opus with Premium. |

Find them behind the download button at the top of Library, and the settings in **Settings ▸ Downloads**.

</td>
<td width="38%"><img src="docs/downloads.jpg" alt="The Downloads page, with 27 songs on the phone"></td>
</tr>
</table>

## Made for iPhone Duo

<img src="docs/duo.svg" width="100%" alt="Made for iPhone Duo: the player beside the queue, albums in two panes, and a stand mode, each in its own layout">

Folded, iPhone Duo's outer display is a phone like any other, and Lily is the app you know. Open it up and each screen is laid out again for the bigger display and its two halves.

<table>
<tr>
<td width="40%"><img src="docs/duo-player.jpg" alt="Now Playing open flat: the player on the left half and the queue on the right"></td>
<td width="40%"><img src="docs/duo-album.jpg" alt="Discovery's album page open flat: the cover and Play on the left half, the tracks on the right"></td>
<td width="20%"><img src="docs/duo-stand.jpg" alt="Stood half open like a laptop: the artwork on the upright half, the controls on the flat half"></td>
</tr>
<tr>
<td align="center"><b>Open</b> · the player beside the queue or lyrics</td>
<td align="center"><b>Albums</b> · the header beside the tracks</td>
<td align="center"><b>Stood</b> · artwork up, controls down</td>
</tr>
</table>

| Feature | What it does |
| --- | --- |
| **Player beside the panel** | Open it wide and Now Playing puts the queue or lyrics beside the player, one on each half, with their buttons at the foot where your thumb reaches. |
| **Two-pane pages** | Albums and playlists put the cover, title and Play button on one half and the tracks on the other. Pages fit more columns, and their colour runs right under the tabs. |
| **Stand mode** | Half open it like a laptop and the artwork or lyrics face you from the upright half, with every control on the flat half. |
| **Fold to scrub** | Half open it like a book, rest it a moment, then fold it to skip back or open it to skip ahead, 10 seconds a step. Turn it on in **Settings ▸ Playback**. |

The open layouts need iOS 27.1 or later.

## Install

On your iPhone, tap **Add to AltStore**, **Add to SideStore** or **Add to Feather** at the top of this page. Your store opens and adds Lily's source; install Lily from it, and new versions show up there as updates.

If a button does nothing, add the source by hand: copy this link, and paste it in your store's **Sources** tab.

```
https://github.com/Visxoz/Lily-ios/releases/latest/download/source.json
```

Or grab `Lily.ipa` from the [latest release](https://github.com/Visxoz/Lily-ios/releases/latest) and open it with any of them. Lily works signed out straight away.

Every release is built by [GitHub Actions](.github/workflows/release.yml) from main, never on anyone's computer. To check a download came from there, run `gh attestation verify Lily.ipa --repo Visxoz/Lily-ios --signer-workflow Visxoz/Lily-ios/.github/workflows/release.yml`.

> [!NOTE]
> Apps signed with a free Apple ID last seven days. AltStore and SideStore refresh them in the background; if they haven't, open the store and tap **Refresh All**.

## Getting around

| Do | To |
| --- | --- |
| Tap the mini player | Open Now Playing |
| Swipe up on Now Playing, or tap **Up next** or **Lyrics** | Show the queue or the lyrics under the player |
| Swipe down | Go back to the artwork, then close Now Playing |
| Tap the song or artist in Now Playing | Go to its album or artist |
| Tap a lyric line | Jump to it |
| Drag a song in the queue | Move it |
| Swipe a song in the queue | Remove it |
| **Select** in the queue | Pick several songs, then play them next or remove them |
| Press and hold a song | Play it next, add it to the queue, start a radio, download it, like it, save it to a playlist or remove it from your own playlist, go to its artist or album, or copy its link |
| Press and hold a card | Play it, start a radio, download an album or playlist, or copy its link. In Library, pin a playlist to the top of its playlists |
| Tap **More** beside an album's, playlist's or artist's buttons | Copy its link, or rename your own playlist, change who can see it, or delete it |
| Tap the shuffle button | Cycle Off, Shuffle and **Smart Shuffle**, which mixes in recommendations. Shuffling keeps an artist's or an album's songs apart |
| On iPhone Duo, half open with **Fold to scrub** on, fold or open it | Skip back or ahead 10 seconds a step |

## Your account

Tap the account button, then **Settings ▸ Account ▸ Sign in**, and sign in on Google's own page. The page closes by itself once you're in. Your playlists, albums and artists appear in Library, where a playlist's menu can pin it to the top, Home becomes your own feed, and what you play here counts towards your YouTube Music history and recommendations, with the time you listened, as on the web, unless you turn off **YouTube history** in **Settings ▸ Account**.

Your own playlists can be edited from their page: press and hold a song, then drag it into a new order, remove songs from their menu, or rename it, change who can see it, or delete it from **More** in its header (making one public or unlisted needs a YouTube channel on the account). Any other album or playlist can be saved to your library from its header, and artists subscribed to. Every song, album, playlist and artist has **Copy link** in its menu.

The sign-in is kept in the iPhone's Keychain, for this device only. Google's page is shown in a private web view that's thrown away as soon as you're signed in. Lily renews the sign-in every 10 minutes, as an open YouTube tab does, and should YouTube sign you out, it says so.

<details>
<summary><b>Connecting Last.fm</b></summary>
<br>

Tap **Settings ▸ Account ▸ Last.fm ▸ Connect**, then allow access on Last.fm's page. Plays scrobble from then on, including ones made while you were offline.

Building it yourself? Last.fm needs an [API account](https://www.last.fm/api/account/create). Put its key and secret in `Config/Secrets.xcconfig` as `LASTFM_API_KEY = …` and `LASTFM_API_SECRET = …`; without them, Settings says Last.fm is unavailable.

</details>

> [!WARNING]
> Lily is an unofficial client. It uses YouTube's undocumented API, which is against YouTube's terms of service. Google could ask you to confirm you're not a bot or sign the session out, and could in principle restrict the account. A separate account is the safest choice.

## Under the hood

Everything you see and hear is native code, written in Swift. A web view only appears while you sign in, to show Google's page.

```mermaid
flowchart LR
    yt(["YouTube Music"]) -->|InnerTube| pages["Pages, search,<br/>radio, lyrics"]
    yt -->|player endpoint| url["Stream URL<br/>visionOS, then Android VR, then iOS"]
    premium["Premium<br/>web player's code, cut down natively,<br/>run in a throwaway JavaScriptCore"] -.-> url
    url --> dl["Download<br/>1 MB ranges, to a disk cache"]
    dl --> dec["Demux and decode<br/>WebM and MP4, Opus and AAC"]
    dec --> fx["Levelling, EQ,<br/>gapless, crossfade"]
    fx --> out(["AVAudioEngine"])
    pages --> ui["SwiftUI"]
```

<details>
<summary><b>What it's built with</b></summary>
<br>

| Part | Built with |
| --- | --- |
| YouTube Music data | YouTube's InnerTube API, called directly (`YTMCore`) |
| Stream URLs | YouTube's player endpoint, called directly (`YTMCore/Streams`) |
| Premium URLs | A Swift tokenizer that cuts the player down, and JavaScriptCore |
| Demuxing | Its own WebM and MP4 readers (`YTMAudio`) |
| Opus and AAC | AudioToolbox |
| Audio output | AVAudioEngine, with its own in-process audio unit for the equaliser, crossfeed, balance and limiter |
| Interface | SwiftUI, with Lily's own icons drawn as shapes, and Now Playing's mesh gradient taken from the artwork |
| Networking | URLSession over HTTP/2 |
| Artwork | ImageIO, decoded at the size it's shown |
| Lock screen, AirPods and volume | MediaPlayer |
| Offline and Wi-Fi only | The Network framework |
| Google sign-in | WebKit, only while signing in |

Most YouTube clients get stream URLs that YouTube's player JavaScript has to unscramble. The visionOS client gets plain ones, so the app asks as that client and needs no JavaScript engine, falling back to Android VR and iOS if YouTube changes it. A client whose streams are cut off partway is asked last from then on, and the song carries on from the same byte with another client's copy. With Premium, the app unscrambles the web player's URLs itself, in a short-lived JavaScriptCore context with a cut-down copy of the player.

Apple's AudioToolbox decodes Opus, but can't read the WebM files YouTube keeps it in, so the app reads them itself and hands AudioToolbox the packets as they download.

The app talks only to YouTube's hosts, plus Last.fm if you connect it, each checked against an allowlist. It follows the proxy set in iOS, or an HTTP or SOCKS5 proxy of your own entered in **Settings ▸ Account ▸ Proxy**, kept in the Keychain and used from the app's next start.

</details>

<details>
<summary><b>Building from source</b></summary>
<br>

You need Xcode 27.2. There are no dependencies to fetch.

```sh
cd Packages/YTMKit
swift test               # the unit tests
swift run ytmcheck all   # checks every page, stream and decode path against live YouTube
cd ../..
scripts/build-ipa.sh     # build/Lily.ipa, unsigned
scripts/lint.sh          # the lint CI runs
```

Or open `Lily.xcodeproj` and run it on the iPhone simulator.

| Path | What it holds |
| --- | --- |
| `App/` | The SwiftUI app |
| `Packages/YTMKit/Sources/YTMCore` | Models, the InnerTube API, page parsing, streams and Premium, persistence, Last.fm, artwork |
| `Packages/YTMKit/Sources/YTMAudio` | Streaming download, saving downloads, the WebM and MP4 readers, decoding and the audio engine |
| `Packages/YTMKit/Sources/YTMPlayback` | The queue, the player, Now Playing, Smart Shuffle, downloads, scrobbling |
| `Packages/YTMKit/Sources/ytmcheck` | A macOS tool that checks the app's YouTube paths are still working |

</details>

## Licence

Lily for iPhone is a port of [Lily for Windows](https://github.com/Visxoz/lily) and, like it, free software under the [GNU General Public License, version 3](LICENSE).

<br>

<div align="center">
<sub>Not affiliated with, endorsed by or connected to YouTube or Google. YouTube Music is a trademark of Google LLC.</sub>
</div>
