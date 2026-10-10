import AppKit
import SwiftUI

// MARK: - Now Playing mini player

struct NowPlayingPopupView: View {
    @EnvironmentObject var store: PierStore
    @ObservedObject private var player = NowPlayingService.shared
    @State private var scrubFraction: Double?

    private let width: CGFloat = 264

    var body: some View {
        let theme = store.theme
        VStack(spacing: 14) {
            artwork
            VStack(spacing: 3) {
                Text(player.current?.title ?? "Nothing Playing")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .id(player.current?.title ?? "")
            .transition(.opacity)

            if player.current != nil {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    VStack(spacing: 5) {
                        Scrubber(fraction: scrubFraction ?? liveFraction(at: context.date), color: theme.text) { f in
                            scrubFraction = f
                        } onCommit: { f in
                            player.seek(to: f * (player.current?.duration ?? 0))
                            scrubFraction = nil
                        }
                        .frame(height: 14)
                        HStack {
                            Text(format(elapsed(at: context.date)))
                            Spacer()
                            Text("-" + format(max(0, (player.current?.duration ?? 0) - elapsed(at: context.date))))
                        }
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(width: width)
            }

            HStack(spacing: 30) {
                transport("backward.fill", size: 20) { player.previous() }
                transport(player.current?.isPlaying == true ? "pause.fill" : "play.fill", size: 30) {
                    player.togglePlayPause()
                }
                transport("forward.fill", size: 20) { player.next() }
            }
            .disabled(player.current == nil)
            .opacity(player.current == nil ? 0.4 : 1)

            if let name = player.sourceAppName {
                Button("Open \(name)") {
                    PopupController.shared.dismiss()
                    player.openSourceApp()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: player.current?.title)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    private var subtitle: String {
        guard let c = player.current else { return "Play something in Music or Spotify" }
        return c.album.isEmpty ? c.artist : "\(c.artist) — \(c.album)"
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: "#F1ECE6"))
            if let art = player.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .id(player.current?.artworkKey ?? "")
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 64, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .scaleEffect(player.current?.isPlaying == false ? 0.94 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.current?.isPlaying)
    }

    private func transport(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(store.theme.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func elapsed(at date: Date) -> Double {
        if let f = scrubFraction { return f * (player.current?.duration ?? 0) }
        return player.interpolatedElapsed(at: date)
    }

    private func liveFraction(at date: Date) -> Double {
        guard let d = player.current?.duration, d > 0 else { return 0 }
        return (player.interpolatedElapsed(at: date) / d).clamped(0, 1)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A thin progress track that grows and shows a knob while you drag it.
struct Scrubber: View {
    let fraction: Double
    let color: Color
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let thick: CGFloat = dragging || hovering ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14)).frame(height: thick)
                Capsule().fill(color.opacity(0.8)).frame(width: max(thick, w * fraction), height: thick)
                Circle().fill(color)
                    .frame(width: 12, height: 12)
                    .offset(x: w * fraction - 6)
                    .opacity(dragging || hovering ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: thick)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    onChange((v.location.x / max(w, 1)).clamped(0, 1))
                }
                .onEnded { v in
                    dragging = false
                    onCommit((v.location.x / max(w, 1)).clamped(0, 1))
                })
        }
    }
}

// MARK: - Calendar

struct CalendarPopupView: View {
    @EnvironmentObject var store: PierStore
    @State private var monthStart = CalendarPopupView.startOfMonth(Date())
    @State private var direction: Edge = .trailing

    private let cell: CGFloat = 34
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let theme = store.theme
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#FF3B30"))
                    Text(context.date.formatted(.dateTime.month(.wide).day()))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.text)
                }
            }

            HStack {
                Text(monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .id(monthStart)
                    .transition(.opacity)
                Spacer()
                navButton("chevron.left") { shift(-1) }
                Button("Today") { jump(to: Date()) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                navButton("chevron.right") { shift(1) }
            }

            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: cell)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 7), spacing: 2) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        dayCell(day, theme: theme)
                    }
                }
                .id(monthStart)
                .transition(.asymmetric(insertion: .move(edge: direction).combined(with: .opacity),
                                        removal: .opacity))
            }
            .clipped()

            Button("Open Calendar") {
                PopupController.shared.dismiss()
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
        }
        .frame(width: cell * 7)
    }

    @ViewBuilder private func dayCell(_ day: Date?, theme: Theme) -> some View {
        if let day {
            let isToday = calendar.isDateInToday(day)
            let weekend = calendar.isDateInWeekend(day)
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : (weekend ? theme.secondaryText : theme.text))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(hex: "#FF3B30")).opacity(isToday ? 1 : 0))
                .frame(width: cell, height: 30)
        } else {
            Color.clear.frame(width: cell, height: 30)
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.theme.text)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func shift(_ months: Int) {
        direction = months > 0 ? .trailing : .leading
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            monthStart = calendar.date(byAdding: .month, value: months, to: monthStart) ?? monthStart
        }
    }

    private func jump(to date: Date) {
        let target = Self.startOfMonth(date)
        direction = target > monthStart ? .trailing : .leading
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { monthStart = target }
    }

    /// Weekday initials ordered by the user's first day of the week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded with nils so day 1 falls under the right weekday.
    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let dates = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        return Array(repeating: nil, count: leading) + dates.map { Optional($0) }
    }

    static func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }
}

// MARK: - Weather

struct WeatherPopupView: View {
    @EnvironmentObject var store: PierStore
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        let theme = store.theme
        VStack(spacing: 10) {
            if let report = weather.report {
                Text(report.place)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Image(systemName: report.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 54))
                    .frame(height: 64)
                Text("\(Int(report.temperature.rounded()))°")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(theme.text)
                Text(report.summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text)
                Text("H:\(Int(report.high.rounded()))°  L:\(Int(report.low.rounded()))°")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            } else {
                Image(systemName: "cloud.sun").symbolRenderingMode(.multicolor).font(.system(size: 44))
                Text(weather.status.isEmpty ? "Loading…" : weather.status)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                Button("Refresh") { weather.refresh() }
                Button("Settings…") { SettingsWindowController.shared.show(pane: .widgets) }
                Button("Open Weather") {
                    PopupController.shared.dismiss()
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 4)
        }
        .frame(width: 230)
        .onAppear { weather.start() }
        .onDisappear { weather.stop() }
    }
}
