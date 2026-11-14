import Foundation

extension YTMusic {
    /// The signed-in account, as YouTube Music's account menu shows it; nil
    /// when signed out, or when YouTube no longer takes the session, which
    /// the app treats as ytm-native's `sign_in_expired`.
    ///
    /// The picture comes from YouTube's guide, as ytm-native's
    /// `account_photo`: the menu has been seen to keep serving the one
    /// before a change.
    @concurrent
    public func account() async throws -> Account? {
        guard await auth.isSignedIn else { return nil }
        async let guide = try? innerTube.post("guide", client: .web)
        let menu = try await innerTube.post("account/account_menu")
        return Account(menu: menu, guidePhoto: Account.photo(await guide?["userProfile", "accountPhoto", "thumbnails"] ?? .missing))
    }
}

extension Account {
    /// The active account of an `account_menu` reply, or nil when the menu
    /// is a signed-out one.
    init?(menu: JSON, guidePhoto: String?) {
        let header = menu["actions"][0]["openPopupAction", "popup", "multiPageMenuRenderer", "header", "activeAccountHeaderRenderer"]
        guard let name = header["accountName"].text, !name.isEmpty else { return nil }
        self.init(
            name: name,
            handle: header["channelHandle"].text.flatMap { $0.isEmpty ? nil : $0 },
            photo: guidePhoto ?? Self.photo(header["accountPhoto", "thumbnails"])
        )
    }

    /// The largest of the pictures, as a JPEG: an animated picture otherwise
    /// comes as a GIF, which artwork isn't decoded from.
    static func photo(_ thumbnails: JSON) -> String? {
        let largest = thumbnails.array.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        guard let url = largest?["url"].string else { return nil }
        return url.contains("=") && !url.hasSuffix("-rj") ? url + "-rj" : url
    }
}
