import Foundation

// What the computer reports about itself.
struct ComputerStatus: Decodable {
    let computer: String
    let system: String
    let volume: Int?
    let muted: Bool
}

// How the service reports errors: {"error": "..."}
struct ErrorResponse: Decodable {
    let error: String
}

enum MediaKey: String {
    case play, next, previous
}

// An open tab in the computer's browser.
struct BrowserTab: Decodable, Identifiable {
    let browser: String
    let tabID: Int
    let title: String
    let url: String
    let window: Int
    let active: Bool // the visible tab of its window

    // The tab ID is only unique within one browser.
    var id: String { "\(browser)-\(tabID)" }

    enum CodingKeys: String, CodingKey {
        case browser, title, url, window, active
        case tabID = "id"
    }
}

private struct TabList: Decodable {
    let tabs: [BrowserTab]
}

// Error messages are shown to the user and are therefore German.
enum ComputerError: LocalizedError {
    case rejected(String)
    case unexpectedResponse(Int)

    var errorDescription: String? {
        switch self {
        case .rejected(let message):
            message
        case .unexpectedResponse(let code):
            "Unerwartete Antwort vom Rechner (Code \(code))."
        }
    }
}

// Talks to the HeimAudio service on the computer.
struct ComputerAPI {
    let baseURL: URL
    let key: String

    // nil as long as the address or key is missing.
    init?(address: String, port: Int, key: String) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = port
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard components.host?.isEmpty == false, !key.isEmpty, let url = components.url else { return nil }
        self.baseURL = url
        self.key = key
    }

    func status() async throws -> ComputerStatus {
        try await send(request("/api/status"))
    }

    func setVolume(_ value: Int) async throws -> ComputerStatus {
        try await send(postRequest("/api/volume", body: ["value": value]))
    }

    func setMuted(_ muted: Bool) async throws -> ComputerStatus {
        try await send(postRequest("/api/mute", body: ["muted": muted]))
    }

    func press(_ key: MediaKey) async throws -> ComputerStatus {
        try await send(postRequest("/api/media-key", body: ["key": key.rawValue]))
    }

    func open(_ url: URL) async throws -> ComputerStatus {
        try await send(postRequest("/api/open", body: ["url": url.absoluteString]))
    }

    // Open browser tabs. Longer timeout: the first time, the Mac waits for a permission.
    func tabs() async throws -> [BrowserTab] {
        var tabsRequest = request("/api/tabs")
        tabsRequest.timeoutInterval = 60
        return try await send(tabsRequest, as: TabList.self).tabs
    }

    func closeTab(_ tab: BrowserTab) async throws -> [BrowserTab] {
        struct Body: Encodable {
            let browser: String
            let id: Int
        }
        var closeRequest = postRequest("/api/close-tab", body: Body(browser: tab.browser, id: tab.tabID))
        closeRequest.timeoutInterval = 60
        return try await send(closeRequest, as: TabList.self).tabs
    }

    // The request for the endless audio stream. AudioReceiver uses it.
    // economical: AAC at 96 kbit/s instead of uncompressed (about 45 instead of 700 MB per hour).
    func audioRequest(economical: Bool) -> URLRequest {
        var audioRequest = request("/api/audio")
        if economical, let url = audioRequest.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [
                URLQueryItem(name: "format", value: "aac"),
                URLQueryItem(name: "kbit", value: "96"),
            ]
            audioRequest.url = components.url
        }
        return audioRequest
    }

    // MARK: - Internal

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        return request
    }

    private func postRequest<Body: Encodable>(_ path: String, body: Body) -> URLRequest {
        var request = self.request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> ComputerStatus {
        try await send(request, as: ComputerStatus.self)
    }

    private func send<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ComputerError.rejected(errorResponse.error)
            }
            throw ComputerError.unexpectedResponse(code)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
