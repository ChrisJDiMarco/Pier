import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OnboardingView { [weak self] in self?.finish() }
                .environmentObject(PierStore.shared)
                .environmentObject(Permissions.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if window?.isVisible != true { Permissions.shared.beginWatching() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        PierStore.shared.settings.didOnboard = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        PierStore.shared.settings.didOnboard = true
        Permissions.shared.endWatching()
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                Text("Welcome to Pier").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Your apps from the macOS Dock are already here. Drag one app onto another to make a folder, right-click the dock to add widgets, and make it yours in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 4) {
                PermissionRow(title: "Accessibility", symbol: "accessibility",
                              detail: "For notification badges and jumping to specific windows.",
                              granted: permissions.accessibility) { permissions.requestAccessibility() }
                Divider()
                PermissionRow(title: "Screen Recording", symbol: "rectangle.dashed.badge.record",
                              detail: "For live window previews when you hover an app.",
                              granted: permissions.screenRecording) { permissions.requestScreenRecording() }
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "dock.arrow.down.rectangle").font(.system(size: 20)).frame(width: 28)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hide the macOS Dock").font(.system(size: 13, weight: .semibold))
                        Text("So only Pier is on screen. Fully reversible from the menu bar icon.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $store.settings.hideSystemDock).toggleStyle(.switch).labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))

            Button(action: onDone) {
                Text("Get Started").frame(width: 180)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 560)
    }
}
