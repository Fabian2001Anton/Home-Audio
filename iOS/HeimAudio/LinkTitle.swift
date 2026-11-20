import Foundation
import LinkPresentation

// Finds a readable name for a link.
enum LinkTitle {
    // Name available right away, until the real title is loaded from the internet (German, shown to the user).
    static func provisional(for url: URL) -> String {
        if isYouTube(url) {
            return url.path().hasPrefix("/playlist") ? "YouTube-Playlist" : "YouTube-Video"
        }
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    // Loads the real title. Returns nil if that doesn't work.
    static func load(for url: URL) async -> String? {
        let title = isYouTube(url) ? await youTubeTitle(url) : await pageTitle(url)
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }

    // YouTube via the official oEmbed API. In the EU, the normal page often shows
    // only the consent page instead of the title when not signed in.
    private static func youTubeTitle(_ url: URL) async -> String? {
        struct Response: Decodable {
            let title: String
        }
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let requestURL = components.url,
              let result = try? await URLSession.shared.data(from: requestURL),
              (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Response.self, from: result.0).title
    }

    // All other pages: the title as iMessage uses it for link previews.
    private static func pageTitle(_ url: URL) async -> String? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        return try? await provider.startFetchingMetadata(for: url).title
    }
}
