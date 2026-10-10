import AppKit
import Combine
import SwiftUI
import os

enum DragLog {
    static let log = Logger(subsystem: "com.logicoutloud.Pier", category: "drag")
}

/// One visual slot in the dock.
public struct DisplayEntry: Identifiable, Equatable {
    public enum Kind: Equatable {
        case item(DockItem)
        case running(RunningApp)
        case minimized(MinimizedWindow)
        /// An app shown inline while its folder is expanded in the dock.
        case folderApp(UUID, AppRef)
        case divider
        case gap
    }

    public let id: String
    public let kind: Kind

    public var appRef: AppRef? {
        switch kind {
        case .item(let item): return item.appRef
        case .running(let app): return app.ref
        case .folderApp(_, let ref): return ref
        default: return nil
        }
    }

    public var dockItem: DockItem? {
        if case .item(let item) = kind { return item }
        return nil
    }

    public var title: String {
        switch kind {
        case .item(let item): return item.displayName
        case .running(let app): return app.ref.name
        case .folderApp(_, let ref): return ref.name
        case .minimized(let w): return w.title
        default: return ""
        }
    }

    var elementKind: ElementKind {
        switch kind {
        case .divider: return .divider
        case .gap: return .gap
        case .running, .minimized, .folderApp: return .icon
        case .item(let item):
            switch item.content {
            case .widget(let w): return .widget(w)
            case .separator: return .divider
            default: return .icon
            }
        }
    }

    static func runningID(_ ref: AppRef) -> String { "run:\(ref.key)" }
    static func minimizedID(_ w: MinimizedWindow) -> String { "min:\(w.id)" }
    static func folderAppID(_ folder: UUID, _ ref: AppRef) -> String { "fapp:\(folder.uuidString):\(ref.key)" }
    static let dividerID = "divider:trailing"
    static let gapID = "gap"
}

enum DragPayload {
    case item(UUID)
    case running(AppRef)
    case files([URL])
}

@MainActor
public final class DockController: ObservableObject {
    public static let shared = DockController()

    @Published public private(set) var entries: [DisplayEntry] = []
    @Published public private(set) var geometry: DockGeometry = .empty
    @Published public private(set) var hoveredID: String?
    @Published public var pressedID: String?
    @Published public var pressedControl: NowPlayingControl?
    @Published public internal(set) var dropOntoID: String?
    @Published public private(set) var isRevealed = true
    @Published public private(set) var isHovering = false
    /// The folder currently expanded inline in the dock, if any.
    @Published public private(set) var expandedFolderID: UUID?

    let store = PierStore.shared
    let running = RunningAppsService.shared
    weak var window: DockWindow?

    private(set) var metrics = DockMetrics(theme: .liquid, magnification: 1)
    /// Copies of the placement settings, taken from the publisher's new value. Reading `store.settings`
    /// inside a `@Published` sink can still return the old value.
    private(set) var position: DockPosition = .bottom
    private(set) var screenMode: ScreenMode = .primary
    private(set) var containerSize: CGSize = .zero
    private var motion = MagnificationMotion()
    private var frameDriver: FrameDriver?
    var draggingPayload: DragPayload?
    var dragGap: DropTarget?
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var tickTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastEdgeHit = Date.distantPast
    private var placement: (DockPosition, ScreenMode)?
    private var collapseMonitor: Any?

    private init() {}

