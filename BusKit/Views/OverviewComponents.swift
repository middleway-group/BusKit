import SwiftUI
import Charts

// MARK: - Shared chart data models

struct MetricSample: Identifiable {
    let id = UUID()
    let series: String
    let timestamp: Date
    let value: Double
}

struct SeriesDef: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let color: Color
}

@available(macOS 15.0, *)
struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let toggle = { isExpanded.toggle() }
                if reduceMotion {
                    toggle()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toggle() }
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(reduceMotion ? nil : .spring(response: 0.3), value: isExpanded)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section, \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                content()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

@available(macOS 15.0, *)
struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 4)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10, bottomLeadingRadius: 10,
                            bottomTrailingRadius: 0, topTrailingRadius: 0
                        )
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 1)

                    Text(value)
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 90, maxWidth: 120, minHeight: 58, maxHeight: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit)")
        .onHover { inside in
            if !inside { NSCursor.arrow.set() }
        }
    }
}

@available(macOS 15.0, *)
struct MetricChartCard: View {
    let title: String
    let series: [SeriesDef]
    let samples: [MetricSample]

    private var timezoneLabel: String {
        let tz = TimeZone.current
        let seconds = tz.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let sign = hours >= 0 ? "+" : "-"
        if minutes == 0 {
            return "UTC\(sign)\(abs(hours))"
        }
        return String(format: "UTC%@%d:%02d", sign, abs(hours), minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            Chart {
                ForEach(series) { s in
                    ForEach(samples.filter { $0.series == s.key }) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(by: .value("Series", s.label))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: series.map(\.label),
                range: series.map(\.color)
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    AxisValueLabel()
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    AxisValueLabel()
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .frame(height: 220)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let frame = geo[proxy.plotAreaFrame]
                    Text(timezoneLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .position(x: frame.maxX - 22, y: frame.maxY - 10)
                }
            }
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            ChartLegend(series: series, samples: samples)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) chart")
    }
}

@available(macOS 15.0, *)
struct ChartLegend: View {
    let series: [SeriesDef]
    let samples: [MetricSample]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(series) { s in
                let total = samples.filter { $0.series == s.key }.reduce(0) { $0 + $1.value }
                HStack(spacing: 4) {
                    Circle()
                        .fill(s.color)
                        .frame(width: 8, height: 8)
                    Text(s.label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(formatMetricValue(total))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func formatMetricValue(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fk", value / 1_000) }
        return "\(Int(value))"
    }
}

@available(macOS 15.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
