import SwiftUI

struct WidgetView: View {
    let kind: WidgetKind
    let size: CGSize
    let vertical: Bool
    @EnvironmentObject var store: PierStore

    var body: some View {
        let theme = store.theme
        let radius = min(size.width, size.height) * 0.26
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.color(theme.widgetFill, theme.widgetFillOpacity))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
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

// MARK: - Clock

struct ClockWidget: View {
    let size: CGSize
    let theme: Theme
    let settings: PierSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: settings.clockShowSeconds ? 1 : 5)) { context in
            VStack(spacing: size.height * 0.02) {
                Text(timeString(context.date))
                    .font(.system(size: size.height * (settings.clockShowSeconds ? 0.27 : 0.34),
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
                Text(dayString(context.date))
                    .font(.system(size: size.height * 0.15, weight: .semibold, design: .rounded))
                    .kerning(1)
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

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    private var artSide: CGFloat { size.height * 0.72 }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artSide * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [.pink.opacity(0.7), .orange.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let art = player.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: artSide * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: artSide, height: artSide)
        .clipShape(RoundedRectangle(cornerRadius: artSide * 0.2, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .onTapGesture { player.openSourceApp() }
    }

    private var fullBody: some View {
        HStack(spacing: size.height * 0.18) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.system(size: size.height * 0.2, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(player.current?.artist ?? "Play something in Music or Spotify")
                    .font(.system(size: size.height * 0.16, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                if player.current != nil {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        ProgressBar(progress: progress(at: context.date), color: theme.text)
                    }
                    .frame(height: 3)
                    .padding(.top, 3)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: size.height * 0.08) {
                control("backward.fill", scale: 0.2) { player.previous() }
                control(player.current?.isPlaying == true ? "pause.fill" : "play.fill", scale: 0.27) {
                    player.togglePlayPause()
                }
                control("forward.fill", scale: 0.2) { player.next() }
            }
        }
        .padding(.horizontal, size.height * 0.14)
    }

    private var compactBody: some View {
        artwork.overlay {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.current?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: artSide * 0.32, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            .buttonStyle(.plain)
        }
    }

    private func control(_ symbol: String, scale: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size.height * scale, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: size.height * 0.36, height: size.height * 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(player.current == nil)
        .opacity(player.current == nil ? 0.4 : 1)
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
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color.opacity(0.75)).frame(width: proxy.size.width * progress)
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
