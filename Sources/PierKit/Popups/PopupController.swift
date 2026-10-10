import AppKit
import SwiftUI

enum PopupKind: Equatable {
    case folder(UUID)
    case stack(UUID)
    case windows(String)   // dock entry id
    case widget(UUID)
}

final class PopupPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Shows one floating popup at a time, anchored to a dock tile, and dismisses it on outside clicks,
/// Escape, or (for hover previews) when the pointer leaves both the tile and the popup.
@MainActor
final class PopupController {
    static let shared = PopupController()

    private var panel: PopupPanel?
    private(set) var kind: PopupKind?
    private var hoverOwned = false
    private var anchor: CGRect = .zero
    private var position: DockPosition = .bottom
    private var isCentered = false
    private var monitors: [Any] = []
    private var leaveWork: DispatchWorkItem?
    private let gap: CGFloat = 10
    static let shadowInset: CGFloat = 24
    private let leaveGrace: TimeInterval = 0.35

    private init() {}

    var isShowing: Bool { panel != nil }
    var isShowingWindows: Bool { if case .windows = kind { return true }; return false }
    func isShowing(_ k: PopupKind) -> Bool { kind == k }

    func show(_ kind: PopupKind, anchor: CGRect, position: DockPosition, theme: Theme,
              hoverOwned: Bool = false, chrome: Bool = true, content: () -> AnyView) {
        dismiss(animated: false)
        let view = content()
        let wrapped: AnyView = chrome
            ? AnyView(PopupChrome(theme: theme) { view })
            : AnyView(view.padding(Self.shadowInset))
        let hosting = FirstMouseHostingView(rootView: wrapped)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize

        let panel = PopupPanel(contentRect: CGRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.allowsKey = !hoverOwned
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.appearance = theme.appearance
        panel.setFrame(frame(size: size, anchor: anchor, position: position), display: true)
        panel.alphaValue = 0

        self.panel = panel
        self.kind = kind
        self.hoverOwned = hoverOwned
        self.anchor = anchor
        self.position = position
        self.isCentered = false
        if hoverOwned { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        ClickLog.log.notice("popup shown \(String(describing: kind), privacy: .public) size=\(Int(size.width))x\(Int(size.height))")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// A full-screen, Launchpad-style presentation: content centered over a blurred, dimmed screen.
    /// Clicking the backdrop or pressing Escape closes it.
    func showCentered(_ kind: PopupKind, on screen: NSScreen?, theme: Theme, content: () -> AnyView) {
        dismiss(animated: false)
        guard let screen = screen ?? NSScreen.main else { return }
        let view = content()
        let hosting = FirstMouseHostingView(rootView: AnyView(LaunchpadContainer(theme: theme) { view }))
        hosting.sizingOptions = []
        let panel = PopupPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // The blur must be the window's own content view (not embedded in SwiftUI) for macOS to blur the
        // windows behind it.
        let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        panel.contentView = blur
        panel.appearance = theme.appearance
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        self.panel = panel
        self.kind = kind
        self.hoverOwned = false
        self.isCentered = true
        panel.makeKeyAndOrderFront(nil)
        ClickLog.log.notice("popup shown \(String(describing: kind), privacy: .public) centered")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// Keeps the popup sized to its content (e.g. when thumbnails load or a folder loses an app).
    func contentSizeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCentered, let panel = self.panel, let hosting = panel.contentView else { return }
            let target = self.frame(size: hosting.fittingSize, anchor: self.anchor, position: self.position)
            if target != panel.frame { panel.setFrame(target, display: true, animate: false) }
        }
    }

    func dismiss(animated: Bool = true) {
        leaveWork?.cancel()
        leaveWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let panel else { return }
        ClickLog.log.notice("popup dismissed \(String(describing: self.kind), privacy: .public)")
        self.panel = nil
        kind = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
    }

    /// Called every frame by the dock controller.
    func trackPointer(_ mouse: CGPoint, dockHoveredID: String?) {
        guard hoverOwned, let panel, case .windows(let owner) = kind else { return }
        let inside = panel.frame.insetBy(dx: -gap, dy: -gap).contains(mouse) || dockHoveredID == owner
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
        } else if leaveWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            leaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + leaveGrace, execute: work)
        }
    }

    private func frame(size: CGSize, anchor: CGRect, position: DockPosition) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = (screen?.frame ?? .zero).insetBy(dx: 8, dy: 8)
        let inset = Self.shadowInset
        var origin: CGPoint
        switch position {
        case .bottom: origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap - inset)
        case .left: origin = CGPoint(x: anchor.maxX + gap - inset, y: anchor.midY - size.height / 2)
        case .right: origin = CGPoint(x: anchor.minX - gap + inset - size.width, y: anchor.midY - size.height / 2)
        }
        origin.x = origin.x.clamped(bounds.minX, max(bounds.minX, bounds.maxX - size.width))
        origin.y = origin.y.clamped(bounds.minY, max(bounds.minY, bounds.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            let isKey = event.type == .keyDown
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isEscape { self.dismiss(); return true }
                if isKey { return false }
                let inPopup = windowNumber == self.panel?.windowNumber
                let inDock = NSApp.windows.contains { $0 is DockWindow && $0.windowNumber == windowNumber }
                if !inPopup && !inDock { self.dismiss() }
                return false
            }
            return swallow ? nil : event
        }) {
            monitors.append(local)
        }
    }
}

/// Shared glass chrome for all popups.
struct PopupChrome<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(
                DockBackground(theme: theme.popupBackdrop, radius: 22)
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                PopupController.shared.contentSizeChanged()
            }
            .padding(PopupController.shadowInset)   // room for the shadow
    }

}

extension Theme {
    /// Popups need a readable backdrop even when the dock itself is fully clear: a smoky glass behind
    /// light text, a milky one behind dark text.
    var popupBackdrop: Theme {
        var t = self
        if t.background == .none || t.background == .clearGlass { t.background = .liquidGlass }
        switch prefersDarkAppearance {
        case true?:
            t.tint = "#000000"
            t.tintOpacity = 0.32
        case false?:
            t.tint = "#FFFFFF"
            t.tintOpacity = max(0.3, tintOpacity)
        case nil:
            t.tintOpacity = max(t.tintOpacity, 0.1)
        }
        return t
    }
}

/// Full-screen backdrop for the Launchpad-style folder: blurs and dims everything behind it.
struct LaunchpadContainer<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: () -> Content
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { PopupController.shared.dismiss() }
            content()
                .fixedSize()
                .padding(36)
                .background(DockBackground(theme: theme.popupBackdrop, radius: 36))
                .scaleEffect(appeared ? 1 : 0.88)
                .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { appeared = true } }
    }
}
