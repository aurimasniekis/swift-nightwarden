import Charts
import NightwardenCore
import SwiftUI

enum ChartRange: String, CaseIterable, Identifiable {
    case hour = "1 h", day = "24 h", week = "7 d", month = "30 d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

/// Event kinds drawn as vertical markers on the charts.
enum Marker: String, CaseIterable {
    case restarted, respawned, flagged

    var label: String {
        switch self {
        case .restarted: return "Restart"
        case .respawned: return "Respawn"
        case .flagged: return "Flagged"
        }
    }

    var color: Color {
        switch self {
        case .restarted: return Palette.good
        case .respawned: return Palette.serious
        case .flagged: return Palette.critical
        }
    }

    var dash: [CGFloat] {
        self == .flagged ? [2, 2] : []
    }
}

struct ServiceDetailView: View {
    let name: String
    @EnvironmentObject var model: AppModel
    @State private var range: ChartRange = .day
    @State private var points: [MetricPoint] = []
    @State private var markers: [MetricEvent] = []
    @State private var restartCount = 0
    @State private var footprint: UInt64?
    @State private var footprintPID: Int32?
    @State private var measuring = false
    @State private var windowEnd = Date()

    private var status: ServiceStatus? { model.status(named: name) }

    /// The selected range, trimmed to where data (or an event marker) actually starts.
    private var chartStart: Date {
        let rangeStart = windowEnd.addingTimeInterval(-range.seconds)
        let firstData = [points.first?.date, markers.map(\.date).min()].compactMap { $0 }.min()
        guard let firstData else { return rangeStart }
        // Keep at least a few minutes visible so a brand-new series isn't a single column.
        return max(rangeStart, min(firstData, windowEnd.addingTimeInterval(-300)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let status { stats(status) }
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                chartSection(title: "CPU", subtitle: cpuSubtitle) {
                    MetricChart(points: points, markers: markers, value: \.cpu, threshold: status?.rule.cpuPercent,
                                thresholdLabel: status.map { "\(Format.percent($0.rule.cpuPercent)) threshold" },
                                domain: chartStart...windowEnd, yFloor: 5,
                                format: { Format.percent($0) })
                }
                if status?.isEstimated == true {
                    Text("kernel_task is only visible to root, so its CPU is estimated (all host CPU minus every visible process) and its resident memory isn't sampled. Use Measure for its footprint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                chartSection(title: "Memory", subtitle: memorySubtitle) {
                    MetricChart(points: points, markers: markers, value: \.rss,
                                threshold: status?.rule.memoryLimitBytes.map(Double.init),
                                thresholdLabel: status?.rule.memoryLimitBytes.map { "\(Format.bytes($0)) limit" },
                                domain: chartStart...windowEnd, yFloor: 4 * 1024 * 1024,
                                format: { Format.bytes(UInt64(max(0, $0))) })
                }
                }
                legend
                if let status, status.instances.count > 1 { instanceTable(status) }
            }
            .padding(20)
        }
        .navigationTitle(name)
        .task(id: "\(range.rawValue)-\(model.metricsVersion)") { reload() }
    }

    // MARK: Header & stats

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(name).font(.largeTitle.weight(.semibold))
            if let status { StatusBadge(status: status) }
            Spacer()
            if let status, status.config.canRestart, status.instances.count == 1 {
                Button("Restart…") { model.restartAction(name, status.instances[0].pid) }
                    .controlSize(.large)
            } else if let status, !status.config.canRestart {
                Text("Watch-only").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func stats(_ status: ServiceStatus) -> some View {
        let primary = status.primary
        let peakCPU = points.map(\.cpuPeak).max()
        let peakRSS = points.map(\.rssPeak).max()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            if status.instances.count > 1 {
                StatTile(label: "Instances", value: "×\(status.instances.count)")
            } else {
                StatTile(label: "PID", value: primary.map { String($0.pid) } ?? "—")
            }
            StatTile(label: "Uptime", value: primary.map { Format.duration($0.uptime) } ?? "—")
            if let p = primary, !p.estimated {
                StatTile(label: "Lifetime CPU", value: Format.cpuTime(p.cpuSeconds),
                         detail: "\(Format.percent(Format.averageCPU(cpuSeconds: p.cpuSeconds, uptime: p.uptime))) avg")
            } else {
                StatTile(label: "Lifetime CPU", value: "—")
            }
            StatTile(label: "Peak CPU · \(range.rawValue)", value: peakCPU.map(Format.percent) ?? "—")
            StatTile(label: "Peak memory · \(range.rawValue)", value: peakRSS.map { Format.bytes(UInt64($0)) } ?? "—")
            footprintTile(primary)
            StatTile(label: "Restarts · 30 d", value: String(restartCount))
        }
    }

