import Foundation

public enum DockPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottom, left, right
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var isVertical: Bool { self != .bottom }
}

public enum ScreenMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case primary, followMouse
    public var id: String { rawValue }
    public var title: String { self == .primary ? "Main display" : "Display with the pointer" }
}

public enum PreviewTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    case hover, off
    public var id: String { rawValue }
    public var title: String { self == .hover ? "On hover" : "Off" }
}

public enum ClickTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    case click, optionClick, commandClick, shiftClick, controlClick, middleClick, scrollUp, scrollDown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .click: return "Click"
        case .optionClick: return "⌥ Option-click"
        case .commandClick: return "⌘ Command-click"
        case .shiftClick: return "⇧ Shift-click"
        case .controlClick: return "⌃ Control-click"
        case .middleClick: return "Middle-click"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        }
    }
}

public enum ClickAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case activate, activateOrHide, showWindows, cycleWindows, newWindow, hide, hideOthers, minimizeAll
    case quit, revealInFinder, appExpose, contextMenu, nothing
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .activate: return "Open / bring to front"
        case .activateOrHide: return "Open, or hide if in front"
        case .showWindows: return "Show window previews"
        case .cycleWindows: return "Cycle through windows"
        case .newWindow: return "New window"
        case .hide: return "Hide app"
        case .hideOthers: return "Open and hide others"
        case .minimizeAll: return "Minimize all windows"
        case .quit: return "Quit app"
        case .revealInFinder: return "Show in Finder"
        case .appExpose: return "App Exposé"
        case .contextMenu: return "Show menu"
        case .nothing: return "Do nothing"
        }
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    public var symbol: String { self == .fahrenheit ? "°F" : "°C" }
}

public struct PierSettings: Codable, Hashable, Sendable {
    public var position: DockPosition = .bottom
    public var screenMode: ScreenMode = .primary
    public var autoHide = false
    public var autoHideDelay = 0.35
    public var magnification = true
    public var magnificationScale = 1.55
    public var showRunningApps = true
    public var showMinimizedWindows = true
    public var showLabels = true
    public var showBadges = true
    public var launchBounce = true
    public var animationsEnabled = true
    public var lockLayout = false
    public var hideSystemDock = false
    public var restoreSystemDockOnQuit = true
    public var windowPreviews: PreviewTrigger = .hover
    public var previewDelay = 0.55
    public var folderColumns = 4
    public var folderStyle: FolderStyle = .popover
    public var clickBindings: [ClickTrigger: ClickAction] = PierSettings.defaultBindings
    public var clock24Hour = false
    public var clockShowSeconds = false
    public var weatherCity = ""
    public var weatherUseLocation = false
    public var temperatureUnit: TemperatureUnit = .fahrenheit
    public var themeID = Theme.meadow.id
    public var didOnboard = false

    public init() {}

    public static let defaultBindings: [ClickTrigger: ClickAction] = [
        .click: .activate,
        .optionClick: .hideOthers,
        .commandClick: .revealInFinder,
        .shiftClick: .newWindow,
        .controlClick: .contextMenu,
        .middleClick: .newWindow,
        .scrollUp: .showWindows,
        .scrollDown: .hide,
    ]

    public func action(for trigger: ClickTrigger) -> ClickAction {
        clickBindings[trigger] ?? PierSettings.defaultBindings[trigger] ?? .nothing
    }

