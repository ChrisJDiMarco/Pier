import AppKit
import SwiftUI

/// Live window thumbnails for a running app. Click to focus, hover for a close button.
struct WindowPreviewPopupView: View {
    let app: RunningApp
    let windows: [AppWindow]
    @EnvironmentObject var store: PierStore
    @State private var thumbnails: [CGWindowID: NSImage] = [:]
    @State private var closed: Set<CGWindowID> = []

    private let maxThumb: CGFloat = 220

    var body: some View {
        let visible = windows.filter { !closed.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: IconService.shared.icon(for: app.ref)).resizable().frame(width: 18, height: 18)
                Text(app.ref.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(store.theme.text)
                Spacer(minLength: 20)
                if !WindowService.canCaptureScreen {
                    Button("Enable Previews") { Permissions.shared.requestScreenRecording() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            if visible.isEmpty {
                HStack {
                    Text("No open windows").font(.system(size: 12)).foregroundStyle(store.theme.secondaryText)
                    Spacer()
                    Button("New Window") {
                        PopupController.shared.dismiss()
                        AppActions.newWindow(app.ref)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(width: 220)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visible.prefix(8)) { window in
                        WindowCard(window: window, app: app, thumbnail: thumbnails[window.id], maxThumb: maxThumb,
                                   theme: store.theme) {
                            closed.insert(window.id)
                            WindowService.shared.close(window)
                        }
                    }
                }
            }
        }
        .task {
            thumbnails = await WindowService.shared.thumbnails(for: windows, maxDimension: maxThumb * 1.2)
        }
    }
}

private struct WindowCard: View {
    let window: AppWindow
    let app: RunningApp
    let thumbnail: NSImage?
    let maxThumb: CGFloat
    let theme: Theme
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        let aspect = window.frame.height > 0 ? window.frame.width / window.frame.height : 1.5
        let size = aspect >= 1
            ? CGSize(width: maxThumb, height: maxThumb / aspect)
            : CGSize(width: maxThumb * aspect, height: maxThumb)
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(nsImage: IconService.shared.icon(for: app.ref)).resizable().frame(width: 48, height: 48)
                        .opacity(0.8)
                }
                if window.isMinimized {
                    Text("Minimized").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(6)
                }
            }
            .frame(width: size.width, height: max(size.height, 60))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Close window")
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .opacity(window.isMinimized ? 0.6 : 1)

            Text(window.title.isEmpty ? app.ref.name : window.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: size.width)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture {
            PopupController.shared.dismiss()
            WindowService.shared.focus(window)
        }
    }
}
