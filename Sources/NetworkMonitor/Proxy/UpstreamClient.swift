import Foundation

struct UpstreamResponse: Sendable {
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let body: Data
}

/// Performs the real request on behalf of the device. Redirects, cookies, caching and
/// system proxies are all disabled so the response reaches the device untouched.
final class UpstreamClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let strippedRequestHeaders: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host",
    ]

    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
        super.init()
    }

    func send(method: String, url: URL, headers: [HTTPHeaderField], body: Data) async throws -> UpstreamResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for field in headers where !Self.strippedRequestHeaders.contains(field.name.lowercased()) {
            request.addValue(field.value, forHTTPHeaderField: field.name)
        }
        if !body.isEmpty {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let fields = http.allHeaderFields
            .compactMap { key, value -> HTTPHeaderField? in
                guard let name = key as? String, let value = value as? String else { return nil }
                return HTTPHeaderField(name: name, value: value)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return UpstreamResponse(statusCode: http.statusCode, headers: fields, body: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
