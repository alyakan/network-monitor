import AppKit
import SwiftUI

struct SetupView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            addressSection
            Divider()
            deviceSection
            Divider()
            simulatorSection
            Divider()
            androidSection
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
        .frame(width: 460)
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
                    Button { copy("\(address):\(model.port)") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone / iPad").font(.headline)
            step(1, "Settings → Wi‑Fi → ⓘ → Configure Proxy → Manual. Enter the address above.")
            step(2, "Open http://\(model.localAddresses.first ?? "<mac-ip>"):\(model.port) in Safari and download the certificate.")
            step(3, "Settings → General → VPN & Device Management → install the profile.")
            step(4, "Settings → General → About → Certificate Trust Settings → enable full trust.")
        }
    }

    private var simulatorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulator").font(.headline)
            Text("The simulator uses the Mac's system proxy. Enable it while testing and disable it afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Install certificate in booted simulator", action: model.installCertificateInBootedSimulator)
                Button(model.isSystemProxyEnabled ? "Disable macOS proxy" : "Enable macOS proxy") {
                    Task { await model.setSystemProxy(enabled: !model.isSystemProxyEnabled) }
                }
                .disabled(!model.isRunning && !model.isSystemProxyEnabled)
            }
            .controlSize(.small)
        }
    }

    private var androidSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Android").font(.headline)
            step(1, "Wi‑Fi → network → Proxy: Manual with the address above. Emulator: use 10.0.2.2:\(model.port).")
            step(2, "Push the certificate below, then Settings → Security → Encryption & credentials → Install a certificate → CA certificate.")
            step(3, "Apps ignore user CAs unless their debug network security config trusts them. See the README.")
            Button("Push certificate to connected device (adb)", action: model.pushCertificateToAndroidDevice)
                .controlSize(.small)
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

    // MARK: - Helpers

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).").foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
