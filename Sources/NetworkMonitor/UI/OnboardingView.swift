import SwiftUI

/// First-launch guide. Reopened any time via Help → Setup Guide.
struct OnboardingView: View {
    let model: AppModel
    let onDismiss: () -> Void
    @State private var platform: TargetPlatform = .iosSimulator

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            howItWorks
            Divider()
            targetSection
            if let message = model.setupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Network Monitor").font(.title2).fontWeight(.semibold)
                Text("See every request your app makes, including HTTPS.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            point("play.fill", "The proxy starts automatically and listens on port \(model.port). Change the port in the toolbar.")
            point("iphone.and.arrow.forward", "Point your simulator or device at this Mac as an HTTP proxy.")
            point("checkmark.shield", "Trust the generated root certificate on the device so HTTPS can be decrypted. Nothing leaves your Mac.")
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up your target").font(.headline)
            Picker("", selection: $platform) {
                ForEach(TargetPlatform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            PlatformStepsView(platform: platform, model: model)
        }
    }

    private var footer: some View {
        HStack {
            Text("Reopen this guide from Help → Setup Guide, or the Setup button in the toolbar.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
