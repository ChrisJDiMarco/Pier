import XCTest
import AppKit
@testable import PierKit

final class PersistenceTests: XCTestCase {

    func testImportsSystemDockPlist() throws {
        let plist: [String: Any] = [
            "persistent-apps": [
                tile("file:///System/Applications/Mail.app/"),
                ["tile-type": "spacer-tile", "tile-data": [String: Any]()],
                tile("file:///System/Applications/Notes.app/"),
            ],
            "persistent-others": [tile("file:///Users/someone/Downloads/")],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let layout = try XCTUnwrap(SystemDockImporter.parse(plistData: data))
        XCTAssertEqual(layout.main.count, 3)
        XCTAssertEqual(layout.main[0].appRef?.path, "/System/Applications/Mail.app")
        XCTAssertEqual(layout.main[1].content, .separator)
        XCTAssertEqual(layout.trailing.first?.content, .stack(path: "/Users/someone/Downloads"))
        XCTAssertEqual(layout.trailing.last?.content, .trash)
    }

    func testEmptyPlistYieldsNil() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        XCTAssertNil(SystemDockImporter.parse(plistData: data))
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let ref = AppRef(bundleID: "a.b", path: "/Applications/A.app", name: "A")
        let layout = DockLayout(
            main: [DockItem(.app(ref)), DockItem(.folder(AppFolder(name: "F", apps: [ref]))), DockItem(.widget(.weather)),
                   DockItem(.separator)],
            trailing: [DockItem(.stack(path: "/tmp")), DockItem(.trash)])
        let decoded = try JSONDecoder().decode(DockLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
    }

    func testThemeDecodingToleratesMissingAndOutOfRangeKeys() throws {
        let json = ##"{"name":"Shared","tint":"#112233","iconSize":9000,"cornerRadius":-3,"future":"ignored"}"##
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        XCTAssertEqual(theme.name, "Shared")
        XCTAssertEqual(theme.tint, "#112233")
        XCTAssertEqual(theme.iconSize, 128, "clamped")
        XCTAssertEqual(theme.cornerRadius, 0, "clamped")
        XCTAssertEqual(theme.background, .liquidGlass, "missing keys fall back to defaults")
    }

    func testBuiltInThemesRoundTrip() throws {
        for theme in Theme.builtIns {
            let decoded = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme))
            XCTAssertEqual(decoded, theme, theme.name)
        }
    }

    func testSettingsKeepDefaultsForNewKeysAndUnknownBindings() throws {
        let json = #"{"autoHide":true,"clickBindings":{"click":"activateOrHide","bogus":"quit","scrollUp":"nope"}}"#
        let settings = try JSONDecoder().decode(PierSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.autoHide)
        XCTAssertTrue(settings.magnification, "absent key keeps default")
        XCTAssertEqual(settings.action(for: .click), .activateOrHide)
        XCTAssertEqual(settings.action(for: .scrollUp), PierSettings.defaultBindings[.scrollUp])
        let roundTrip = try JSONDecoder().decode(PierSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
    }

    func testHexColorParsing() {
        XCTAssertEqual(NSColor(hex: "#FF8000")?.hexString, "#FF8000")
        XCTAssertEqual(NSColor(hex: "ff800080")?.alphaComponent ?? 0, 128.0 / 255, accuracy: 0.01)
        XCTAssertNil(NSColor(hex: "not-a-color"))
    }

    func testWeatherCodesMapToSymbols() {
        XCTAssertEqual(WeatherCode.symbol(0, isDay: true), "sun.max.fill")
        XCTAssertEqual(WeatherCode.symbol(0, isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCode.summary(95), "Thunderstorms")
        XCTAssertEqual(WeatherCode.symbol(-1, isDay: true), "cloud.fill")
    }

    private func tile(_ url: String) -> [String: Any] {
        ["tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15]]]
    }
}

final class ThemeAppearanceTests: XCTestCase {
    func testTextColorDecidesAppearance() {
        XCTAssertEqual(Theme.clear.prefersDarkAppearance, true, "white text reads as a dark theme")
        XCTAssertEqual(Theme.meadow.prefersDarkAppearance, false, "dark text reads as a light theme")
        XCTAssertNil(Theme.liquid.prefersDarkAppearance, "auto follows the system")
    }
}
