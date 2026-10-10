import AppKit
import SwiftUI

/// Drag and drop: internal reordering, making folders, and files dropped from Finder.
extension DockController {

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
        if before.hasPrefix("min:") {
            // Minimized windows lead the right-hand section.
            return mainOnly ? (.main, main.count) : (.trailing, 0)
        }
        if before.hasPrefix("run:") {
            // Running apps sit right after the last app/folder, so dropping before one lands there.
            let lastApp = main.lastIndex { $0.appRef != nil || $0.folder != nil }
            return (.main, lastApp.map { $0 + 1 } ?? 0)
        }
        return (.main, main.count)
    }
}
