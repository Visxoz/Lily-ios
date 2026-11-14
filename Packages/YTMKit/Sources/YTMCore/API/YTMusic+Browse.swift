import Foundation

extension YTMusic {
    /// A browse page opened by a "More" button, such as an artist's whole
    /// discography or a Home shelf in full: its sections, each list followed
    /// to its end. Asked as the account, since Home's shelves are its own.
    func browsePage(_ id: String, params: String?) async throws -> Page {
        let response = try await innerTube.browse(id, params: params)
        let title = response["header"].onlyValue?.value["title"].text ?? ""
        // A discography's tiles say only "Album • 2021"; the page is the artist's.
        let context = id.hasPrefix("MPAD") && !title.isEmpty
            ? ItemContext(artists: [ArtistRef(id: String(id.dropFirst(4)), name: title)])
            : ItemContext()
        var sections: [Section] = []
        for wrapped in Renderers.sectionList(in: response)["contents"].array {
            guard var section = Renderers.section(wrapped, context: context) else { continue }
            if let list = wrapped.onlyValue?.value {
                try await following(list, authenticated: true) { section.append($0, context: context) }
            }
            sections.append(section)
        }
        guard !sections.isEmpty else { throw YTMError(.notFound, "There's nothing here.") }
        return Page(header: title.isEmpty ? nil : PageHeader(title: title), sections: sections)
    }

    /// Hands `take` the items of every batch after a list's first (a shelf
    /// or grid's unwrapped body), up to `maxBatches`, each as it arrives, so
    /// a batch's JSON is parsed and freed before the next is asked for. A
    /// batch that fails ends the list with what arrived.
    func following(_ list: JSON, authenticated: Bool, _ take: ([JSON]) -> Void) async throws {
        var token = Renderers.continuation(list)
        var batches = 0
        while let current = token, batches < Self.maxBatches {
            let response: JSON
            do {
                response = try await innerTube.continuation(current, authenticated: authenticated)
            } catch {
                try Task.checkCancellation()
                break
            }
            let (batch, next) = Renderers.continuationItems(in: response)
            take(batch)
            token = next
            batches += 1
        }
    }

    /// Bounds how far a list is followed, so a list that never ends can't
    /// hold the page.
    private static let maxBatches = 20
}

extension Section {
    /// Adds the tracks or cards among `items` to the section's own kind.
    mutating func append(_ items: [JSON], context: ItemContext) {
        guard !items.isEmpty else { return }
        switch self {
        case .tracks(var section):
            section.tracks += Renderers.tracks(items, context: context)
            self = .tracks(section)
        case .cards(var section):
            section.cards += Renderers.cards(items, context: context)
            self = .cards(section)
        }
    }
}
