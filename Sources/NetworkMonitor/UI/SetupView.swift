import AppKit
import SwiftUI

struct SetupView: View {
    let model: AppModel
    @State private var platform: TargetPlatform = .iosSimulator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            addressSection
            Divider()
            Picker("", selection: $platform) {
                ForEach(TargetPlatform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            PlatformStepsView(platform: platform, model: model)
            Divider()
            certificateSection
            if let message = model.setupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    // MARK: - Sections

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proxy address").font(.headline)
            if model.localAddresses.isEmpty {
                Text("No network interface found").foregroundStyle(.secondary)
            }
            ForEach(model.localAddresses, id: \.self) { address in
                HStack {
                    Text("\(address):\(model.port)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    CopyButton(text: "\(address):\(model.port)")
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Root certificate").font(.headline)
            HStack {
                Text(model.certificatePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder", action: model.revealCertificate)
                    .controlSize(.small)
            }
        }
    }
}
