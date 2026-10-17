import AppKit
import NightwardenCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("General") { GeneralSettings() }
            Section("Services") { ServicesSettings() }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { model.refreshNotificationStatusAction() }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    private var paused: Binding<Bool> {
        Binding(get: { model.config.alertsPaused(at: Date()) },
                set: { $0 ? model.pauseAlertsIndefinitely() : model.pauseAlerts(for: nil) })
    }

    var body: some View {
        LabeledContent("Poll interval") {
            HStack {
                TextField("Poll interval", value: $model.config.pollSeconds, format: .number).labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $model.config.pollSeconds, in: Config.pollRange, step: 5).labelsHidden()
                Text("seconds (10–300)").foregroundStyle(.secondary)
            }
        }
        LabeledContent("Default stuck rule") {
            HStack {
                Text("CPU ≥")
                TextField("Default CPU %", value: $model.config.defaultCPUPercent, format: .number).labelsHidden()
                    .frame(width: 60).multilineTextAlignment(.trailing)
                Text("% for")
                TextField("Default minutes", value: $model.config.defaultCPUMinutes, format: .number).labelsHidden()
                    .frame(width: 50).multilineTextAlignment(.trailing)
                Text("minutes")
            }
        }
        LabeledContent("Re-notify every") {
            HStack {
                TextField("Re-notify minutes", value: $model.config.renotifyMinutes, format: .number).labelsHidden()
                    .frame(width: 60).multilineTextAlignment(.trailing)
                Text("minutes while still stuck")
            }
        }
        Toggle(isOn: paused) {
            Text("Pause alerts")
            if let until = model.config.pausedUntil, until > Date(), until != .distantFuture {
                Text("Until \(until.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        LabeledContent("Notifications") {
            HStack {
                Text(statusText).foregroundStyle(model.notificationStatus == .denied ? Palette.critical : .secondary)
                Button("Send Test Notification") { model.testNotificationAction() }
                Button("Open Notification Settings") { openNotificationSettings() }
            }
        }
        Text("Choose the **Alerts** style in Notification Settings so stuck warnings stay on screen until you act on them.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch model.notificationStatus {
        case .authorized: return "Allowed"
        case .provisional: return "Delivered quietly"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not requested yet"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "lt.niekis.nightwarden"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ServicesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<ServiceConfig.ID>()
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.config.services, selection: $selection) {
                TableColumn("On") { svc in
                    Toggle("", isOn: binding(svc.id).enabled).labelsHidden()
                }
                .width(28)
                TableColumn("Name") { svc in
                    TextField("Name", text: binding(svc.id).name, prompt: Text("process name"))
                        .labelsHidden()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Restartable") { svc in
                    restartableCell(svc)
                }
                .width(80)
                TableColumn("CPU %") { svc in
                    TextField("CPU %", value: binding(svc.id).cpuPercent, format: .number,
                              prompt: Text(Self.number(model.config.defaultCPUPercent)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                .width(60)
                TableColumn("Minutes") { svc in
                    TextField("Minutes", value: binding(svc.id).cpuMinutes, format: .number,
                              prompt: Text(Self.number(model.config.defaultCPUMinutes)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                .width(60)
                TableColumn("Memory limit (MB)") { svc in
                    TextField("Memory limit", value: binding(svc.id).memoryLimitMB, format: .number.grouping(.never),
                              prompt: Text("none"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                .width(min: 90, ideal: 110)
            }
            .frame(minHeight: 380)

            HStack(spacing: 4) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Add a service")
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                    .help("Remove the selected services")
                Spacer()
                Text("Blank CPU fields use the default rule. Changes apply on the next check.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults") { model.config.services = Config.defaultServices }
            }
        }
        .sheet(isPresented: $adding) {
            AddServiceSheet { name in
                guard !name.isEmpty else { return }
                model.config.services.append(ServiceConfig(name: name, restartable: false))
            }
        }
    }

    @ViewBuilder
    private func restartableCell(_ svc: ServiceConfig) -> some View {
        if svc.isProtected {
            HStack(spacing: 4) {
                Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
            }
            .help("\(svc.name) is never restarted")
        } else {
            Toggle("", isOn: binding(svc.id).restartable).labelsHidden()
        }
    }

    private func binding(_ id: UUID) -> Binding<ServiceConfig> {
        Binding(
            get: { model.config.services.first { $0.id == id } ?? ServiceConfig(name: "", restartable: false) },
            set: { new in
                if let i = model.config.services.firstIndex(where: { $0.id == id }) { model.config.services[i] = new }
            })
    }

    private func remove() {
        model.config.services.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private static func number(_ v: Double) -> String {
        v.formatted(.number)
    }
}

struct AddServiceSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var running: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Service").font(.headline)
            Text("Process name as shown by ps (the executable's basename).")
                .font(.caption).foregroundStyle(.secondary)
            ComboBox(items: running, text: $name)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .task {
            let rows = await ProcessList.snapshotAsync() ?? []
            running = Array(Set(rows.map(\.name))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }
}

/// NSComboBox: free text plus a list of suggestions.
struct ComboBox: NSViewRepresentable {
    var items: [String]
    @Binding var text: String

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 15
        box.placeholderString = "e.g. fseventsd"
        box.delegate = context.coordinator
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        if context.coordinator.items != items {
            context.coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text { box.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var items: [String] = []

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            if let box = note.object as? NSComboBox { text.wrappedValue = box.stringValue }
        }

        func comboBoxSelectionDidChange(_ note: Notification) {
            if let box = note.object as? NSComboBox, let value = box.objectValueOfSelectedItem as? String {
                text.wrappedValue = value
            }
        }
    }
}
