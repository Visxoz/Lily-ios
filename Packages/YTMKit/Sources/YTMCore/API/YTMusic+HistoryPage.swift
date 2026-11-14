import Foundation

// The account's own History page, as ytm-native's `api/pages.rs` shows it.
// Signed out, the app shows the songs played on the phone instead.

extension YTMusic {
    /// The account's YouTube Music history, newest first, so plays on other
    /// devices and the website show here too. Only the first page YouTube
    /// sends, as ytm-native.
    @concurrent
    func historyPage() async throws -> Page {
        try await requireSignIn("Sign in to see your YouTube Music history.")
        let tracks = Self.historyTracks(in: try await innerTube.browse("FEmusic_history", params: "oggECgIIAQ%3D%3D"))
        guard let section = Section.tracks("", tracks, mode: .section) else {
            throw YTMError(.notFound, "Songs you play will show up here.")
        }
        // No count: with only the first page, it wouldn't be the whole
        // history's.
        return Page(header: PageHeader(label: "Recently played", title: "History"), sections: [section])
    }

    /// The songs of every day's shelf (Today, Yesterday, …), in order.
    static func historyTracks(in response: JSON) -> [Track] {
        Renderers.sectionList(in: response)["contents"].array.flatMap { section in
            Renderers.tracks(section["musicShelfRenderer", "contents"].array)
        }
    }
}
