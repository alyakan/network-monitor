import SwiftUI

enum TargetPlatform: String, CaseIterable, Identifiable {
    case iosSimulator = "iOS Simulator"
    case iosDevice = "iPhone / iPad"
    case android = "Android"

    var id: String { rawValue }
}

/// Setup steps and one-click actions for a given target, shared by the Setup popover and the guide.
struct PlatformStepsView: View {
    let platform: TargetPlatform
    let model: AppModel

    private var address: String { "\(model.localAddresses.first ?? "<mac-ip>"):\(model.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch platform {
            case .iosSimulator: simulatorSteps
            case .iosDevice: deviceSteps
            case .android: androidSteps
            }
        }
    }

    // MARK: - Platforms

    private var simulatorSteps: some View {
        Group {
            step(1, "Install the root certificate into the booted simulator.") {
                Button("Install certificate", action: model.installCertificateInBootedSimulator)
            }
            step(2, "Route the Mac through the proxy. The simulator follows the Mac's system proxy.") {
                Button(model.isSystemProxyEnabled ? "Disable macOS proxy" : "Enable macOS proxy") {
                    Task { await model.setSystemProxy(enabled: !model.isSystemProxyEnabled) }
                }
                .disabled(!model.isRunning && !model.isSystemProxyEnabled)
            }
            step(3, "Use the app in the simulator. Requests appear in the list. The proxy is disabled again on Stop or Quit.")
        }
    }

    private var deviceSteps: some View {
        Group {
            step(1, "Same Wi‑Fi as the Mac. Settings → Wi‑Fi → ⓘ → Configure Proxy → Manual → \(address).") {
                CopyButton(text: address)
            }
            step(2, "Open http://\(address) in Safari and download the certificate.")
            step(3, "Settings → General → VPN & Device Management → install “Network Monitor Root CA”.")
            step(4, "Settings → General → About → Certificate Trust Settings → enable full trust.")
        }
    }

    private var androidSteps: some View {
        Group {
            step(1, "Wi‑Fi → network → Proxy: Manual → \(address). Emulator: 10.0.2.2:\(model.port).") {
                CopyButton(text: address)
            }
            step(2, "Copy the certificate to the device, or download it from http://\(address) in Chrome.") {
                Button("Push via adb", action: model.pushCertificateToAndroidDevice)
            }
            step(3, "Settings → Security → Encryption & credentials → Install a certificate → CA certificate.")
            step(4, "Apps only trust user CAs when their debug network security config opts in. See the README.")
        }
    }

    // MARK: - Helpers

    private func step(_ number: Int, _ text: String) -> some View {
        step(number, text) { EmptyView() }
    }

    private func step<Action: View>(_ number: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
                .controlSize(.small)
        }
        .font(.callout)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}
