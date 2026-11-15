import Foundation
import Testing
@testable import YTMCore

@Suite struct SettingsTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func anUnreadableSettingResetsOnlyItself() throws {
        let settings = try decode(#"{"youtubeHistory": false, "accent": "beige", "equaliserGains": [1], "volume": 0.5}"#)
        #expect(!settings.youtubeHistory, "the opt-out is kept")
        #expect(settings.accent == .red)
        #expect(settings.equaliserGains == Array(repeating: 0, count: 6))
    }

    @Test func fillsMissingFieldsWithDefaults() throws {
        let settings = try decode(#"{"look": "black", "accent": "artwork", "shuffle": "smart"}"#)
        #expect(settings.look == .black && settings.accent == .artwork && settings.shuffle == .smart)
        #expect(settings.normalise && !settings.crossfade && settings.quality == .high)
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: saved) == settings)
    }

    @Test func accentsAreYTMNativesColours() {
        #expect(Accent.red.rgb == 0xff0033)
        #expect(Accent.artwork.rgb == nil)
        #expect(Accent.artwork.name == "From the artwork")
    }
}

@Suite struct HistoryTests {
    @Test func keepsTheNewestPlayOfEachSong() {
        var history = PlayHistory()
        for id in ["a", "b", "a"] { history.record(Track(id: id, title: id)) }
        #expect(history.tracks.map(\.id) == ["a", "b"])
        let long = PlayHistory(tracks: (0..<600).map { Track(id: "\($0)", title: "") } + [Track(id: "0", title: "")])
        #expect(long.tracks.count == 500)
    }

    @Test func searchesKeepTheNewestFiveOnceEach() throws {
        var searches = RecentSearches()
        for q in ["a", "b", "c", "d", "e", "f"] { searches.record(q) }
        #expect(searches.queries == ["f", "e", "d", "c", "b"])
        searches.record("  C ")
        #expect(searches.queries == ["C", "f", "e", "d", "b"])
        searches.record("   ")
        searches.remove("F")
        #expect(searches.queries == ["C", "e", "d", "b"])
        let edited = try JSONDecoder().decode(
            RecentSearches.self, from: Data(#"{"queries":["x","  ","X","y ","a","b","c","d"]}"#.utf8))
        #expect(edited.queries == ["x", "y", "a", "b", "c"], "trimmed, without blanks or repeats, the newest five")
    }
}

@Suite struct FileStoreTests {
    @Test func laterSavesWinAndRemovesDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ytm-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileStore(directory: directory)
        #expect(store.load([String].self, from: .searches) == nil)
        for n in 0..<50 { store.save(["\(n)"], to: .searches) }
        #expect(store.load([String].self, from: .searches) == ["49"])
        store.remove(.searches)
        #expect(store.load([String].self, from: .searches) == nil)
        store.save(Settings(), to: .settings)
        #expect(store.load(Settings.self, from: .settings) == Settings())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == ["settings.json"])
    }
}
