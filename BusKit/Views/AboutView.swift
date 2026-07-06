import SwiftUI

private struct AcknowledgmentEntry: Identifiable {
    let id = UUID()
    let name: String
    let copyright: String
    let license: String
    let url: URL
}

private let acknowledgments: [AcknowledgmentEntry] = [
    AcknowledgmentEntry(
        name: "Azure SDK",
        copyright: "Copyright (c) Microsoft Corporation",
        license: "MIT License",
        url: URL(string: "https://github.com/Azure/azure-sdk-for-net")!
    ),
    AcknowledgmentEntry(
        name: "gRPC Swift",
        copyright: "Copyright (c) gRPC authors",
        license: "Apache License, Version 2.0",
        url: URL(string: "https://github.com/grpc/grpc-swift")!
    ),
    AcknowledgmentEntry(
        name: "Sparkle",
        copyright: "Copyright (c) 2006-present Sparkle Project Contributors",
        license: "MIT License",
        url: URL(string: "https://sparkle-project.org")!
    ),
]

@available(macOS 15.0, *)
struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            appInfoColumn
            acknowledgementsColumn
        }
        .frame(width: 520, height: 200)
    }

    private var acknowledgementsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Acknowledgments")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                ForEach(Array(acknowledgments.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Spacer().frame(height: 8)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Link(entry.name, destination: entry.url)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(entry.copyright)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.license)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 260)
    }

    private var appInfoColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            VStack(spacing: 4) {
                Image("BusKitLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    .padding(.bottom, 4)

                Text("BusKit")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Azure Service Bus client for macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Built with help of AI tools")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 12)

            VStack(spacing: 2) {
                Text("Released under the MIT License")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("© 2026 Peter Karda")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: 260)
    }
}