    private func footprintTile(_ primary: ProcSample?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Footprint").font(.caption).foregroundStyle(.secondary)
            if let footprint, footprintPID == primary?.pid {
                Text(Format.bytes(footprint)).font(.title3.monospacedDigit().weight(.medium))
            } else if measuring {
                ProgressView().controlSize(.small)
            } else {
                Button("Measure") { measure(primary) }
                    .disabled(primary == nil)
                    .help("Physical footprint from top(1); takes about a second")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func measure(_ sample: ProcSample?) {
        guard let pid = sample?.pid else { return }
        measuring = true
        Task {
            footprint = await Footprint.measure(pid: pid)
            footprintPID = pid
            measuring = false
        }
    }

    private var cpuSubtitle: String {
        guard let status else { return "" }
        return "Flagged at ≥ \(Format.percent(status.rule.cpuPercent)) for \(Format.duration(status.rule.cpuMinutes * 60))"
            + (status.instances.count > 1 ? " per instance · total of all instances shown" : "")
    }

    private var memorySubtitle: String {
        guard let status else { return "" }
        let limit = status.rule.memoryLimitBytes.map { "Flagged at ≥ \(Format.bytes($0)) resident" } ?? "No memory limit"
        return limit + (status.instances.count > 1 ? " per instance · total shown" : "")
    }

    // MARK: Charts

    private func chartSection<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content().frame(height: 200)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: Palette.series, dash: [], label: name)
            legendItem(color: Palette.rule, dash: [4, 3], label: "Threshold")
            ForEach(Marker.allCases, id: \.self) { m in
                legendItem(color: m.color, dash: m.dash, label: m.label, vertical: true)
            }
            Spacer()
            if range.seconds > MetricsStore.rawRangeLimit {
                Text("5-minute averages").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func legendItem(color: Color, dash: [CGFloat], label: String, vertical: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { p in
                if vertical {
                    p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 6, y: 12))
                } else {
                    p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: 16, y: 6))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
            .frame(width: vertical ? 12 : 16, height: 12)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func instanceTable(_ status: ServiceStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instances").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    ForEach(["PID", "UID", "CPU", "Memory", "Up", ""], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(status.instances) { p in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(String(p.pid))
                            if status.flaggedPIDs.contains(p.pid) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
                            }
                        }
                        Text(String(p.uid))
                        Text(p.cpuPercent.map(Format.percent) ?? "—")
                        Text(Format.bytes(p.rssBytes))
                        Text(Format.duration(p.uptime))
                        if status.config.canRestart {
                            Button("Restart…") { model.restartAction(name, p.pid) }.controlSize(.small)
                        } else {
                            Text("")
                        }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() {
        guard let metrics = model.metrics else { return }
        let now = Date()
        windowEnd = now
        let from = now.addingTimeInterval(-range.seconds)
        points = (try? metrics.series(service: name, from: from, to: now)) ?? []
        let events = (try? metrics.events(service: name, since: now.addingTimeInterval(-30 * 86_400))) ?? []
        markers = events.filter { $0.date >= from && Marker(rawValue: $0.kind) != nil }
        restartCount = events.filter { $0.kind == EventKind.restarted.rawValue }.count
    }
}

extension MetricPoint {
    /// Points tagged with a run index; a gap much longer than the usual spacing (service not running,
    /// Mac asleep) starts a new run so lines break instead of bridging it.
    static func segmented(_ points: [MetricPoint]) -> [(point: MetricPoint, segment: Int)] {
        let gaps = zip(points.dropFirst(), points).map { $0.date.timeIntervalSince($1.date) }.sorted()
        let typical = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let limit = max(typical * 3, 90)
        var segment = 0
        var previous: Date?
        return points.map { p in
            if let previous, p.date.timeIntervalSince(previous) > limit { segment += 1 }
            previous = p.date
            return (p, segment)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title3.monospacedDigit().weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One measure over time, a dashed threshold rule, event markers, and a hover crosshair.
struct MetricChart: View {
    let points: [MetricPoint]
    let markers: [MetricEvent]
    let value: KeyPath<MetricPoint, Double>
    let threshold: Double?
    let thresholdLabel: String?
    let domain: ClosedRange<Date>
    /// Smallest y-axis top, so near-zero series don't magnify noise.
    let yFloor: Double
    let format: (Double) -> String

    @State private var hover: Date?

    private var segments: [(point: MetricPoint, segment: Int)] { MetricPoint.segmented(points) }

    private var dataMax: Double { points.map { $0[keyPath: value] }.max() ?? 0 }

    /// Fit the data; pull the threshold into view only once the data gets within half of it.
    private var showsThreshold: Bool {
        guard let threshold else { return false }
        return dataMax >= threshold / 2
    }

    private var yMax: Double {
        let top = showsThreshold ? max(dataMax, threshold ?? 0) : dataMax
        return max(top * 1.15, yFloor)
    }

    private var hovered: MetricPoint? {
        guard let hover, !points.isEmpty else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hover)) < abs($1.date.timeIntervalSince(hover)) }
    }

    var body: some View {
        if points.isEmpty {
            Text("No samples in this range yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(segments, id: \.point.id) { item in
                LineMark(x: .value("Time", item.point.date), y: .value("Value", item.point[keyPath: value]),
                         series: .value("Segment", item.segment))
                    .foregroundStyle(Palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if showsThreshold, let threshold {
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(Palette.rule)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        if let thresholdLabel {
                            Text(thresholdLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
            }
            ForEach(markers) { e in
                if let m = Marker(rawValue: e.kind) {
                    RuleMark(x: .value("Event", e.date))
                        .foregroundStyle(m.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: m.dash))
                }
            }
            if let p = hovered {
                RuleMark(x: .value("Hover", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(p)
                    }
                PointMark(x: .value("Time", p.date), y: .value("Value", p[keyPath: value]))
                    .foregroundStyle(Palette.series)
                    .symbolSize(64)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(format(d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXSelection(value: $hover)
    }

    private func tooltip(_ p: MetricPoint) -> some View {
        let nearby = markers.filter { abs($0.date.timeIntervalSince(p.date)) < max(60, domain.upperBound.timeIntervalSince(domain.lowerBound) / 200) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            Text(format(p[keyPath: value])).font(.callout.monospacedDigit().weight(.semibold))
            if p.cpuPeak != p.cpu || p.rssPeak != p.rss {
                Text("peak \(format(value == \MetricPoint.cpu ? p.cpuPeak : p.rssPeak))").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(nearby) { e in
                Text("\(Marker(rawValue: e.kind)?.label ?? e.kind): \(e.detail)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
