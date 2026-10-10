# Pier

A replacement for the macOS Dock that you can actually customize. Native Swift and AppKit, no Electron, no account, no telemetry. Free and MIT licensed.

<p align="center"><img src="docs/icon.png" width="160" alt="Pier icon"></p>

The built-in Dock lets you change its size, position and magnification. Pier lets you change everything else.

**Folders.** Drag one app onto another to make a folder. Open folders as a popover, inline (the folder unfolds into the dock itself), a centered Launchpad-style grid, or a fan. Give each folder its own color and style. Open folders work from the keyboard: arrow keys to move, Return to launch, type to filter, Esc to close. Badges from the apps inside add up on the collapsed tile.

**Widgets.** A clock with a month calendar, Now Playing (Music and Spotify) with a mini player you can scrub, weather from Open-Meteo, and battery.

**Windows.** Hover a running app for live thumbnails of its windows, with close, minimize and full-screen buttons on each card. Minimized windows get their own tiles after the divider, like the macOS Dock.

**Agent notifications.** Scripts and AI agents can bounce an icon, badge it, or pop a short message above it, through a `pier://` URL or the bundled `pier` command. An auto-hidden dock slides up to show it, and everything clears when you open the app.

**A dock per desktop.** Optionally give every Space its own dock. Each desktop starts with your main dock and keeps whatever you change there.

**And the rest.** Notification badges mirrored from the macOS Dock. Custom icons for any app. Click actions you choose for click, ⌥-click, ⌘-click, ⇧-click, middle-click and scroll. Drag files onto an app to open them with it, or onto the Trash. Stacks for folders like Downloads with Quick Look thumbnails. Bottom, left or right placement, auto-hide, and magnification that runs at your display's refresh rate and keeps the icon under your pointer still.

On first launch Pier copies the layout of your current macOS Dock, so nothing needs setting up.

## Install

Requires macOS 14 or later. Liquid Glass needs macOS 26 or later; older versions get a frosted blur.

Download the latest signed and notarized `Pier.dmg` from [Releases](https://github.com/ChrisJDiMarco/Pier/releases), open it, and drag Pier to Applications.

To build it yourself:

```bash
git clone https://github.com/ChrisJDiMarco/Pier.git
cd Pier
scripts/build_app.sh --install
```

That builds a release binary, wraps it in `Pier.app`, signs it with the first Developer ID or Apple Development identity in your keychain (or ad-hoc if you have none), copies it to `/Applications` and launches it.

To hide the macOS Dock, use the menu bar icon or Settings → General. Pier turns on the system Dock's auto-hide with a very long delay, and turns it back off when you uncheck the option or quit Pier.

## Permissions

Pier works without any permissions. Two optional ones add features:

| Permission | Enables |
|---|---|
| Accessibility | Badges, minimized-window tiles, window lists in menus, focusing a specific window, ⌘N / minimize / cycle click actions |
| Screen Recording | Live thumbnails in window previews (titles still show without it) |

macOS also asks once before Pier reads Music or Spotify, and before it uses your location (only if you choose location-based weather). Network use is limited to weather, Spotify album art and the theme gallery.

If you build Pier with ad-hoc signing, macOS forgets these grants on every rebuild. Sign with a stable identity, or set `PIER_SIGN_IDENTITY`.

## Agent notifications

Install the command once:

```bash
sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Pier.app/Contents/Resources/pier /usr/local/bin/pier
```

Then:

```bash
pier notify --message "Build finished"          # bounce once, glow, show a callout
pier bounce --until-opened                      # keep bouncing until you open the app
pier badge --text 3 --color "#34C759"           # badge; add --sticky to keep it after opening
pier clear                                      # or: pier clear --all
```

Without `--app`, `pier` targets the app that ran it, such as your terminal. With [Claude Code](https://docs.claude.com/en/docs/claude-code) hooks in `~/.claude/settings.json`, your terminal's icon tells you when Claude is done or needs you:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "pier notify --message 'Claude finished' --text ✓" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "pier bounce --until-opened --text '!'" }] }]
  }
}
```

The same actions work as URLs (`open -g "pier://notify?app=com.apple.Terminal&message=Done"`), along with `pier://open?folder=Name&style=launchpad` and `pier://close`. Every value is validated: badges are capped at 4 characters, messages at 140.

## Themes

Right-click the dock → Theme to switch, or browse Settings → Themes, which includes a community gallery. Edit the current theme live in Settings → Appearance, then **Save as Theme…** or **Export…**. A theme is plain JSON:

```json
{
  "name": "Prairie",
  "author": "you",
  "background": "liquidGlass",
  "tint": "#F4E7DA",
  "tintOpacity": 0.32,
  "cornerRadius": 0.3,
  "iconSize": 54,
  "indicator": "dot",
  "textColor": "auto"
}
```

Missing keys fall back to defaults and out-of-range values are clamped, so a theme from an older or newer Pier still loads. The text color also picks the appearance: light text gets dark glass for popups, dark text gets light glass.

**Share a theme:** add your `.piertheme` file to [`themes/`](themes), run `scripts/build_theme_index.py`, and open a pull request. Merged themes show up in everyone's gallery.

## How it works

| Piece | File |
|---|---|
| Borderless, non-activating panel at Dock window level. Transparent pixels pass clicks through, so the window can span the screen edge without blocking anything | `Dock/DockWindow.swift` |
| Layout engine: magnification is the exact integral of one smooth bulge, so icons never jump; auto-fit, hit testing, drop targets | `Layout/DockLayoutEngine.swift` |
| Display-linked animation (up to 120 Hz) driven by a critically damped spring, paused when the pointer is away | `Dock/DockMotion.swift` |
| AppKit overlay that owns every click, scroll, menu and drag, drawn over a SwiftUI renderer | `Dock/DockInteractionView.swift`, `Dock/DockView.swift` |
| Badges read from the system Dock's accessibility tree (`AXStatusLabel`); minimized windows via per-app AX observers | `Services/BadgeService.swift`, `Services/MinimizedWindowsService.swift` |
| Window lists via Accessibility, thumbnails via ScreenCaptureKit | `Services/WindowService.swift` |
| Layout edits as pure functions over value types, all unit tested | `Model/DockLayout+Editing.swift` |

State lives in `~/Library/Application Support/Pier/` (`layout.json`, `spaces.json`, `settings.json`, `theme.json`, `Themes/`, `Icons/`).

## Develop

```bash
swift build                     # debug build
swift test                      # unit tests
scripts/build_app.sh --install  # build, sign and install the app
scripts/build_app.sh --icon     # re-render the icon from Tools/make_icon.swift
```

To ship a notarized DMG, set `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` and run `scripts/package_release.sh`. The app icon is drawn in code by `Tools/make_icon.swift`, so the repo needs no design files.

## Known limits

- Pier stays out of full-screen Spaces, the same as most dock replacements.
- Maximized windows don't know about Pier, so they can extend underneath it. Auto-hide avoids this.
- Now Playing supports Music and Spotify. macOS 15.4 and later block other apps from reading the system-wide now-playing info.
- Per-desktop docks read the active Space through a private window-server call. If a future macOS removes it, the option turns itself off.
- With Reduce Transparency on (System Settings → Accessibility → Display), macOS draws every blur as a flat fill, Pier's included.

## License

MIT. See [LICENSE](LICENSE).
