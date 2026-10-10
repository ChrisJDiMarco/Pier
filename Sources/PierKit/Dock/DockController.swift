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
        case divider
        case gap
    }

    public let id: String
    public let kind: Kind

    public var appRef: AppRef? {
        switch kind {
        case .item(let item): return item.appRef
        case .running(let app): return app.ref
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
        default: return ""
        }
    }

    var elementKind: ElementKind {
        switch kind {
        case .divider: return .divider
        case .gap: return .gap
        case .running: return .icon
        case .item(let item):
            switch item.content {
            case .widget(let w): return .widget(w)
            case .separator: return .divider
            default: return .icon
            }
        }
    }

    static func runningID(_ ref: AppRef) -> String { "run:\(ref.key)" }
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
    @Published public private(set) var dropOntoID: String?
    @Published public private(set) var isRevealed = true
    @Published public private(set) var isHovering = false

    let store = PierStore.shared
    let running = RunningAppsService.shared
    weak var window: DockWindow?

    private(set) var metrics = DockMetrics(theme: .liquid, magnification: 1)
    /// Copies of the placement settings, taken from the publisher's new value. Reading `store.settings`
    /// inside a `@Published` sink can still return the old value.
    private(set) var position: DockPosition = .bottom
    private(set) var screenMode: ScreenMode = .primary
    private(set) var containerSize: CGSize = .zero
    private var pointer: CGPoint?
    private var draggingPayload: DragPayload?
    private var dragGap: DropTarget?
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var tickTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastEdgeHit = Date.distantPast
    private var placement: (DockPosition, ScreenMode)?

    private init() {}

    public func start() {
        Publishers.CombineLatest3(store.$layout, store.$settings, running.$apps)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildEntries(animated: true) }
            .store(in: &bag)
        Publishers.CombineLatest(store.$theme, store.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] theme, settings in self?.applyAppearance(theme: theme, settings: settings) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.window?.reposition() }
            .store(in: &bag)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    var settings: PierSettings { store.settings }
    var theme: Theme { store.theme }

    // MARK: Entries & geometry

    private func rebuildEntries(animated: Bool) {
        let layout = store.layout
        let draggedID: UUID? = { if case .item(let id) = draggingPayload { return id }; return nil }()
        let draggedRunning: AppRef? = { if case .running(let r) = draggingPayload { return r }; return nil }()

        var list: [DisplayEntry] = layout.main
            .filter { $0.id != draggedID }
            .map { DisplayEntry(id: $0.id.uuidString, kind: .item($0)) }

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
        if !trailing.isEmpty {
            list.append(DisplayEntry(id: DisplayEntry.dividerID, kind: .divider))
            list += trailing.map { DisplayEntry(id: $0.id.uuidString, kind: .item($0)) }
        }

        if let gap = dragGap, case .insert(let before) = gap {
            let index = before.flatMap { id in list.firstIndex { $0.id == id } } ?? list.count
            list.insert(DisplayEntry(id: DisplayEntry.gapID, kind: .gap), at: index)
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
        let next = DockLayoutEngine.layout(elements: elements, metrics: metrics, position: position,
                                           container: containerSize, pointer: pointer)
        if next != geometry { geometry = next }
    }

    func entry(_ id: String) -> DisplayEntry? { entries.first { $0.id == id } }

    // MARK: Pointer tracking (polled so it also works during drags and over transparent areas)

    private func tick() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let p = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let inWindow = frame.contains(mouse)
        let inside = inWindow && isRevealed && geometry.isInsideDock(p, slop: isHovering ? 8 : 0)
        let popupOpen = PopupController.shared.isShowing

        let desired: CGPoint? = inside && !popupOpen ? p : nil
        if inside != isHovering || (desired == nil) != (pointer == nil) {
            withAnimation(settings.animationsEnabled ? .easeOut(duration: 0.16) : nil) {
                isHovering = inside
                pointer = desired
                recomputeGeometry()
            }
        } else if let desired, let current = pointer, abs(geometry.along(current) - geometry.along(desired)) > 0.2 {
            pointer = desired
            recomputeGeometry()
        }

        let hit = inside ? geometry.hit(p, spacing: metrics.spacing)?.id : nil
        if hit != hoveredID {
            hoveredID = hit
            hoverChanged()
        }

        handleAutoHide(mouse: mouse, inside: inside)
        handleScreenFollow(mouse: mouse)
        PopupController.shared.trackPointer(mouse, dockHoveredID: hoveredID)
    }

    private func handleAutoHide(mouse: CGPoint, inside: Bool) {
        guard settings.autoHide else {
            if !isRevealed { setRevealed(true) }
            return
        }
        let resting = isRevealed && (window?.targetScreen.map { atEdge(mouse, of: $0) } ?? false)
        let busy = inside || resting || draggingPayload != nil || PopupController.shared.isShowing
            || window?.isTrackingMenu == true
        if busy {
            hideWork?.cancel()
            hideWork = nil
            if !isRevealed && inside { setRevealed(true) }
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

    // MARK: Drag & drop state (used by DockInteractionView)

    func beginInternalDrag(_ payload: DragPayload, from entryID: String) {
        DragLog.log.notice("begin drag \(entryID, privacy: .public)")
        cancelPendingPreview()
        PopupController.shared.dismiss()
        let nextID = entries.firstIndex { $0.id == entryID }.flatMap { i in
            entries.indices.contains(i + 1) ? entries[i + 1].id : nil
        }
        draggingPayload = payload
        dragGap = .insert(before: nextID)
        rebuildEntries(animated: false)
    }

    var isDraggingInternally: Bool {
        if case .files = draggingPayload { return false }
        return draggingPayload != nil
    }

    func internalPayload() -> DragPayload? { isDraggingInternally ? draggingPayload : nil }

    func updateDrop(at p: CGPoint, payload: DragPayload) -> NSDragOperation {
        let target = geometry.dropTarget(at: p) { [weak self] el in
            self?.canDrop(payload, onto: el.id) ?? false
        }
        var operation: NSDragOperation = []
        var newGap: DropTarget?
        var onto: String?
        switch target {
        case .onto(let id):
            // Keep the gap where it is: removing it would shift the icons out from under the pointer
            // and flicker between "onto" and "between" every update.
            onto = id
            newGap = dragGap
            operation = ontoOperation(payload, id)
        case .insert(let before):
            if canInsert(payload) {
                newGap = .insert(before: before)
                operation = isInternal(payload) ? .move : .link
            }
        }
        if isInternal(payload) && operation.isEmpty { operation = .move }
        let gapChanged = newGap != dragGap
        if onto != dropOntoID { DragLog.log.notice("drop target \(onto ?? "gap", privacy: .public)") }
        if onto != dropOntoID { dropOntoID = onto }
        if gapChanged {
            dragGap = newGap
            rebuildEntries(animated: true)
        }
        return operation
    }

    func dropExited() {
        dropOntoID = nil
        if case .files = draggingPayload { draggingPayload = nil }
        if dragGap != nil {
            dragGap = nil
            rebuildEntries(animated: true)
        }
    }

    func beginExternalDrag(_ urls: [URL]) {
        if draggingPayload == nil { draggingPayload = .files(urls) }
    }

    @discardableResult
    func performDrop(payload: DragPayload) -> Bool {
        DragLog.log.notice("perform drop onto=\(self.dropOntoID ?? "-", privacy: .public) gap=\(String(describing: self.dragGap), privacy: .public)")
        defer { endDrag() }
        if let onto = dropOntoID { return drop(payload, onto: onto) }
        guard case .insert(let before)? = dragGap else { return isInternal(payload) }
        insert(payload, before: before)
        return true
    }

    /// True when releasing an internal drag at `screenPoint` would remove the item from the dock.
    func wouldRemove(at screenPoint: CGPoint) -> Bool {
        guard case .item(let id)? = draggingPayload, !settings.lockLayout,
              let background = screenBackgroundRect,
              let item = store.layout.allItems.first(where: { $0.id == id }), item.content != .trash
        else { return false }
        return !background.insetBy(dx: -50, dy: -50).contains(screenPoint)
    }

    /// Called by the drag source when an internal drag finishes anywhere.
    func internalDragEnded(at screenPoint: CGPoint, accepted: Bool, cancelled: Bool) {
        let remove = !accepted && !cancelled && wouldRemove(at: screenPoint)
        DragLog.log.notice("drag ended accepted=\(accepted) remove=\(remove)")
        let payload = draggingPayload
        endDrag()
        if remove, case .item(let id)? = payload {
            store.update { $0.removing(id) }
        }
    }

    private func endDrag() {
        draggingPayload = nil
        dragGap = nil
        dropOntoID = nil
        rebuildEntries(animated: true)
    }

    private func isInternal(_ payload: DragPayload) -> Bool {
        if case .files = payload { return false }
        return true
    }

    private func appRefs(in payload: DragPayload) -> [AppRef] {
        switch payload {
        case .item(let id):
            guard let item = store.layout.allItems.first(where: { $0.id == id }) else { return [] }
            if let ref = item.appRef { return [ref] }
            return item.folder?.apps ?? []
        case .running(let ref): return [ref]
        case .files(let urls): return urls.compactMap(AppRef.init(url:))
        }
    }

    private func canInsert(_ payload: DragPayload) -> Bool {
        guard !settings.lockLayout else { return false }
        if case .files(let urls) = payload {
            return urls.allSatisfy { $0.pathExtension == "app" || $0.hasDirectoryPath }
        }
        return true
    }

    private func canDrop(_ payload: DragPayload, onto id: String) -> Bool {
        guard let target = entry(id) else { return false }
        if case .item(let srcID) = payload, srcID.uuidString == id { return false }
        switch target.kind {
        case .running:
            if case .files = payload { return true }
            return !settings.lockLayout && appRefs(in: payload).count == 1
        case .item(let item):
            switch item.content {
            case .app:
                if case .files = payload { return true }
                return !settings.lockLayout && appRefs(in: payload).count == 1
            case .folder: return !settings.lockLayout && !appRefs(in: payload).isEmpty
            case .trash: if case .files = payload { return true } else { return false }
            default: return false
            }
        default: return false
        }
    }

    private func ontoOperation(_ payload: DragPayload, _ id: String) -> NSDragOperation {
        guard let target = entry(id) else { return [] }
        if case .item(let item) = target.kind, item.content == .trash { return .delete }
        if case .files(let urls) = payload {
            if case .item(let item) = target.kind, item.folder != nil, urls.allSatisfy({ $0.pathExtension == "app" }) {
                return .link
            }
            return .copy
        }
        return .move
    }

    private func drop(_ payload: DragPayload, onto id: String) -> Bool {
        guard let target = entry(id) else { return false }
        // Files dropped on an app open with that app; on the trash they're moved to the Trash.
        if case .files(let urls) = payload {
            if case .item(let item) = target.kind, item.content == .trash {
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                NSSound(named: "Purr")?.play()
                return true
            }
            if case .item(let item) = target.kind, item.folder != nil, urls.allSatisfy({ $0.pathExtension == "app" }) {
                for ref in urls.compactMap(AppRef.init(url:)) { store.update { $0.addingApp(ref, toFolder: item.id) } }
                return true
            }
            if let ref = target.appRef {
                AppActions.open(files: urls, with: ref)
                return true
            }
            return false
        }

        let sources = appRefs(in: payload)
        switch target.kind {
        case .item(let item):
            if item.folder != nil {
                store.update { layout in
                    var next = layout
                    if case .item(let srcID) = payload, next.allItems.first(where: { $0.id == srcID })?.folder != nil {
                        next = next.removing(srcID)
                    }
                    return sources.reduce(next) { $0.addingApp($1, toFolder: item.id) }
                }
                return true
            }
            if let targetApp = item.appRef, let source = sources.first {
                return makeFolder(payload: payload, source: source, targetID: item.id, targetApp: targetApp)
            }
        case .running(let app):
            guard let source = sources.first else { return false }
            store.update { $0.pinning(app.ref) }
            guard let pinned = store.layout.main.last(where: { $0.appRef?.matches(app.ref) == true }) else { return false }
            return makeFolder(payload: payload, source: source, targetID: pinned.id, targetApp: app.ref)
        default: break
        }
        return false
    }

    private func makeFolder(payload: DragPayload, source: AppRef, targetID: UUID, targetApp: AppRef) -> Bool {
        let name = AppActions.folderName(for: [targetApp, source])
        let result: (DockLayout, UUID)?
        if case .item(let srcID) = payload {
            result = store.layout.makingFolder(dropping: srcID, onto: targetID, name: name)
        } else {
            result = store.layout.makingFolder(adding: source, onto: targetID, name: name)
        }
        guard let (layout, folderID) = result else { return false }
        store.update { _ in layout }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.openFolder(folderID)
        }
        return true
    }

    private func insert(_ payload: DragPayload, before: String?) {
        let layout = store.layout
        let (section, index) = insertionPoint(before: before, layout: layout, payload: payload)
        switch payload {
        case .item(let id):
            store.update { $0.moving(id, to: section, at: index) }
        case .running(let ref):
            store.update { $0.pinning(ref, in: .main, at: min(index, $0.main.count)) }
        case .files(let urls):
            var offset = 0
            for url in urls {
                if let ref = AppRef(url: url) {
                    store.update { $0.pinning(ref, in: .main, at: min(index + offset, $0.main.count)) }
                } else if url.hasDirectoryPath {
                    let item = DockItem(.stack(path: AppRef.normalize(url.path)))
                    store.update { $0.inserting(item, in: .trailing, at: section == .trailing ? index + offset : 0) }
                }
                offset += 1
            }
        }
    }

    private func insertionPoint(before: String?, layout: DockLayout, payload: DragPayload) -> (DockLayout.Section, Int) {
        let draggedID: UUID? = { if case .item(let id) = payload { return id }; return nil }()
        let main = layout.main.filter { $0.id != draggedID }
        let trailing = layout.trailing.filter { $0.id != draggedID }
        let mainOnly: Bool = {
            switch payload {
            case .running: return true
            case .files(let urls): return urls.allSatisfy { $0.pathExtension == "app" }
            case .item(let id):
                guard let item = layout.allItems.first(where: { $0.id == id }) else { return true }
                switch item.content {
                case .app, .folder: return true
                default: return false
                }
            }
        }()
        guard let before else { return mainOnly ? (.main, main.count) : (.trailing, max(0, trailing.count - 1)) }
        if let i = main.firstIndex(where: { $0.id.uuidString == before }) { return (.main, i) }
        if let i = trailing.firstIndex(where: { $0.id.uuidString == before }) {
            return mainOnly ? (.main, main.count) : (.trailing, i)
        }
        if before.hasPrefix("run:") {
            // Running apps sit right after the last app/folder, so dropping before one lands there.
            let lastApp = main.lastIndex { $0.appRef != nil || $0.folder != nil }
            return (.main, lastApp.map { $0 + 1 } ?? 0)
        }
        return (.main, main.count)
    }
}
