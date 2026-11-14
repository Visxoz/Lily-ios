import Foundation

/// YouTube Music for the app: pages, what to play, streams and the library.
/// Stateless apart from caches, so one instance is shared. Each concern
/// lives in its own `YTMusic+….swift` beside this file.
public final class YTMusic: Sendable {
    public static let shared = YTMusic()

    public let auth: GoogleAuth
    let innerTube: InnerTube
    let store: FileStore

    public init(auth: GoogleAuth = .shared, store: FileStore = .shared) {
        self.auth = auth
        self.store = store
        innerTube = InnerTube(auth: auth, store: store)
    }
}
