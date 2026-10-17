import AppKit
import NightwardenCore
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: MainView().environmentObject(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Nightwarden"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NightwardenMain")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Shows the window (activating the app while it's open) and optionally navigates.
    func show(_ item: SidebarItem?) {
        if let item { model.selection = item }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
                Section("Services") {
                    ForEach(model.statuses) { status in
                        HStack(spacing: 6) {
                            Text(status.name)
                                .foregroundStyle(status.isRunning ? .primary : .secondary)
                            Spacer()
                            if status.health == .flagged {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Palette.critical)
                                    .help("Looks stuck")
                            }
                        }
                        .tag(SidebarItem.service(status.name))
                    }
                }
                Section {
                    Label("Events", systemImage: "list.bullet.rectangle").tag(SidebarItem.events)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch model.selection ?? .overview {
            case .overview: DashboardView()
            case .service(let name): ServiceDetailView(name: name).id(name)
            case .events: EventsView()
            case .settings: SettingsView()
            }
        }
    }
}
