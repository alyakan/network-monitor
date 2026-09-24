import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isShowingSetup = false

    var body: some View {
        HSplitView {
            TransactionTable(model: model)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            TransactionDetailView(transaction: model.selectedTransaction)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter by host, path, method or status")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.toggleProxy) {
                Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(model.authority == nil || model.isStarting)
            .help(model.isRunning ? "Stop the proxy" : "Start listening")

            TextField("Port", value: $model.port, format: .number.grouping(.never))
                .frame(width: 56)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRunning)

            statusLabel
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.clear) {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.transactions.isEmpty)

            Button { isShowingSetup.toggle() } label: {
                Label("Setup", systemImage: "iphone.gen3.badge.exclamationmark")
            }
            .popover(isPresented: $isShowingSetup, arrowEdge: .bottom) {
                SetupView(model: model)
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(model.errorMessage == nil ? .secondary : Color.red)
                .lineLimit(1)
        }
        .padding(.leading, 6)
    }

    private var statusText: String {
        if let error = model.errorMessage { return error }
        if model.isRunning { return "Listening on port \(model.port) · \(model.transactions.count) requests" }
        return "Stopped"
    }
}
