import Foundation
import SwiftData

// A saved link, e.g. a YouTube playlist.
// @Model: SwiftData stores it permanently on the iPhone.
@Model
final class SavedLink {
    var title: String
    var url: String
    var createdAt: Date

    init(title: String, url: String, createdAt: Date = .now) {
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }

    // Short form for display: without https:// and www.
    var displayAddress: String {
        var text = url
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }
}
