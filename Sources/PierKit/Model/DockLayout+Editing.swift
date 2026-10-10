import Foundation

/// Pure, value-returning edits. Every function returns a new layout and leaves `self` untouched.
public extension DockLayout {

    func inserting(_ item: DockItem, in section: Section, at index: Int) -> DockLayout {
        var copy = self
        var list = copy.items(in: section)
        list.insert(item, at: max(0, min(index, list.count)))
        copy.set(list, for: section)
        return copy
    }

    func removing(_ id: UUID) -> DockLayout {
        var copy = self
        copy.main.removeAll { $0.id == id }
        copy.trailing.removeAll { $0.id == id }
        return copy
    }

    /// Moves an item to `index` of `section`, where `index` is measured in the list *without* the item.
    func moving(_ id: UUID, to section: Section, at index: Int) -> DockLayout {
        guard let found = locate(id) else { return self }
        let item = items(in: found.section)[found.index]
        return removing(id).inserting(item, in: section, at: index)
    }

    /// Pins an app unless it is already pinned somewhere (including inside a folder).
    func pinning(_ app: AppRef, in section: Section = .main, at index: Int? = nil) -> DockLayout {
        guard !isPinned(app) else { return self }
        let target = index ?? items(in: section).count
        return inserting(DockItem(.app(app)), in: section, at: target)
    }

    func unpinning(_ app: AppRef) -> DockLayout {
        var copy = self
        copy.main = copy.main.compactMap { $0.without(app) }
        copy.trailing = copy.trailing.compactMap { $0.without(app) }
        return copy
    }

    /// Drops app item `sourceID` onto app item `targetID`, replacing the target with a new folder.
    func makingFolder(dropping sourceID: UUID, onto targetID: UUID, name: String) -> (DockLayout, UUID)? {
        guard sourceID != targetID,
              let target = locate(targetID),
              let targetApp = items(in: target.section)[target.index].appRef,
              let sourceApp = allItems.first(where: { $0.id == sourceID })?.appRef
        else { return nil }
        let folder = DockItem(.folder(AppFolder(name: name, apps: [targetApp, sourceApp])))
        var copy = self
        var list = copy.items(in: target.section)
        list[target.index] = folder
        copy.set(list, for: target.section)
        return (copy.removing(sourceID), folder.id)
    }

    /// Creates a folder from an app that is not yet pinned (e.g. a running app or a Finder drop).
    func makingFolder(adding app: AppRef, onto targetID: UUID, name: String) -> (DockLayout, UUID)? {
        guard let target = locate(targetID),
              let targetApp = items(in: target.section)[target.index].appRef,
              !targetApp.matches(app)
        else { return nil }
        let folder = DockItem(.folder(AppFolder(name: name, apps: [targetApp, app])))
        var copy = self.unpinning(app)
        guard let newTarget = copy.locate(targetID) else { return nil }
        var list = copy.items(in: newTarget.section)
        list[newTarget.index] = folder
        copy.set(list, for: newTarget.section)
        return (copy, folder.id)
    }

    func addingApp(_ app: AppRef, toFolder folderID: UUID) -> DockLayout {
        guard let loc = locate(folderID), var folder = items(in: loc.section)[loc.index].folder,
              !folder.apps.contains(where: { $0.matches(app) })
        else { return self }
        folder.apps.append(app)
        var copy = self.unpinningOutside(app, folderID: folderID)
        copy = copy.replacing(folderID, with: .folder(folder))
        return copy
    }

    /// Removes an app from a folder. A folder left with one app collapses back into a plain app tile.
    func removingApp(_ app: AppRef, fromFolder folderID: UUID, placeOutside: Bool) -> DockLayout {
        guard let loc = locate(folderID), var folder = items(in: loc.section)[loc.index].folder else { return self }
        folder.apps.removeAll { $0.matches(app) }
        var copy = self
        var list = copy.items(in: loc.section)
        switch folder.apps.count {
        case 0: list.remove(at: loc.index)
        case 1: list[loc.index] = DockItem(id: folderID, .app(folder.apps[0]))
        default: list[loc.index] = DockItem(id: folderID, .folder(folder))
        }
        if placeOutside {
            list.insert(DockItem(.app(app)), at: min(loc.index + 1, list.count))
        }
        copy.set(list, for: loc.section)
        return copy
    }

    func renamingFolder(_ folderID: UUID, to name: String) -> DockLayout {
        guard let loc = locate(folderID), var folder = items(in: loc.section)[loc.index].folder else { return self }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? folder.name : trimmed
        return replacing(folderID, with: .folder(folder))
    }

    func reorderingFolder(_ folderID: UUID, apps: [AppRef]) -> DockLayout {
        guard let loc = locate(folderID), var folder = items(in: loc.section)[loc.index].folder else { return self }
        folder.apps = apps
        return replacing(folderID, with: .folder(folder))
    }

    func replacing(_ id: UUID, with content: DockItemContent) -> DockLayout {
        guard let loc = locate(id) else { return self }
        var copy = self
        var list = copy.items(in: loc.section)
        list[loc.index] = DockItem(id: id, content)
        copy.set(list, for: loc.section)
        return copy
    }

    /// Removes widgets or stacks that are duplicates and guarantees a single trash at the end.
    func sanitized() -> DockLayout {
        var copy = self
        var seenWidgets = Set<WidgetKind>()
        copy.main = copy.main.filter { item in
            switch item.content {
            case .trash: return false
            case .widget(let kind): return seenWidgets.insert(kind).inserted
            default: return true
            }
        }
        copy.trailing = copy.trailing.filter { item in
            if case .widget(let kind) = item.content { return seenWidgets.insert(kind).inserted }
            if case .trash = item.content { return false }
            return true
        }
        copy.trailing.append(DockItem(id: trashID ?? UUID(), .trash))
        return copy
    }

    var trashID: UUID? {
        allItems.first { if case .trash = $0.content { return true } else { return false } }?.id
    }

    // MARK: - Private helpers

    private mutating func set(_ list: [DockItem], for section: Section) {
        if section == .main { main = list } else { trailing = list }
    }

    private func unpinningOutside(_ app: AppRef, folderID: UUID) -> DockLayout {
        var copy = self
        let strip: (DockItem) -> DockItem? = { $0.id == folderID ? $0 : $0.without(app) }
        copy.main = copy.main.compactMap(strip)
        copy.trailing = copy.trailing.compactMap(strip)
        return copy
    }
}

extension DockItem {
    /// Returns this item with `app` removed, or nil if the item was that app.
    func without(_ app: AppRef) -> DockItem? {
        switch content {
        case .app(let ref):
            return ref.matches(app) ? nil : self
        case .folder(var folder):
            guard folder.apps.contains(where: { $0.matches(app) }) else { return self }
            folder.apps.removeAll { $0.matches(app) }
            switch folder.apps.count {
            case 0: return nil
            case 1: return DockItem(id: id, .app(folder.apps[0]))
            default: return DockItem(id: id, .folder(folder))
            }
        default:
            return self
        }
    }
}
