import AppKit
import SwiftUI

struct TransactionDetailView: View {
    private enum Side: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"

        var id: String { rawValue }
    }

    /// Selecting a request re-renders on every proxy event; parsing the body only when this changes keeps large bodies cheap.
    private struct BodyKey: Hashable {
        let transactionID: Transaction.ID
        let side: Side
        let size: Int
    }

    let transaction: Transaction?
    @State private var side: Side = .response
    @State private var presentation: BodyPresentation = .empty

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
                VSplitView {
                    ScrollView {
                        headersSection(for: transaction)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, idealHeight: 180)
                    bodySection
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            .task(id: BodyKey(transactionID: transaction.id, side: side, size: bodyData(for: transaction).count)) {
                presentation = BodyPresentation.make(data: bodyData(for: transaction), contentType: contentType(for: transaction))
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
                Button("Copy Response") { copyResponse(transaction) }
                    .controlSize(.small)
                    .disabled(transaction.outcome != .completed)
                    .help("Copy status line, headers and body")
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

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Body", count: nil)
                .padding([.horizontal, .top], 12)
            BodyView(presentation: presentation)
        }
    }

    private func bodyData(for transaction: Transaction) -> Data {
        side == .request ? transaction.requestBody : transaction.responseBody
    }

    private func contentType(for transaction: Transaction) -> String? {
        side == .request ? transaction.requestContentType : transaction.responseContentType
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
        copyToPasteboard(parts.joined(separator: " "))
    }

    private func copyResponse(_ transaction: Transaction) {
        var lines = ["HTTP/1.1 \(transaction.statusCode ?? 0)"]
        lines += transaction.responseHeaders.map { "\($0.name): \($0.value)" }
        var text = lines.joined(separator: "\n")
        if !transaction.responseBody.isEmpty {
            text += "\n\n" + BodyPresentation.fullText(data: transaction.responseBody, contentType: transaction.responseContentType)
        }
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
        if let string = text(data: data, contentType: type) {
            return truncate(string)
        }
        return .binary(data.count)
    }

    /// Untruncated text for the clipboard, pretty-printing JSON like the on-screen view.
    static func fullText(data: Data, contentType: String?) -> String {
        text(data: data, contentType: contentType?.lowercased() ?? "")
            ?? "<binary data, \(Int64(data.count).formatted(.byteCount(style: .file)))>"
    }

    private static func text(data: Data, contentType type: String) -> String? {
        if type.contains("json") || looksLikeJSON(data),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .utf8)
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
            placeholder(Text("Empty").foregroundStyle(.secondary))
        case .text(let string, let truncated):
            VStack(alignment: .leading, spacing: 6) {
                if truncated {
                    Text("Showing the first 300 KB").font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                }
                BodyTextView(text: string)
            }
        case .image(let image):
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480, maxHeight: 480, alignment: .leading)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .binary(let count):
            placeholder(Text("Binary data · \(Int64(count).formatted(.byteCount(style: .file)))").foregroundStyle(.secondary))
        }
    }

    private func placeholder(_ text: some View) -> some View {
        text
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// SwiftUI `Text` lays out its whole string on the main thread, which hangs on bodies of a few hundred KB.
/// `NSTextView` lays out lazily as you scroll.
struct BodyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.layoutManager?.allowsNonContiguousLayout = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}
