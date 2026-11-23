import Foundation

/// Lyrics sites other than YouTube: asked without cookies, as an unnamed client, and given little time,
/// as YouTube's own lyrics wait on them.
enum LyricsSite {
    /// Nil on a 404, which these sites answer a miss with. Items without a value are left out.
    static func get(_ host: String, _ path: String, _ items: KeyValuePairs<String, String?> = [:]) async throws -> Data? {
        var address = URLComponents()
        address.scheme = "https"
        address.host = host
        address.path = path
        if !items.isEmpty {
            address.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            // Left as it is, a "+" in a name would be read as a space.
            address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = address.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Lily", forHTTPHeaderField: "User-Agent")
        do {
            return try await HTTP.data(for: request).0
        } catch let error as YTMError where error.status == 404 {
            return nil
        }
    }
}
