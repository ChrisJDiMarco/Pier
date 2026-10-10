import AppKit
import SwiftUI

/// A borderless, non-activating panel at Dock level. Fully transparent pixels pass clicks through to the
/// windows beneath, so the window can be a full-width strip without blocking anything.
final class DockWindow: NSPanel {
    private let controller: DockController
    private let interaction: DockInteractionView
    private(set) var targetScreen: NSScreen?

    var isTrackingMenu: Bool { interaction.isShowingMenu }

    init(controller: DockController) {
        self.controller = controller
        self.interaction = DockInteractionView(controller: controller)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = NSView()
        root.wantsLayer = true
        let hosting = FirstMouseHostingView(rootView: DockRootView()
            .environmentObject(controller)
            .environmentObject(PierStore.shared)
            .environmentObject(RunningAppsService.shared)
            .environmentObject(BadgeService.shared)
            .environmentObject(IconService.shared))
        // The window's frame is set explicitly, so skip SwiftUI's size-constraint pass. Otherwise every
        // small update (a clock tick, the progress bar) re-measures the whole dock.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        interaction.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        root.addSubview(interaction)
        for view in [hosting, interaction] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func move(to screen: NSScreen) {
        targetScreen = screen
        reposition()
    }

    /// Sizes the window as a strip along the dock's edge of the target screen.
    func reposition() {
        let position = controller.position
        let screen: NSScreen? = {
            if controller.screenMode == .followMouse, let current = targetScreen, NSScreen.screens.contains(current) {
                return current
            }
            return NSScreen.screens.first
        }()
        guard let screen else { return }
        targetScreen = screen
        let f = screen.frame
        // Side docks need extra width for the hover labels drawn beside the icons.
        let depth = controller.metrics.windowDepth + (position.isVertical ? 200 : 0)
        let frame: CGRect
        switch position {
        case .bottom: frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: depth)
        case .left: frame = CGRect(x: f.minX, y: f.minY, width: depth, height: f.height)
        case .right: frame = CGRect(x: f.maxX - depth, y: f.minY, width: depth, height: f.height)
        }
        setFrame(frame, display: true)
        controller.setContainerSize(frame.size)
    }
}

/// Lets clicks reach SwiftUI controls (e.g. Now Playing buttons) without first activating Pier.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSPasteboard.PasteboardType {
    static let pierItem = NSPasteboard.PasteboardType("com.logicoutloud.pier.dock-item")
}
