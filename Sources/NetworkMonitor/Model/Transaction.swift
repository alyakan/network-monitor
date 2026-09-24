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

    var requestContentType: String? { requestHeaders.value(for: "Content-Type") }
    var responseContentType: String? { responseHeaders.value(for: "Content-Type") }

    var errorMessage: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }
}

protocol TransactionRecorder: Sendable {
    func transactionDidStart(_ transaction: Transaction)
    func transactionDidComplete(id: UUID, statusCode: Int, headers: [HTTPHeaderField], body: Data, duration: TimeInterval)
    func transactionDidFail(id: UUID, message: String, duration: TimeInterval)
}
