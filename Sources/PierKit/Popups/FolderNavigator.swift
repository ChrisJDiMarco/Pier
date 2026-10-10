import Foundation

/// Keyboard navigation and type-to-filter for a folder's app grid. Pure, so it's easy to test.
public enum FolderNavigator {

    /// Moves the selection by `delta` (±1 for left/right, ±columns for up/down). Starts at the first app
    /// when nothing is selected, and stays put at the edges instead of wrapping.
    public static func move(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current < count else { return 0 }
        let next = current + delta
        return (0..<count).contains(next) ? next : current
    }

    /// Apps whose name contains the query, with prefix matches first, then word-start matches.
    public static func filter(_ apps: [AppRef], query: String) -> [AppRef] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        func rank(_ app: AppRef) -> Int? {
            let name = app.name
            if name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains(where: { $0.range(of: q, options: [.caseInsensitive, .anchored]) != nil }) { return 1 }
            if name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 2 }
            return nil
        }
        return apps.enumerated()
            .compactMap { i, app in rank(app).map { (rank: $0, index: i, app: app) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.app)
    }
}
