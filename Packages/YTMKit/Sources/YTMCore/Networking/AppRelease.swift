import Foundation

/// This build's version, and whether GitHub has a newer release of Lily.
public enum AppRelease {
    /// Nil outside the app, as in ytmcheck.
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private static let repository = "Visxoz/Lily-ios"
    /// The latest release's page, and its IPA, which GitHub redirects to the newest.
    public static let page = URL(string: "https://github.com/\(repository)/releases/latest")
    public static let ipa = "https://github.com/\(repository)/releases/latest/download/Lily.ipa"
    private static let latest = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")

    /// False on any failure, as a missed update matters less than a false one.
    @concurrent
    public static func hasUpdate() async -> Bool {
        guard let version, let latest, let (data, _) = try? await HTTP.data(for: URLRequest(url: latest)),
              let tag = (try? JSON(data: data))?["tag_name"].string
        else { return false }
        return isNewer(tag, than: version)
    }

    /// Tags are "v1.0.4"; compared number by number, so 1.0.10 is after 1.0.9.
    static func isNewer(_ tag: String, than version: String) -> Bool {
        tag.trimmingPrefix("v").compare(version, options: .numeric) == .orderedDescending
    }
}
