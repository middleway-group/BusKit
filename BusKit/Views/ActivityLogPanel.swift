import SwiftUI

// MARK: - Activity Log Panel

/// Xcode-console-style collapsible panel that slides up from the bottom of the
/// window (above the status bar). Shows a timestamped tabular history of all
/// user actions with colour-coded results and optional diagnostic hint rows.
@available(macOS 15.0, *)
struct ActivityLogPanel: View {
    @Environment(ActivityLogStore.self) var activityLog

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()

            if activityLog.entries.isEmpty {
                emptyState
            } else {
                logTable
            }
        }
        .frame(height: 200)
        // Blurred panel background — matches Xcode console / Safari Web Inspector.
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Activity Log")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            // Entry count badge
            if !activityLog.entries.isEmpty {
                Text("\(activityLog.entries.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            Spacer()

            // ── Severity summary ────────────────────────────────
            if activityLog.errorCount > 0 {
                severityPill(count: activityLog.errorCount, label: "error", color: .red)
            }
            if activityLog.warningCount > 0 {
                severityPill(count: activityLog.warningCount, label: "warning", color: .orange)
            }

            if activityLog.errorCount > 0 || activityLog.warningCount > 0 {
                Divider().frame(height: 12)
            }

            // ── Clear ───────────────────────────────────────────
            Button("Clear") {
                withAnimation(.easeOut(duration: 0.2)) { activityLog.clearLog() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .disabled(activityLog.entries.isEmpty)

            Divider().frame(height: 12)

            // ── Close ───────────────────────────────────────────
            Button {
                activityLog.toggleLog()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Activity Log (⌘⇧L)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No activity yet")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Log Table

    private var logTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                columnHeader
                Divider()

                ForEach(Array(activityLog.entries.enumerated()), id: \.element.id) { index, entry in
                    ActivityLogRow(entry: entry)
                    if index < activityLog.entries.count - 1 {
                        Divider()
                            .padding(.leading, 12)
                            .opacity(0.5)
                    }
                }
            }
        }
    }

    // MARK: - Column Header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Time")
                .frame(width: 86, alignment: .leading)
            Text("Action")
                .frame(width: 76, alignment: .leading)
            Text("Target")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Result")
                .frame(width: 220, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Helpers

    private func severityPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)\(count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Activity Log Row

@available(macOS 15.0, *)
private struct ActivityLogRow: View {
    let entry: ActivityLogEntry

    @State private var isHovered = false

    private var resultColor: Color {
        switch entry.result {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var resultIcon: String {
        switch entry.result {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Main data row ───────────────────────────────────
            HStack(spacing: 0) {

                // Time — monospaced so columns stay aligned
                Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .leading)

                // Action label
                Text(entry.action.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 76, alignment: .leading)

                // Target (message ID)
                Text(entry.target.isEmpty ? "—" : entry.target)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Result with icon
                HStack(spacing: 4) {
                    Image(systemName: resultIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(resultColor)
                    Text(entry.result.label)
                        .font(.system(size: 11))
                        .foregroundStyle(resultColor)
                        .lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isHovered ? Color.primary.opacity(0.04) : .clear)
            .onHover { isHovered = $0 }

            // ── Hint sub-row (errors only) ──────────────────────
            if let hint = entry.hint, entry.result.isError {
                HStack(spacing: 4) {
                    // Indent to align the hint text under the Result column.
                    Spacer().frame(width: 86 + 76 + 4)

                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
                .background(Color.red.opacity(0.04))
            }
        }
    }
}
