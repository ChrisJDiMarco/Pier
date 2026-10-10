import AppKit
import ApplicationServices
import ScreenCaptureKit

public struct AppWindow: Identifiable, Hashable {
    public let id: CGWindowID
    public let pid: pid_t
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
}

/// Lists an app's windows (via Accessibility), captures thumbnails (via ScreenCaptureKit) and focuses them.
@MainActor
public final class WindowService {
    public static let shared = WindowService()
    private var cycleIndex: [pid_t: Int] = [:]
    /// Last thumbnail captured per window, reused for minimized-window tiles.
    private(set) var thumbnailCache: [CGWindowID: NSImage] = [:]
    private init() {}

    // MARK: Listing

    public func windows(for pid: pid_t) -> [AppWindow] {
        if AXIsProcessTrusted() {
            let ax = axWindows(pid: pid).compactMap { element -> AppWindow? in
                var wid: CGWindowID = 0
                _AXUIElementGetWindow(element, &wid)
                let role = AX.string(element, kAXSubroleAttribute)
                guard wid != 0, role == nil || role == (kAXStandardWindowSubrole as String) || role == "AXDialog" else {
                    return nil
                }
                let origin = AX.point(element, kAXPositionAttribute) ?? .zero
                let size = AX.size(element, kAXSizeAttribute) ?? .zero
                return AppWindow(id: wid, pid: pid, title: AX.string(element, kAXTitleAttribute) ?? "",
                                 frame: CGRect(origin: origin, size: size),
                                 isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false)
            }
            if !ax.isEmpty { return ax }
        }
        return cgWindows(pid: pid)
    }

    /// Fallback without Accessibility: on-screen, normal-layer windows from the window server.
    private func cgWindows(pid: pid_t) -> [AppWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 60, bounds.height > 40
            else { return nil }
            return AppWindow(id: id, pid: pid, title: w[kCGWindowName as String] as? String ?? "",
                             frame: bounds, isMinimized: false)
        }
    }

    private func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not freeze the dock: give up on it quickly instead of the 6 s AX default.
        AXUIElementSetMessagingTimeout(app, AX.timeout)
        return (AX.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func axWindow(_ window: AppWindow) -> AXUIElement? {
        axWindows(pid: window.pid).first { element in
            var wid: CGWindowID = 0
            _AXUIElementGetWindow(element, &wid)
            return wid == window.id
        }
    }

    // MARK: Thumbnails

    public static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    public func thumbnails(for windows: [AppWindow], maxDimension: CGFloat,
                           includeMinimized: Bool = false) async -> [CGWindowID: NSImage] {
        guard Self.canCaptureScreen, !windows.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        let wanted = Set(windows.filter { includeMinimized || !$0.isMinimized }.map(\.id))
        var result: [CGWindowID: NSImage] = [:]
        for scWindow in content.windows where wanted.contains(scWindow.windowID) {
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = min(1, maxDimension / max(scWindow.frame.width, scWindow.frame.height, 1))
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            config.width = max(1, Int(scWindow.frame.width * scale * backing))
            config.height = max(1, Int(scWindow.frame.height * scale * backing))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                result[scWindow.windowID] = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / backing,
                                                                               height: CGFloat(cg.height) / backing))
            }
        }
        thumbnailCache.merge(result) { _, new in new }
        if thumbnailCache.count > 200 { thumbnailCache = result }
        return result
    }

    // MARK: Actions

    public func focus(_ window: AppWindow) {
        if let element = axWindow(window) {
            if AX.bool(element, kAXMinimizedAttribute) == true {
                AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse)
            }
            AX.perform(element, kAXRaiseAction)
            AX.set(AXUIElementCreateApplication(window.pid), kAXFocusedWindowAttribute, element)
        }
        NSRunningApplication(processIdentifier: window.pid)?.unhide()
        AppActions.bringToFront(pid: window.pid)
    }

    public func close(_ window: AppWindow) {
        guard let element = axWindow(window),
              let button = AX.value(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        AX.perform(button as! AXUIElement, kAXPressAction)
    }

    public func minimize(_ window: AppWindow) {
        guard let element = axWindow(window) else { return }
        AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
    }

    /// Toggles native full screen (the green button) for a window, bringing it forward first.
    public func toggleFullScreen(_ window: AppWindow) {
        guard let element = axWindow(window) else { return }
        focus(window)
        let isFull = AX.bool(element, "AXFullScreen") ?? false
        AX.set(element, "AXFullScreen", isFull ? kCFBooleanFalse : kCFBooleanTrue)
    }

    public func minimizeAll(pid: pid_t) {
        for element in axWindows(pid: pid) {
            AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
        }
    }

    /// Brings the next window of the app to the front, wrapping around.
    public func cycle(pid: pid_t) {
        let list = windows(for: pid)
        guard !list.isEmpty else {
            AppActions.bringToFront(pid: pid)
            return
        }
        let next = ((cycleIndex[pid] ?? -1) + 1) % list.count
        cycleIndex[pid] = next
        focus(list[next])
    }
}