    /// Tolerant decoding so new settings never wipe a user's existing preferences.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PierSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        position = v(.position, d.position)
        screenMode = v(.screenMode, d.screenMode)
        autoHide = v(.autoHide, d.autoHide)
        autoHideDelay = v(.autoHideDelay, d.autoHideDelay).clamped(0, 3)
        magnification = v(.magnification, d.magnification)
        magnificationScale = v(.magnificationScale, d.magnificationScale).clamped(1, 2.4)
        showRunningApps = v(.showRunningApps, d.showRunningApps)
        showMinimizedWindows = v(.showMinimizedWindows, d.showMinimizedWindows)
        showLabels = v(.showLabels, d.showLabels)
        showBadges = v(.showBadges, d.showBadges)
        launchBounce = v(.launchBounce, d.launchBounce)
        animationsEnabled = v(.animationsEnabled, d.animationsEnabled)
        lockLayout = v(.lockLayout, d.lockLayout)
        hideSystemDock = v(.hideSystemDock, d.hideSystemDock)
        restoreSystemDockOnQuit = v(.restoreSystemDockOnQuit, d.restoreSystemDockOnQuit)
        windowPreviews = v(.windowPreviews, d.windowPreviews)
        previewDelay = v(.previewDelay, d.previewDelay).clamped(0, 3)
        folderColumns = Int(Double(v(.folderColumns, d.folderColumns)).clamped(2, 8))
        folderStyle = v(.folderStyle, d.folderStyle)
        let rawBindings: [String: String] = v(.clickBindings, [:])
        var bindings = PierSettings.defaultBindings
        for (k, val) in rawBindings {
            if let t = ClickTrigger(rawValue: k), let a = ClickAction(rawValue: val) { bindings[t] = a }
        }
        clickBindings = bindings
        clock24Hour = v(.clock24Hour, d.clock24Hour)
        clockShowSeconds = v(.clockShowSeconds, d.clockShowSeconds)
        weatherCity = v(.weatherCity, d.weatherCity)
        weatherUseLocation = v(.weatherUseLocation, d.weatherUseLocation)
        temperatureUnit = v(.temperatureUnit, d.temperatureUnit)
        themeID = v(.themeID, d.themeID)
        didOnboard = v(.didOnboard, d.didOnboard)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position)
        try c.encode(screenMode, forKey: .screenMode)
        try c.encode(autoHide, forKey: .autoHide)
        try c.encode(autoHideDelay, forKey: .autoHideDelay)
        try c.encode(magnification, forKey: .magnification)
        try c.encode(magnificationScale, forKey: .magnificationScale)
        try c.encode(showRunningApps, forKey: .showRunningApps)
        try c.encode(showMinimizedWindows, forKey: .showMinimizedWindows)
        try c.encode(showLabels, forKey: .showLabels)
        try c.encode(showBadges, forKey: .showBadges)
        try c.encode(launchBounce, forKey: .launchBounce)
        try c.encode(animationsEnabled, forKey: .animationsEnabled)
        try c.encode(lockLayout, forKey: .lockLayout)
        try c.encode(hideSystemDock, forKey: .hideSystemDock)
        try c.encode(restoreSystemDockOnQuit, forKey: .restoreSystemDockOnQuit)
        try c.encode(windowPreviews, forKey: .windowPreviews)
        try c.encode(previewDelay, forKey: .previewDelay)
        try c.encode(folderColumns, forKey: .folderColumns)
        try c.encode(folderStyle, forKey: .folderStyle)
        try c.encode(Dictionary(uniqueKeysWithValues: clickBindings.map { ($0.key.rawValue, $0.value.rawValue) }),
                     forKey: .clickBindings)
        try c.encode(clock24Hour, forKey: .clock24Hour)
        try c.encode(clockShowSeconds, forKey: .clockShowSeconds)
        try c.encode(weatherCity, forKey: .weatherCity)
        try c.encode(weatherUseLocation, forKey: .weatherUseLocation)
        try c.encode(temperatureUnit, forKey: .temperatureUnit)
        try c.encode(themeID, forKey: .themeID)
        try c.encode(didOnboard, forKey: .didOnboard)
    }

    enum CodingKeys: String, CodingKey {
        case position, screenMode, autoHide, autoHideDelay, magnification, magnificationScale
        case showRunningApps, showMinimizedWindows, showLabels, showBadges, launchBounce, animationsEnabled, lockLayout
        case hideSystemDock, restoreSystemDockOnQuit, windowPreviews, previewDelay, folderColumns, folderStyle
        case clickBindings, clock24Hour, clockShowSeconds, weatherCity, weatherUseLocation
        case temperatureUnit, themeID, didOnboard
    }
}
