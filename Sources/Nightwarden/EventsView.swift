import NightwardenCore
import SwiftUI

struct EventsView: View {
    @EnvironmentObject var model: AppModel
    @State private var events: [MetricEvent] = []
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\MetricEvent.date, order: .reverse)]

    private var services: [String] {
        Array(Set(model.config.services.map(\.name) + events.map(\.service))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Service", selection: $filter) {
                    Text("All services").tag("")
                    Divider()
                    ForEach(services, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Text("\(events.count) events · last 180 days").font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            Table(events.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Time", value: \.date) { e in
                    Text(e.date.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                }
                .width(min: 150, ideal: 170)
                TableColumn("Service", value: \.service)
                    .width(min: 90, ideal: 120)
                TableColumn("PID", value: \.pidSortKey) { e in
                    Text(e.pid.map(String.init) ?? "—").monospacedDigit()
                }
                .width(min: 50, ideal: 70)
                TableColumn("Event", value: \.kind) { e in
                    Text(Self.label(e.kind))
                }
                .width(min: 90, ideal: 130)
                TableColumn("Detail", value: \.detail) { e in
                    Text(e.detail).help(e.detail)
                }
            }
        }
        .navigationTitle("Events")
        .task(id: "\(filter)-\(model.metricsVersion)") { reload() }
    }

    private func reload() {
        events = (try? model.metrics?.events(service: filter.isEmpty ? nil : filter,
                                             since: Date().addingTimeInterval(-MetricsStore.eventRetention))) ?? []
    }

    static func label(_ kind: String) -> String {
        switch EventKind(rawValue: kind) {
        case .flagged: return "Flagged"
        case .notified: return "Notified"
        case .snoozed: return "Snoozed"
        case .ignored: return "Ignored"
        case .cleared: return "Cleared"
        case .respawned: return "Respawned"
        case .restartRequested: return "Restart requested"
        case .restarted: return "Restarted"
        case .restartCancelled: return "Restart cancelled"
        case .restartFailed: return "Restart failed"
        case nil: return kind
        }
    }
}
