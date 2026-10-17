import AppKit
import NightwardenCore
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: AboutView().environmentObject(model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "About \(AppInfo.name)"
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}

struct AboutView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text(AppInfo.name).font(.title.weight(.semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("A menu-bar watchdog that spots stuck macOS daemons and restarts them when you click.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            updateStatus
                .frame(minHeight: 28)

            HStack(spacing: 16) {
                Link("GitHub", destination: AppInfo.repositoryURL)
                Link("Release Notes", destination: AppInfo.releasesURL)
                Link("Report an Issue", destination: AppInfo.newIssueURL)
            }
            .font(.callout)

            Text(AppInfo.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 12)
        .frame(width: 360)
    }

    @ViewBuilder
    private var updateStatus: some View {
        if model.checkingForUpdates {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
            }
        } else if let update = model.availableUpdate {
            Button("Download \(update.version?.description ?? update.tagName)…") { model.showUpdateAction() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else {
            VStack(spacing: 4) {
                Button("Check for Updates") { model.checkForUpdatesAction() }
                if let last = model.lastUpdateCheck {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
