import Foundation

/// Per-Space docks: the main dock plus any desktops whose dock has been changed.
/// A desktop without its own entry shows the main dock; editing it there gives it one.
public struct SpaceLayouts: Codable, Equatable, Sendable {
    public var base: DockLayout
    public var spaces: [String: DockLayout]

    public init(base: DockLayout, spaces: [String: DockLayout] = [:]) {
        self.base = base
        self.spaces = spaces
    }

    /// The dock to show on `space` (nil = per-Space docks off, i.e. the main dock).
    public func layout(for space: String?) -> DockLayout {
        space.flatMap { spaces[$0] } ?? base
    }

    /// Records `current` as the dock of `space`. Unchanged copies of the main dock aren't stored, so a
    /// desktop only gets its own dock once you actually change it there.
    public func storing(_ current: DockLayout, for space: String?) -> SpaceLayouts {
        var copy = self
        guard let space else {
            copy.base = current
            return copy
        }
        if copy.spaces[space] == nil && current == base { return copy }
        copy.spaces[space] = current
        return copy
    }

    public func resetting(_ space: String) -> SpaceLayouts {
        var copy = self
        copy.spaces.removeValue(forKey: space)
        return copy
    }

    public var customizedCount: Int { spaces.count }
}
