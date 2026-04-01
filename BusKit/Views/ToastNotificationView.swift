import SwiftUI

// MARK: - Toast Overlay Container

/// Positions all active toast notifications in the top-trailing corner of its
/// parent. Inject above the detail content area in ContentView.
@available(macOS 15.0, *)
struct ToastOverlay: View {
    @Environment(ActivityLogStore.self) var activityLog

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(activityLog.toasts) { toast in
                ToastNotificationView(toast: toast) {
                    activityLog.dismissToast(id: toast.id)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    )
                )
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.trailing, 16)
        // Allow pointer events through empty space so table/body remain interactive.
        .allowsHitTesting(!activityLog.toasts.isEmpty)
        .animation(
            .spring(response: 0.35, dampingFraction: 0.85),
            value: activityLog.toasts.map(\.id)
        )
    }
}

// MARK: - Single Toast Notification

@available(macOS 15.0, *)
struct ToastNotificationView: View {
    let toast    : ToastItem
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    // MARK: - Derived

    private var accentColor: Color {
        switch toast.result {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var iconName: String {
        switch toast.result {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // ── Header row ──────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(toast.action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Timestamp
                Text(toast.timestamp, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0.6)
                .help("Dismiss")
            }

            // ── Message ID pill ─────────────────────────────────
            if !toast.messageId.isEmpty {
                HStack(spacing: 4) {
                    Text("ID")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(toast.messageId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // ── Result message ──────────────────────────────────
            Text(toast.result.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // ── Optional details link ───────────────────────────
            if let details = toast.details {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                    Text("Details")
                        .font(.system(size: 10))
                }
                .foregroundStyle(accentColor)
                .help(details)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                // Vibrancy / material background
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)

                // Colored left-edge accent stripe
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12),
            radius: 8, x: 0, y: 3
        )
        .onHover { isHovered = $0 }
    }
}
