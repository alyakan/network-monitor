import SwiftUI

struct FilterMenus: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            if model.availableMethods.isEmpty {
                Text("No requests yet")
            }
            ForEach(model.availableMethods, id: \.self) { method in
                Toggle(method, isOn: binding(for: method, in: \.methodFilter))
            }
            if !model.methodFilter.isEmpty {
                Divider()
                Button("Show All Methods") { model.methodFilter = [] }
            }
        } label: {
            Label(title(for: model.methodFilter.sorted(), fallback: "Method"), systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter by HTTP method")

        Menu {
            ForEach(StatusClass.allCases) { status in
                Toggle(status.rawValue, isOn: binding(for: status, in: \.statusFilter))
            }
            if !model.statusFilter.isEmpty {
                Divider()
                Button("Show All Statuses") { model.statusFilter = [] }
            }
        } label: {
            Label(title(for: StatusClass.allCases.filter(model.statusFilter.contains).map(\.rawValue), fallback: "Status"), systemImage: "number")
        }
        .help("Filter by response status")
    }

    private func binding<Value: Hashable>(for value: Value, in keyPath: ReferenceWritableKeyPath<AppModel, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { model[keyPath: keyPath].insert(value) } else { model[keyPath: keyPath].remove(value) }
            }
        )
    }

    private func title(for selection: [String], fallback: String) -> String {
        selection.isEmpty ? fallback : selection.joined(separator: ", ")
    }
}
