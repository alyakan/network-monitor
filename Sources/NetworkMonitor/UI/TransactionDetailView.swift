import AppKit
import SwiftUI

struct TransactionDetailView: View {
    private enum Side: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"

        var id: String { rawValue }
    }

    let transaction: Transaction?
    @State private var side: Side = .response

    var body: some View {
        if let transaction {
            VStack(alignment: .leading, spacing: 0) {
                summary(for: transaction)
                Divider()
                Picker("", selection: $side) {
                    ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headersSection(for: transaction)
                        bodySection(for: transaction)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView("No request selected", systemImage: "network", description: Text("Requests appear on the left as the device makes them."))
        }
    }

    // MARK: - Summary

    private func summary(for transaction: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transaction.method)
                    .fontWeight(.bold)
                    .foregroundStyle(MethodStyle.color(for: transaction.method))
                Text(transaction.url)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                Button("Copy as cURL") { copyCURL(transaction) }
                    .controlSize(.small)
            }
            HStack(spacing: 12) {
                switch transaction.outcome {
                case .pending:
                    Text("Waiting for response…").foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .completed:
                    Text("Status \(transaction.statusCode ?? 0)")
                        .foregroundStyle(StatusStyle.color(for: transaction.statusCode))
                        .fontWeight(.medium)
                    Text("\(Int((transaction.duration ?? 0) * 1000)) ms")
                    Text("↑ \(Int64(transaction.requestBody.count).formatted(.byteCount(style: .file)))")
                    Text("↓ \(Int64(transaction.responseBody.count).formatted(.byteCount(style: .file)))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Sections

    private func headersSection(for transaction: Transaction) -> some View {
        let headers = side == .request ? transaction.requestHeaders : transaction.responseHeaders
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Headers", count: headers.count)
            if headers.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        GridRow {
                            Text(header.name)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(header.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func bodySection(for transaction: Transaction) -> some View {
        let data = side == .request ? transaction.requestBody : transaction.responseBody
        let contentType = side == .request ? transaction.requestContentType : transaction.responseContentType
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Body", count: nil)
            BodyView(presentation: BodyPresentation.make(data: data, contentType: contentType))
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let count {
                Text("\(count)").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    // MARK: - Actions

    private func copyCURL(_ transaction: Transaction) {
        var parts = ["curl", "-X", transaction.method, shellQuote(transaction.url)]
        for header in transaction.requestHeaders where header.name.lowercased() != "content-length" {
            parts.append("-H")
            parts.append(shellQuote("\(header.name): \(header.value)"))
        }
        if !transaction.requestBody.isEmpty, let body = String(data: transaction.requestBody, encoding: .utf8) {
            parts.append("--data-binary")
            parts.append(shellQuote(body))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: " "), forType: .string)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Body rendering

enum BodyPresentation {
    case empty
    case text(String, truncated: Bool)
    case image(NSImage)
    case binary(Int)

    private static let textLimit = 300_000

    static func make(data: Data, contentType: String?) -> BodyPresentation {
        guard !data.isEmpty else { return .empty }
        let type = contentType?.lowercased() ?? ""

        if type.hasPrefix("image/"), let image = NSImage(data: data) {
            return .image(image)
        }
        if type.contains("json") || looksLikeJSON(data),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let string = String(data: pretty, encoding: .utf8) {
            return truncate(string)
        }
        if let string = String(data: data, encoding: .utf8) {
            return truncate(string)
        }
        return .binary(data.count)
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private static func truncate(_ string: String) -> BodyPresentation {
        guard string.utf8.count > textLimit else { return .text(string, truncated: false) }
        return .text(String(string.prefix(textLimit)), truncated: true)
    }
}

struct BodyView: View {
    let presentation: BodyPresentation

    var body: some View {
        switch presentation {
        case .empty:
            Text("Empty").foregroundStyle(.secondary)
        case .text(let string, let truncated):
            VStack(alignment: .leading, spacing: 6) {
                if truncated {
                    Text("Showing the first 300 KB").font(.callout).foregroundStyle(.orange)
                }
                Text(string)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 480, maxHeight: 480, alignment: .leading)
        case .binary(let count):
            Text("Binary data · \(Int64(count).formatted(.byteCount(style: .file)))").foregroundStyle(.secondary)
        }
    }
}
