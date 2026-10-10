import SwiftUI

struct WidgetView: View {
    let kind: WidgetKind
    let size: CGSize
    let vertical: Bool
    var hovered = false
    @EnvironmentObject var store: PierStore

    var body: some View {
        let theme = store.theme
        let radius = min(size.width, size.height) * 0.26
        ZStack {
            WellBackground(theme: theme, radius: radius, lift: hovered ? 0.1 : 0)
                .animation(.easeOut(duration: 0.18), value: hovered)
            switch kind {
            case .clock: ClockWidget(size: size, theme: theme, settings: store.settings)
            case .nowPlaying: NowPlayingWidget(size: size, theme: theme, compact: vertical)
            case .weather: WeatherWidget(size: size, theme: theme, compact: vertical)
            case .battery: BatteryWidget(size: size, theme: theme, compact: vertical)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The frosted inset that holds widgets and folders: a soft top-lit fill with a crisp light rim.
struct WellBackground: View {
    let theme: Theme
    let radius: CGFloat
    var lift: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = theme.widgetFillOpacity + lift
        shape
            .fill(LinearGradient(colors: [theme.color(theme.widgetFill, min(1, fill + 0.08)),
                                          theme.color(theme.widgetFill, max(0, fill - 0.06))],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(theme.color(theme.borderColor, theme.borderOpacity * 0.85),
                                        lineWidth: max(0.8, theme.borderWidth)))
    }
}

// MARK: - Clock

struct ClockWidget: View {
    let size: CGSize
    let theme: Theme
    let settings: PierSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: settings.clockShowSeconds ? 1 : 5)) { context in
            VStack(spacing: size.height * 0.015) {
                Text(timeString(context.date))
                    .font(.system(size: size.height * (settings.clockShowSeconds ? 0.27 : 0.33), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
                Text(dayString(context.date))
                    .font(.system(size: size.height * 0.13, weight: .semibold))
                    .kerning(size.height * 0.025)
                    .foregroundStyle(theme.secondaryText)
            }
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        if settings.clock24Hour {
            f.dateFormat = settings.clockShowSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            f.dateFormat = settings.clockShowSeconds ? "h:mm:ss" : "h:mm"
        }
        return f.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: date).uppercased()
    }
}

// MARK: - Now Playing

struct NowPlayingWidget: View {
    let size: CGSize
    let theme: Theme
    let compact: Bool
    @ObservedObject private var player = NowPlayingService.shared
    @EnvironmentObject private var dock: DockController

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .animation(.easeInOut(duration: 0.35), value: player.current?.title)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    private var artSide: CGFloat { size.height * 0.64 }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artSide * 0.22, style: .continuous)
                .fill(Color(hex: "#F4EFEA"))
            if let art = player.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .id(player.current?.artworkKey ?? "")
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: artSide * 0.4, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(width: artSide, height: artSide)
        .clipShape(RoundedRectangle(cornerRadius: artSide * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private var fullBody: some View {
        HStack(spacing: size.height * 0.14) {
            artwork
            VStack(alignment: .leading, spacing: size.height * 0.02) {
                Group {
                    Text(player.current?.title ?? "Not Playing")
                    .font(.system(size: size.height * 0.17, weight: .bold))
                    .foregroundStyle(theme.text)
                    Text(player.current?.artist ?? "Music or Spotify")
                        .font(.system(size: size.height * 0.135, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .id(player.current?.title ?? "")
                .transition(.opacity)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressBar(progress: progress(at: context.date), color: theme.text)
                }
                .frame(width: size.height * 1.3, height: max(2.5, size.height * 0.035))
                .padding(.top, size.height * 0.05)
                .opacity(player.current == nil ? 0.35 : 1)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NowPlayingLayout.controlSpacing(size)) {
                control("chevron.left", .previous, scale: 0.13)
                control(player.current?.isPlaying == true ? "pause.fill" : "play.fill", .playPause, scale: 0.15)
                control("chevron.right", .next, scale: 0.13)
            }
        }
        .padding(.leading, (size.height - artSide) / 2)
        .padding(.trailing, NowPlayingLayout.trailingPadding(size))
    }

    private var compactBody: some View {
        artwork.overlay {
            Image(systemName: player.current?.isPlaying == true ? "pause.fill" : "play.fill")
                .font(.system(size: artSide * 0.3, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
    }

    /// Drawn only; clicks are hit-tested by the dock against `NowPlayingLayout` (same rects).
    private func control(_ symbol: String, _ kind: NowPlayingControl, scale: CGFloat) -> some View {
        let pressed = dock.pressedControl == kind && dock.pressedID != nil
        return Image(systemName: symbol)
            .font(.system(size: size.height * scale, weight: .semibold))
            .foregroundStyle(pressed ? theme.text : theme.secondaryText)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: NowPlayingLayout.controlWidth(size), height: size.height * 0.42)
            .background(Circle().fill(theme.color(theme.textColor, pressed ? 0.12 : 0)).padding(2))
            .scaleEffect(pressed ? 0.82 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .opacity(player.current == nil ? 0.45 : 1)
    }

    private func progress(at date: Date) -> Double {
        guard let current = player.current, current.duration > 0 else { return 0 }
        return (player.interpolatedElapsed(at: date) / current.duration).clamped(0, 1)
    }
}

struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.12))
                Capsule().fill(color.opacity(0.85)).frame(width: proxy.size.width * progress)
            }
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    let size: CGSize
    let theme: Theme
    let compact: Bool
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        Group {
            if let report = weather.report {
                if compact {
                    VStack(spacing: 1) {
                        symbol(report).font(.system(size: size.height * 0.32))
                        Text(temp(report.temperature)).font(.system(size: size.height * 0.2, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.text)
                    }
                } else {
                    HStack(spacing: size.height * 0.14) {
                        symbol(report).font(.system(size: size.height * 0.42))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(temp(report.temperature))
                                .font(.system(size: size.height * 0.3, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.text)
                            Text(report.place)
                                .font(.system(size: size.height * 0.14, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                            Text("H:\(temp(report.high)) L:\(temp(report.low))")
                                .font(.system(size: size.height * 0.12, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .lineLimit(1)
                    }
                    .padding(.horizontal, size.height * 0.12)
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "cloud.sun").font(.system(size: size.height * 0.3))
                        .symbolRenderingMode(.multicolor)
                    if !compact {
                        Text(weather.status).font(.system(size: size.height * 0.12, weight: .medium))
                            .foregroundStyle(theme.secondaryText).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .minimumScaleFactor(0.6)
        .onAppear { weather.start() }
        .onDisappear { weather.stop() }
    }

    private func symbol(_ report: WeatherReport) -> some View {
        Image(systemName: report.symbol).symbolRenderingMode(.multicolor)
    }

    private func temp(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

// MARK: - Battery

struct BatteryWidget: View {
    let size: CGSize
    let theme: Theme
    let compact: Bool
    @ObservedObject private var battery = BatteryService.shared

    var body: some View {
        if let state = battery.state {
            VStack(spacing: 2) {
                Image(systemName: state.symbol)
                    .font(.system(size: size.height * 0.3, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state.percent <= 20 && !state.isCharging ? Color.red : theme.text)
                Text("\(state.percent)%")
                    .font(.system(size: size.height * 0.22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
            }
            .minimumScaleFactor(0.6)
        } else {
            VStack(spacing: 2) {
                Image(systemName: "powerplug.fill").font(.system(size: size.height * 0.28))
                Text("AC").font(.system(size: size.height * 0.18, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(theme.text)
        }
    }
}
