import AppKit
import ApplicationServices
import Combine
import IOKit.ps
import ServiceManagement

// MARK: - Battery

public struct BatteryState: Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool

    public var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

@MainActor
public final class BatteryService: ObservableObject {
    public static let shared = BatteryService()
    @Published public private(set) var state: BatteryState?
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { state = nil; return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let next = BatteryState(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            if next != state { state = next }
            return
        }
        state = nil
    }
}

// MARK: - Launch at login

@MainActor
public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pier: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Permissions

@MainActor
public final class Permissions: ObservableObject {
    public static let shared = Permissions()

    @Published public private(set) var accessibility = AXIsProcessTrusted()
    @Published public private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private var timer: Timer?
    private var watchers = 0

    private init() {}

    /// Polls while the settings/onboarding UI is open so status flips as soon as the user grants access.
    /// Calls are counted, so closing one window doesn't stop polling for the other.
    public func beginWatching() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
        if ax { BadgeService.shared.start() }
    }

    public func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        AppActions.openSystemSettings(anchor: "Privacy_Accessibility")
    }

    public func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            AppActions.openSystemSettings(anchor: "Privacy_ScreenCapture")
        }
    }
}
