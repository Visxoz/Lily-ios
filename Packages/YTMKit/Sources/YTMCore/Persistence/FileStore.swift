import Foundation
import os
import Synchronization

/// The JSON files the app keeps between launches.
public enum StoreFile: String, Sendable {
    case settings, session, history, searches, home, scrobbles, visitor
    /// The Premium path's trimmed player script.
    case player
}

/// Saves and loads the app's state as JSON files in
/// Application Support/YTMusic/.
///
/// Writes run on one serial queue, so they never hold up the caller and run
/// in the order they were asked for. Each replaces its file atomically, so a
/// crash midway leaves the old one whole, and a save overtaken by a newer
/// one of the same file is skipped rather than written.
public final class FileStore: Sendable {
    public static let shared = FileStore(
        directory: URL.applicationSupportDirectory.appending(path: "YTMusic", directoryHint: .isDirectory)
    )

    private let directory: URL
    private let queue = DispatchQueue(label: "YTMusic.FileStore", qos: .utility)
    /// The newest save asked for, per file, so older ones queued behind it
    /// are skipped.
    private let latest = Mutex<[StoreFile: UInt64]>([:])
    private static let log = Logger(subsystem: "YTMusic", category: "FileStore")

    /// `directory` is created on the first save.
    init(directory: URL) {
        self.directory = directory
    }

    private func url(_ file: StoreFile) -> URL {
        directory.appending(path: file.rawValue + ".json", directoryHint: .notDirectory)
    }

    /// The file's contents, or nil when it is missing or can't be read. Waits
    /// for saves already queued, so it always reads the latest; call it off
    /// the main actor.
    public func load<T: Decodable>(_ type: T.Type, from file: StoreFile) -> T? {
        let url = url(file)
        guard let data = queue.sync(execute: { try? Data(contentsOf: url) }) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("\(file.rawValue, privacy: .public).json could not be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes `value` off the caller's thread; of several saves of one file,
    /// the last asked for is the one that stays.
    public func save<T: Encodable & Sendable>(_ value: T, to file: StoreFile) {
        let ticket = nextTicket(for: file)
        let url = url(file)
        queue.async { [directory] in
            guard self.isLatest(ticket, for: file) else { return }
            do {
                let data = try Self.encoder.encode(value)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("\(file.rawValue, privacy: .public).json could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the file after any saves already queued, which it overtakes.
    public func remove(_ file: StoreFile) {
        _ = nextTicket(for: file)
        let url = url(file)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func nextTicket(for file: StoreFile) -> UInt64 {
        latest.withLock { tickets in
            let ticket = tickets[file, default: 0] + 1
            tickets[file] = ticket
            return ticket
        }
    }

    private func isLatest(_ ticket: UInt64, for file: StoreFile) -> Bool {
        latest.withLock { $0[file] == ticket }
    }

    /// Shared, and only used on `queue`, one encode at a time.
    private static let encoder = JSONEncoder()
}
