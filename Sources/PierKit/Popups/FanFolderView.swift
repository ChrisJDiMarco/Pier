import AppKit
import SwiftUI

/// A folder opened as a fan: icons rise from the tile in a gentle arc, names on the left, nearest first.
/// Long folders show their first apps plus a button to open the full grid.
struct FanFolderView: View {
    let folderID: UUID
    @EnvironmentObject var store: PierStore
    @EnvironmentObject var icons: IconService
    @EnvironmentObject var badges: BadgeService
    @State private var appeared = false

    private let maxItems = 9
    private let icon: CGFloat = 52
    private let labelWidth: CGFloat = 160

    var body: some View {
        let _ = icons.revision
        if let folder = store.layout.allItems.first(where: { $0.id == folderID })?.folder {
            let apps = Array(folder.apps.prefix(maxItems))
            VStack(spacing: 8) {
                if folder.apps.count > maxItems {
                    Button("Open “\(folder.name)” (\(folder.apps.count))") {
                        DockController.shared.openFolder(folderID, as: .popover)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: arc(apps.count))
                    .opacity(appeared ? 1 : 0)
                }
                // Top of the stack is the farthest from the dock, so render in reverse.
                ForEach(Array(apps.enumerated()).reversed(), id: \.element.key) { index, app in
                    row(app, index: index)
                }
            }
            .onAppear { appeared = true }
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { PopupController.shared.dismiss() }
        }
    }

    /// Horizontal drift for the n-th item up the fan, so the column bends to the right as it rises.
    private func arc(_ index: Int) -> CGFloat {
        pow(CGFloat(index), 1.55) * 3.4
    }

    private func row(_ app: AppRef, index: Int) -> some View {
        HStack(spacing: 10) {
            Text(app.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: labelWidth, alignment: .trailing)
            Image(nsImage: icons.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: icon, height: icon)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    if store.settings.showBadges, let badge = badges.badge(for: app) {
                        BadgeView(text: badge, size: icon, color: store.theme.color(store.theme.badgeColor))
                    }
                }
            // Mirror the label's width so the icon column is centered over the folder tile.
            Color.clear.frame(width: labelWidth, height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            PopupController.shared.dismiss()
            AppActions.open(app)
        }
        .rotationEffect(.degrees(Double(index) * 1.6), anchor: .center)
        .offset(x: arc(index), y: appeared ? 0 : CGFloat(index + 1) * 16)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.76).delay(Double(index) * 0.028), value: appeared)
        .help(app.name)
    }
}
