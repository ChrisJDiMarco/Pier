import Foundation

/// A request, usually from a script or an AI agent, to get the user's attention through a dock icon.
///
///     pier://bounce?app=com.apple.Terminal&times=3
///     pier://badge?app=Terminal&text=✓&color=%2334C759
///     pier://notify?app=com.mitchellh.ghostty&message=Build%20finished&text=1
///     pier://clear?app=Terminal          (or app=all)
///
/// Any action accepts `text` (badge), `color`, `message`, `times` / `until=opened`, and `sticky=1`
/// (keep the badge after the app is opened). Everything is validated: this URL can come from anywhere.
public struct AttentionCommand: Equatable, Sendable {
    public enum Action: String, Sendable { case bounce, badge, flash, notify, clear }

    public var action: Action
    public var app: String
    public var bounces: Int?          // nil = don't bounce; Int.max = until the app is opened
    public var badge: String?
    public var color: String?
    public var message: String?
    public var flash: Bool
    public var sticky: Bool

    public static let untilOpened = Int.max
    static let maxBounces = 20
    static let maxBadgeLength = 4
    static let maxMessageLength = 140
    static let maxAppLength = 200

    public static func parse(_ url: URL) -> AttentionCommand? {
        guard url.scheme?.lowercased() == "pier",
              let action = Action(rawValue: (url.host ?? "").lowercased()),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] { params[item.name.lowercased()] = item.value ?? "" }

        guard let app = params["app"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !app.isEmpty, app.count <= maxAppLength
        else { return nil }

        var command = AttentionCommand(action: action, app: app, bounces: nil, badge: nil, color: nil,
                                       message: nil, flash: false, sticky: params["sticky"] == "1")

        if let text = params["text"].map(clean), !text.isEmpty {
            command.badge = String(text.prefix(maxBadgeLength))
        }
        if let message = params["message"].map(clean), !message.isEmpty {
            command.message = String(message.prefix(maxMessageLength))
        }
        if let color = params["color"], isHexColor(color) { command.color = color }

        let requestedBounces: Int? = {
            if params["until"]?.lowercased() == "opened" { return untilOpened }
            return params["times"].flatMap(Int.init).map { min(max($0, 0), maxBounces) }
        }()

        switch action {
        case .bounce:
            command.bounces = requestedBounces ?? 3
        case .notify:
            command.bounces = requestedBounces ?? 1
            command.flash = true
        case .flash:
            command.flash = true
            command.bounces = requestedBounces
        case .badge:
            guard command.badge != nil else { return nil }
            command.bounces = requestedBounces
        case .clear:
            command.badge = nil
            command.message = nil
        }
        if command.bounces == 0 { command.bounces = nil }
        return command
    }

    /// Strips control characters and surrounding whitespace so a badge or message renders as plain text.
    private static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHexColor(_ s: String) -> Bool {
        let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return (body.count == 6 || body.count == 8) && body.allSatisfy(\.isHexDigit)
    }
}
