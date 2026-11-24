import Foundation

/// Lyrics sites other than YouTube, given little time as YouTube's own lyrics wait on them.
enum LyricsSite {
    /// Nil on a 404, which these sites answer a miss with. Items without a value are left out.
    static func get(_ host: String, _ path: String, _ items: KeyValuePairs<String, String?> = [:]) async throws -> Data? {
        var address = URLComponents()
        address.scheme = "https"
        address.host = host
        address.path = path
        if !items.isEmpty { address.percentEncodedQuery = query(items) }
        guard let url = address.url else { return nil }
        return try await send(URLRequest(url: url))
    }

    /// `items` as a form or query, a "+" kept from being read as a space.
    static func query(_ items: KeyValuePairs<String, String?>) -> String? {
        var form = URLComponents()
        form.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    /// `fetch`'s answer, or nil on failure or once `deadline` passes.
    static func within<T: Sendable>(_ deadline: Duration, _ fetch: @escaping @Sendable () async throws -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await fetch() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    static func send(_ request: URLRequest) async throws -> Data? {
        do {
            return try await HTTP.data(for: prepared(request)).0
        } catch let error as YTMError where error.status == 404 {
            return nil
        }
    }

    /// `send`'s answer as it arrives, for one sent in parts.
    static func stream(_ request: URLRequest) async throws -> URLSession.AsyncBytes? {
        do {
            return try await HTTP.bytes(for: prepared(request))
        } catch let error as YTMError where error.status == 404 {
            return nil
        }
    }

    /// The 4 s is how long the site may fall silent, not how long it may take.
    private static func prepared(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = 4
        request.setValue("Lily", forHTTPHeaderField: "User-Agent")
        return request
    }
}