    public func start() {
        Publishers.CombineLatest4(store.$layout, store.$settings, running.$apps, MinimizedWindowsService.shared.$windows)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildEntries(animated: true) }
            .store(in: &bag)
        store.$settings.map(\.showMinimizedWindows).removeDuplicates()
            .sink { show in if show { MinimizedWindowsService.shared.start() } else { MinimizedWindowsService.shared.stop() } }
            .store(in: &bag)
        Publishers.CombineLatest(store.$theme, store.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] theme, settings in self?.applyAppearance(theme: theme, settings: settings) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.window?.reposition() }
            .store(in: &bag)

        // Per-frame work runs off the display's refresh (120 Hz on ProMotion) while the pointer is near
        // the dock. Otherwise a 20 Hz timer handles auto-hide edges and wakes the display link.
        if let view = window?.contentView {
            frameDriver = FrameDriver(view: view) { [weak self] dt in
                MainActor.assumeIsolated { self?.tick(dt: dt) }
            }
        }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Called by the dock's tracking area the moment the pointer reaches it, and by the idle timer.
    func wakeIfNear() {
        guard let window, frameDriver?.isRunning == false else { return }
        if window.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { frameDriver?.resume() }
    }

    private func idleTick() {
        guard frameDriver?.isRunning != true else { return }
        wakeIfNear()
        if frameDriver?.isRunning != true { tick(dt: 1.0 / 20.0) }
    }

    var settings: PierSettings { store.settings }
    var theme: Theme { store.theme }

    // MARK: Entries & geometry

    func rebuildEntries(animated: Bool) {
        let layout = store.layout
        let draggedID: UUID? = { if case .item(let id) = draggingPayload { return id }; return nil }()
        let draggedRunning: AppRef? = { if case .running(let r) = draggingPayload { return r }; return nil }()

        var list: [DisplayEntry] = layout.main
            .filter { $0.id != draggedID }
            .flatMap { item -> [DisplayEntry] in
                let tile = DisplayEntry(id: item.id.uuidString, kind: .item(item))
                // An inline-expanded folder unfolds its apps right after its tile.
                guard item.id == expandedFolderID, let folder = item.folder else { return [tile] }
                return [tile] + folder.apps.map {
                    DisplayEntry(id: DisplayEntry.folderAppID(item.id, $0), kind: .folderApp(item.id, $0))
                }
            }

        if settings.showRunningApps {
            let extras = running.apps.filter { app in
                !layout.isPinned(app.ref) && !(draggedRunning?.matches(app.ref) ?? false)
            }
            // Running apps join the apps, right after the last app or folder, ahead of any widgets.
            let lastApp = list.lastIndex { entry in
                guard case .item(let item) = entry.kind else { return false }
                return item.appRef != nil || item.folder != nil
            }
            let insertAt = lastApp.map { $0 + 1 } ?? 0
            list.insert(contentsOf: extras.map { DisplayEntry(id: DisplayEntry.runningID($0.ref), kind: .running($0)) },
                        at: insertAt)
        }

        let trailing = layout.trailing.filter { $0.id != draggedID }
        // Minimized windows sit right after the divider, before stacks and the Trash (as in the macOS Dock).
        let minimized = settings.showMinimizedWindows ? MinimizedWindowsService.shared.windows : []
        if !trailing.isEmpty || !minimized.isEmpty {
            list.append(DisplayEntry(id: DisplayEntry.dividerID, kind: .divider))
            list += minimized.map { DisplayEntry(id: DisplayEntry.minimizedID($0), kind: .minimized($0)) }
            list += trailing.map { DisplayEntry(id: $0.id.uuidString, kind: .item($0)) }
        }

        if let gap = dragGap, case .insert(let before) = gap {
            let index = before.flatMap { id in list.firstIndex { $0.id == id } } ?? list.count
            list.insert(DisplayEntry(id: DisplayEntry.gapID, kind: .gap), at: index)
        }

        if let expanded = expandedFolderID, layout.allItems.first(where: { $0.id == expanded })?.folder == nil {
            expandedFolderID = nil
            installCollapseMonitor(false)
        }
        guard list != entries else { return }
        if animated && settings.animationsEnabled {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                entries = list
                recomputeGeometry()
            }
        } else {
            entries = list
            recomputeGeometry()
        }
    }

    private func applyAppearance(theme: Theme, settings: PierSettings) {
        window?.appearance = theme.appearance
        let next = DockMetrics(theme: theme, magnification: settings.magnification ? settings.magnificationScale : 1)
        let moved = placement.map { $0.0 != settings.position || $0.1 != settings.screenMode } ?? true
        let changed = next != metrics || moved
        metrics = next
        placement = (settings.position, settings.screenMode)
        position = settings.position
        screenMode = settings.screenMode
        if changed { window?.reposition() }
        recomputeGeometry()
    }

    func setContainerSize(_ size: CGSize) {
        guard size != containerSize else { return }
        containerSize = size
        recomputeGeometry()
    }

    private func recomputeGeometry() {
        let elements = entries.map { LayoutElement(id: $0.id, kind: $0.elementKind) }
        // Magnification strength follows the spring; the wave is centered on the smoothed pointer.
        var frameMetrics = metrics
        frameMetrics.magnification = 1 + (metrics.magnification - 1) * motion.amount
        let pointer = motion.amount > 0 ? motion.along.map { a in
            position.isVertical ? CGPoint(x: 0, y: a) : CGPoint(x: a, y: 0)
        } : nil
        let next = DockLayoutEngine.layout(elements: elements, metrics: frameMetrics, position: position,
                                           container: containerSize, pointer: pointer)
        if next != geometry { geometry = next }
    }

    func entry(_ id: String) -> DisplayEntry? { entries.first { $0.id == id } }

    // MARK: Inline folders

    func setExpandedFolder(_ id: UUID?) {
        guard id != expandedFolderID else { return }
        ClickLog.log.notice("inline folder \(id?.uuidString ?? "collapsed", privacy: .public)")
        expandedFolderID = id
        installCollapseMonitor(id != nil)
        rebuildEntries(animated: true)
    }

    private func installCollapseMonitor(_ on: Bool) {
        if let collapseMonitor { NSEvent.removeMonitor(collapseMonitor) }
        collapseMonitor = nil
        guard on else { return }
        // A click in another app folds the folder back up; clicks in the dock are handled by the dock.
        collapseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.setExpandedFolder(nil) }
        }
    }

    // MARK: Pointer tracking (polled so it also works during drags and over transparent areas)

    private func tick(dt: CGFloat) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let p = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let inWindow = frame.contains(mouse)
        let inside = inWindow && isRevealed && geometry.isInHoverZone(p, alreadyHovering: isHovering)
        let popupOpen = PopupController.shared.isShowing

        if inside != isHovering { isHovering = inside }
        let before = motion
        let target = inside && !popupOpen && metrics.magnification > 1 ? geometry.along(p) : nil
        motion.step(dt: settings.animationsEnabled ? dt : 1, pointer: target)
        if motion != before { recomputeGeometry() }

        let hit = inside ? geometry.hit(p, spacing: metrics.spacing)?.id : nil
        if hit != hoveredID {
            hoveredID = hit
            hoverChanged()
        }

        handleAutoHide(mouse: mouse, inside: inside)
        handleScreenFollow(mouse: mouse)
        PopupController.shared.trackPointer(mouse, dockHoveredID: hoveredID)

        // Nothing left to animate and the pointer is away: stop the display link until it comes back.
        let nearby = frame.insetBy(dx: -24, dy: -24).contains(mouse)
        if !nearby && motion.isSettled && draggingPayload == nil { frameDriver?.pause() }
    }

    private func handleAutoHide(mouse: CGPoint, inside: Bool) {
        guard settings.autoHide else {
            if !isRevealed { setRevealed(true) }
            return
        }
        let resting = isRevealed && (window?.targetScreen.map { atEdge(mouse, of: $0) } ?? false)
        // Like the macOS Dock, an auto-hidden dock slides up while an app is asking for attention.
        let attention = AttentionService.shared
        let wantsAttention = !attention.bouncing.isEmpty || !attention.messages.isEmpty
        let presenting = PopupController.shared.isShowing || expandedFolderID != nil
        let busy = inside || resting || wantsAttention || presenting || draggingPayload != nil
            || window?.isTrackingMenu == true
        if busy {
            hideWork?.cancel()
            hideWork = nil
            if !isRevealed && (inside || wantsAttention || presenting) { setRevealed(true) }
            return
        }
        if !isRevealed, let screen = window?.targetScreen, atEdge(mouse, of: screen) {
            setRevealed(true)
            return
        }
        if isRevealed && hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.hideWork = nil
                self?.setRevealed(false)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, settings.autoHideDelay), execute: work)
        }
    }

    private func atEdge(_ mouse: CGPoint, of screen: NSScreen) -> Bool {
        let f = screen.frame
        guard f.insetBy(dx: -1, dy: -1).contains(mouse) else { return false }
        switch position {
        case .bottom: return mouse.y <= f.minY + 2
        case .left: return mouse.x <= f.minX + 2
        case .right: return mouse.x >= f.maxX - 2
        }
    }

    private func handleScreenFollow(mouse: CGPoint) {
        guard screenMode == .followMouse, let window,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              screen != window.targetScreen, atEdge(mouse, of: screen)
        else { return }
        if Date().timeIntervalSince(lastEdgeHit) < 0.25 { return }
        lastEdgeHit = Date()
        window.move(to: screen)
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        withAnimation(settings.animationsEnabled ? .spring(response: 0.32, dampingFraction: 0.9) : nil) {
            isRevealed = revealed
        }
    }

    // MARK: Hover previews

    private func hoverChanged() {
        previewWork?.cancel()
        guard settings.windowPreviews == .hover, draggingPayload == nil,
              let id = hoveredID, let entry = entry(id), let ref = entry.appRef,
              let app = running.running(ref)
        else { return }
        if PopupController.shared.isShowingWindows {
            showWindowPreviews(for: entry, app: app, fromHover: true)
            return
        }
        guard !PopupController.shared.isShowing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredID == id else { return }
            self.showWindowPreviews(for: entry, app: app, fromHover: true)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.previewDelay, execute: work)
    }

    func cancelPendingPreview() {
        previewWork?.cancel()
        previewWork = nil
    }

    // MARK: Coordinates

    /// Screen rect for anchoring a popup: the element's span along the dock, the dock's resting depth across it.
    func screenRect(of id: String) -> CGRect? {
        guard let window, let el = geometry.element(id) else { return nil }
        let bg = geometry.background
        let r: CGRect = position.isVertical
            ? CGRect(x: bg.minX, y: el.rect.minY, width: bg.width, height: el.rect.height)
            : CGRect(x: el.rect.minX, y: bg.minY, width: el.rect.width, height: bg.height)
        let f = window.frame
        return CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    var screenBackgroundRect: CGRect? {
        guard let window else { return nil }
        let f = window.frame, r = geometry.background
        return CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }
}
