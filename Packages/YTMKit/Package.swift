// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "YTMKit",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [
        .library(name: "YTMCore", targets: ["YTMCore"]),
        .library(name: "YTMAudio", targets: ["YTMAudio"]),
        .library(name: "YTMPlayback", targets: ["YTMPlayback"]),
    ],
    targets: [
        // Models, YouTube Music's InnerTube API, streams, persistence,
        // Last.fm and artwork. Foundation and Apple frameworks only.
        .target(name: "YTMCore", swiftSettings: strict),
        // The streaming AAC decoder and the AVAudioEngine graph: gapless,
        // crossfade, equaliser, normalisation. Knows nothing of YouTube.
        .target(name: "YTMAudio", swiftSettings: strict),
        // The queue and the player that ties the API to the audio engine.
        .target(name: "YTMPlayback", dependencies: ["YTMCore", "YTMAudio"], swiftSettings: strict),
        // A macOS command line check that talks to YouTube for real.
        .executableTarget(name: "ytmcheck", dependencies: ["YTMCore", "YTMAudio"], swiftSettings: strict),
        .testTarget(name: "YTMCoreTests", dependencies: ["YTMCore"], swiftSettings: strict),
        .testTarget(name: "YTMAudioTests", dependencies: ["YTMAudio"], swiftSettings: strict),
        .testTarget(name: "YTMPlaybackTests", dependencies: ["YTMPlayback"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
