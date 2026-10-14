import Foundation

struct HTTPHeaderField: Hashable, Sendable {
    let name: String
    let value: String
}

extension Array where Element == HTTPHeaderField {
    func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct Transaction: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case pending
        case completed
        case failed(String)
    }

    let id: UUID
    let startedAt: Date
    let method: String
    let url: String
    let host: String
    let path: String
    let requestHeaders: [HTTPHeaderField]
    let requestBody: Data
    var statusCode: Int?
    var responseHeaders: [HTTPHeaderField] = []
    var responseBody = Data()
    var duration: TimeInterval?
    var outcome: Outcome = .pending
    /// The model's change counter when this transaction last changed, so the local API can serve "what changed since".
    var revision: UInt64 = 0

    var requestContentType: String? { requestHeaders.value(for: "Content-Type") }
    var responseContentType: String? { responseHeaders.value(for: "Content-Type") }

    var errorMessage: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    var statusClass: StatusClass? {
        switch outcome {
        case .pending: return nil
        case .failed: return .failed
        case .completed: return statusCode.flatMap(StatusClass.init(code:))
        }
    }
}

enum StatusClass: String, CaseIterable, Identifiable, Sendable {
    case success = "2xx"
    case redirect = "3xx"
    case clientError = "4xx"
    case serverError = "5xx"
    case failed = "Failed"

    var id: String { rawValue }

    init?(code: Int) {
        switch code {
        case 200..<300: self = .success
        case 300..<400: self = .redirect
        case 400..<500: self = .clientError
        case 500..<600: self = .serverError
        default: return nil
        }
    }
}

protocol TransactionRecorder: Sendable {
    func transactionDidStart(_ transaction: Transaction)
    func transactionDidComplete(id: UUID, statusCode: Int, headers: [HTTPHeaderField], body: Data, duration: TimeInterval)
    func transactionDidFail(id: UUID, message: String, duration: TimeInterval)
}
