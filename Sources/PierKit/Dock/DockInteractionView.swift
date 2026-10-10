import AppKit

/// Transparent AppKit layer on top of the SwiftUI dock. It owns every mouse interaction so that
/// modifier-clicks, middle-clicks, scrolling, menus and drags behave exactly like a native dock.
final class DockInteractionView: NSView, NSDraggingSource {
    private let controller: DockController
    private var mouseDownPoint: CGPoint?
    private var mouseDownEntry: String?
    private var didDrag = false
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollAction = Date.distantPast
    private(set) var isShowingMenu = false

    private let dragThreshold: CGFloat = 5
    private let scrollThreshold: CGFloat = 6

    init(controller: DockController) {
        self.controller = controller
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .pierItem])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// Wakes the display link the instant the pointer reaches the dock, without a system-wide mouse monitor.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { controller.wakeIfNear() }
    override func mouseMoved(with event: NSEvent) { controller.wakeIfNear() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return controller.geometry.isInsideDock(local, slop: 4) ? self : nil
    }

    private func entryID(at event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return controller.geometry.hit(p, spacing: controller.metrics.spacing)?.id
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEntry = entryID(at: event)
        didDrag = false
        controller.pressedID = mouseDownEntry
        if let id = mouseDownEntry, let start = mouseDownPoint { controller.pressBegan(id, at: start) }
        if mouseDownEntry == nil {
            PopupController.shared.dismiss()
            controller.setExpandedFolder(nil)
        }
        if event.modifierFlags.contains(.control), let id = mouseDownEntry {
            controller.pressedID = nil
            mouseDownEntry = nil
            if controller.handleClick(id, trigger: .controlClick) { showMenu(for: id, event: event) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseDownPoint, let id = mouseDownEntry else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > dragThreshold else { return }
        didDrag = true
        controller.pressedID = nil
        controller.pressedControl = nil
        beginDrag(entryID: id, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            controller.pressedID = nil
            controller.pressedControl = nil
            mouseDownEntry = nil
            mouseDownPoint = nil
        }
        guard !didDrag, let id = mouseDownEntry, entryID(at: event) == id else { return }
        let flags = event.modifierFlags
        let trigger: ClickTrigger
        if flags.contains(.command) { trigger = .commandClick }
        else if flags.contains(.option) { trigger = .optionClick }
        else if flags.contains(.shift) { trigger = .shiftClick }
        else { trigger = .click }
        let point = convert(event.locationInWindow, from: nil)
        if controller.handleClick(id, trigger: trigger, at: point) { showMenu(for: id, event: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let id = entryID(at: event) else { return }
        if controller.handleClick(id, trigger: .middleClick) { showMenu(for: id, event: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let id = entryID(at: event) {
            showMenu(for: id, event: event)
        } else {
            showDockMenu(event: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let id = entryID(at: event) else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let natural = event.isDirectionInvertedFromDevice ? -delta : delta
        scrollAccumulator += natural
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
        guard abs(scrollAccumulator) > scrollThreshold, Date().timeIntervalSince(lastScrollAction) > 0.45 else { return }
        let trigger: ClickTrigger = scrollAccumulator > 0 ? .scrollUp : .scrollDown
        scrollAccumulator = 0
        lastScrollAction = Date()
        if controller.handleClick(id, trigger: trigger) { showMenu(for: id, event: event) }
    }

    // MARK: Menus

    private func showMenu(for id: String, event: NSEvent) {
        guard let entry = controller.entry(id) else { return }
        controller.cancelPendingPreview()
        PopupController.shared.dismiss()
        let menu = DockMenus.menu(for: entry, controller: controller)
        present(menu, event: event)
    }

    private func showDockMenu(event: NSEvent) {
        present(DockMenus.dockMenu(controller: controller), event: event)
    }

    private func present(_ menu: NSMenu, event: NSEvent) {
        isShowingMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isShowingMenu = false
        controller.pressedID = nil
    }

    // MARK: Drag source

    private func beginDrag(entryID id: String, event: NSEvent) {
        guard !controller.settings.lockLayout, let entry = controller.entry(id),
              let el = controller.geometry.element(id) else { return }
        let payloadString: String
        let payload: DragPayload
        switch entry.kind {
        case .item(let item):
            if item.content == .trash { return }
            payload = .item(item.id)
            payloadString = "item:\(item.id.uuidString)"
        case .running(let app):
            payload = .running(app.ref)
            payloadString = "run:\(app.ref.path)"
        default:
            return
        }

        let pbItem = NSPasteboardItem()
        pbItem.setString(payloadString, forType: .pierItem)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(el.rect, contents: snapshot(of: entry, size: el.rect.size))
        controller.beginInternalDrag(payload, from: id)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshot(of entry: DisplayEntry, size: CGSize) -> NSImage {
        let icon: NSImage
        switch entry.kind {
        case .running(let app): icon = IconService.shared.icon(for: app.ref)
        case .item(let item):
            switch item.content {
            case .app(let ref): icon = IconService.shared.icon(for: ref)
            case .folder(let folder): icon = folder.apps.first.map { IconService.shared.icon(for: $0) } ?? NSImage()
            case .stack(let path): icon = IconService.shared.icon(forPath: path)
            default:
                icon = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil) ?? NSImage()
            }
        default: icon = NSImage()
        }
        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .delete
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        if controller.wouldRemove(at: screenPoint) { NSCursor.disappearingItem.set() } else { NSCursor.arrow.set() }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NSCursor.arrow.set()
        // Escape cancels a drag; that must never be read as "dragged off the dock to remove".
        let escape = CGEventSource.keyState(.combinedSessionState, key: 0x35)
            || (NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 0x35)
        controller.internalDragEnded(at: screenPoint, accepted: operation == .move, cancelled: escape)
    }

    // MARK: Drag destination

    private func payload(from info: NSDraggingInfo) -> DragPayload? {
        if let own = controller.internalPayload(),
           info.draggingPasteboard.availableType(from: [.pierItem]) != nil {
            return own
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return nil }
        controller.beginExternalDrag(urls)
        return .files(urls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = payload(from: sender) else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        return controller.updateDrop(at: p, payload: payload)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller.dropExited()
    }

    /// Safety net: clears drag state however an external drag ends.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        if !controller.isDraggingInternally { controller.dropExited() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = payload(from: sender) else { return false }
        return controller.performDrop(payload: payload)
    }
}
