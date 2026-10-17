import AppKit
import Charts
import NightwardenCore
import SwiftUI

/// Chart and status colors (dataviz reference palette), stepped separately for light and dark.
enum Palette {
    static let series = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let rule = dynamic(light: 0x52514E, dark: 0xC3C2B7)
    static let good = fixed(0x0CA30C)
    static let warning = fixed(0xFAB219)
    static let serious = fixed(0xEC835A)
    static let critical = fixed(0xD03B3B)

    static func fixed(_ hex: UInt32) -> Color { Color(nsColor: nsColor(hex)) }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Status is never color alone: icon + label + color.
struct StatusBadge: View {
    let status: ServiceStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
    }

    private var text: String {
        guard status.isRunning else { return "Not running" }
        switch status.health {
        case .ok: return "OK"
        case .elevated: return "Elevated"
        case .flagged: return "Stuck"
        }
    }

    private var icon: String {
        guard status.isRunning else { return "minus.circle.fill" }
        switch status.health {
        case .ok: return "checkmark.circle.fill"
        case .elevated: return "exclamationmark.circle.fill"
        case .flagged: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        guard status.isRunning else { return .secondary }
        switch status.health {
        case .ok: return Palette.good
        case .elevated: return Palette.warning
        case .flagged: return Palette.critical
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var sparklines: [String: [MetricPoint]] = [:]
    @State private var restarts: [String: Int] = [:]

    private var sorted: [ServiceStatus] {
        model.statuses.sorted {
            ($0.health, $0.isRunning ? 1 : 0, $0.cpuTotal) > ($1.health, $1.isRunning ? 1 : 0, $1.cpuTotal)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(sorted) { status in
                        Button {
                            model.selection = .service(status.name)
                        } label: {
                            ServiceCard(status: status, points: sparklines[status.name] ?? [],
                                        restarts: restarts[status.name] ?? 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .task(id: model.metricsVersion) { reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            let flagged = model.statuses.filter { $0.health == .flagged }.count
            Text(flagged == 0 ? "All watched services look healthy" : "\(flagged) service\(flagged == 1 ? "" : "s") look stuck")
                .font(.title2.weight(.semibold))
            Spacer()
            if let last = model.lastCheck {
                Text("Last check \(last.formatted(date: .omitted, time: .standard))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Check Now") { model.checkNowAction() }
        }
    }

    private func reload() {
        guard let metrics = model.metrics else { return }
        let now = Date()
        // Autoscale the bucket to the history available: ~72 points, from one poll up to 15 minutes.
        let since = now.addingTimeInterval(-86_400)
        let span = (try? metrics.oldestSample(since: since)).flatMap { $0 }.map { now.timeIntervalSince($0) } ?? 86_400
        let bucket = Int(min(max(span / 72, model.config.pollSeconds), 900))
        sparklines = (try? metrics.sparklines(since: since, bucket: bucket)) ?? [:]
        restarts = (try? metrics.eventCounts(.restarted, since: now.addingTimeInterval(-30 * 86_400))) ?? [:]
    }
}

struct ServiceCard: View {
    let status: ServiceStatus
    let points: [MetricPoint]
    let restarts: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                StatusBadge(status: status)
            }
            // Always three equal columns so every card has the same shape.
            HStack(alignment: .top, spacing: 12) {
                metric(status.cpuKnown ? Format.percent(status.cpuTotal) : "—", "CPU")
                metric(status.isRunning && !status.isEstimated ? Format.bytes(status.rssTotal) : "—", "memory")
                if status.instances.count > 1 {
                    metric("×\(status.instances.count)", "instances")
                } else {
                    metric(status.instances.first.map { Format.duration($0.uptime) } ?? "—", "uptime")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Sparkline(points: points)
                    .frame(height: 34)
                HStack {
                    Text("CPU, last \(Sparkline.spanLabel(points))")
                    Spacer()
                    Text(restarts == 0 ? "No restarts in 30 d" : "\(restarts) restart\(restarts == 1 ? "" : "s") in 30 d")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(status.health == .flagged ? Palette.critical : Color.secondary.opacity(0.15),
                              lineWidth: status.health == .flagged ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Sparkline: View {
    let points: [MetricPoint]

    var body: some View {
        if points.count < 2 {
            Text("Collecting data…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(MetricPoint.segmented(points), id: \.point.id) { item in
                LineMark(x: .value("Time", item.point.date), y: .value("CPU", item.point.cpu),
                         series: .value("Segment", item.segment))
                    .foregroundStyle(Palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                AreaMark(x: .value("Time", item.point.date), y: .value("CPU", item.point.cpu),
                         series: .value("Segment", item.segment))
                    .foregroundStyle(Palette.series.opacity(0.12))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(10, points.map(\.cpu).max() ?? 0))
            .chartXScale(domain: Self.start(points)...Date())
        }
    }

    /// Up to 24 h back, but no earlier than the first sample, so young history isn't squashed into a sliver.
    static func start(_ points: [MetricPoint]) -> Date {
        max(Date().addingTimeInterval(-86_400), points.first?.date ?? .distantPast)
    }

    static func spanLabel(_ points: [MetricPoint]) -> String {
        let span = Date().timeIntervalSince(start(points))
        return span >= 86_000 || points.count < 2 ? "24 h" : Format.duration(span)
    }
}
