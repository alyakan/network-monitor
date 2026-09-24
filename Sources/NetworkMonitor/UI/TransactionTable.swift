import SwiftUI

struct TransactionTable: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.filteredTransactions, selection: $model.selectedTransactionID) {
            TableColumn("Time") { transaction in
                Text(transaction.startedAt, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
            }
            .width(72)

            TableColumn("Method") { transaction in
                Text(transaction.method)
                    .fontWeight(.semibold)
                    .foregroundStyle(MethodStyle.color(for: transaction.method))
            }
            .width(62)

            TableColumn("Status") { transaction in
                StatusBadge(transaction: transaction)
            }
            .width(52)

            TableColumn("Host") { transaction in
                Text(transaction.host)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 190)

            TableColumn("Path") { transaction in
                Text(transaction.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(transaction.url)
            }

            TableColumn("Duration") { transaction in
                Text(transaction.duration.map { "\(Int($0 * 1000)) ms" } ?? "…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Size") { transaction in
                Text(Int64(transaction.responseBody.count), format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(70)
        }
        .font(.system(size: 12))
    }
}

struct StatusBadge: View {
    let transaction: Transaction

    var body: some View {
        switch transaction.outcome {
        case .pending:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(transaction.errorMessage ?? "Failed")
        case .completed:
            Text(transaction.statusCode.map(String.init) ?? "—")
                .fontWeight(.medium)
                .foregroundStyle(StatusStyle.color(for: transaction.statusCode))
        }
    }
}

enum MethodStyle {
    static func color(for method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }
}

enum StatusStyle {
    static func color(for status: Int?) -> Color {
        switch status ?? 0 {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }
}
