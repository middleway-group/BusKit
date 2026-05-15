import SwiftUI

@available(macOS 15.0, *)
struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("BusKitLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

            Text("BusKit")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Azure Service Bus client for macOS")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Acknowledgments")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Link("Sparkle", destination: URL(string: "https://sparkle-project.org/")!)
                        .font(.caption)
                    Text("is by Sparkle Project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("© 2026 Peter Karda")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(width: 320)
    }
}
