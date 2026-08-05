import Charts
import SwiftUI

struct WeatherPopup: View {
    @ObservedObject var manager: WeatherManager
    @State private var mode = ForecastMode.daily
    @State private var popupSize = CGSize(width: 520, height: 540)
    @State private var resizeStart: CGSize?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let sunlight = manager.sunlightData {
                    SunlightView(sunlight: sunlight)
                }

                Divider().opacity(0.35)

                if (mode == .hourly && manager.hourlyForecast.isEmpty)
                    || (mode == .daily && manager.dailyForecast.isEmpty) {
                    if manager.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(manager.errorMessage ?? "Forecast unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    forecast
                }
            }
            .padding(20)

            resizeHandle
        }
        .frame(width: popupSize.width, height: popupSize.height, alignment: .top)
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .gesture(resizeGesture(horizontal: true, vertical: false))
        }
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(resizeGesture(horizontal: false, vertical: true))
        }
        .task {
            manager.fetchWeather()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let weather = manager.weatherData {
            HStack(spacing: 14) {
                Image(systemName: WeatherManager.symbolName(for: weather.weatherCode))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34, weight: .medium))
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(WeatherManager.conditionName(for: weather.weatherCode))
                        .font(.headline)
                    Text("\(Int(weather.temperature.rounded()))°C")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Spacer()

                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        mode = mode == .hourly ? .daily : .hourly
                    }
                } label: {
                    Image(systemName: mode == .hourly ? "calendar" : "clock")
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(mode == .hourly ? "Show daily forecast" : "Show hourly forecast")

                Button {
                    manager.fetchWeather()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh weather")
            }
        } else {
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(manager.isLoading ? "Loading weather…" : "Weather unavailable")
                    .font(.headline)
            }
        }
    }

    @ViewBuilder
    private var forecast: some View {
        let chartHeight = max(160, popupSize.height - 340)
        if mode == .hourly {
            HourlyTemperatureChart(hours: Array(manager.hourlyForecast.prefix(24)))
                .frame(height: chartHeight)
                .transition(.opacity)
        } else {
            DailyTemperatureChart(days: manager.dailyForecast)
                .frame(height: chartHeight)
                .transition(.opacity)
        }
        dailyStrip
    }

    private var dailyStrip: some View {
        HStack(spacing: 4) {
            ForEach(manager.dailyForecast) { day in
                VStack(spacing: 5) {
                    Text(day.date, format: .dateTime.weekday(.abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: WeatherManager.symbolName(for: day.weatherCode))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 18, weight: .medium))
                    Text("\(Int(day.maximumTemperature.rounded()))° \(Int(day.minimumTemperature.rounded()))°")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                    if let precipitation = day.precipitationProbability,
                       precipitation > 0 {
                        Label("\(precipitation)%", systemImage: "drop.fill")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .help(WeatherManager.conditionName(for: day.weatherCode))
            }
        }
        .padding(.horizontal, 6)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .gesture(resizeGesture(horizontal: true, vertical: true))
            .help("Drag to resize")
            .accessibilityLabel("Resize weather popup")
    }

    private func resizeGesture(horizontal: Bool, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = resizeStart ?? popupSize
                resizeStart = start
                let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 900, height: 760)
                let maximumWidth = max(460, min(760, screen.width - 64))
                let maximumHeight = max(500, min(680, screen.height - 64))
                popupSize = CGSize(
                    width: horizontal
                        ? min(max(start.width + value.translation.width * 2, 460), maximumWidth)
                        : start.width,
                    height: vertical
                        ? min(max(start.height + value.translation.height, 500), maximumHeight)
                        : start.height
                )
            }
            .onEnded { _ in resizeStart = nil }
    }
}

private enum ForecastMode {
    case hourly, daily
}

private struct HourlyTemperatureChart: View {
    let hours: [HourlyWeatherData]
    @State private var selected: HourlyWeatherData?

    private var minimum: Double {
        (hours.map(\.temperature).min() ?? 0) - 2
    }

    private var maximum: Double {
        (hours.map(\.temperature).max() ?? 1) + 2
    }

    var body: some View {
        Chart {
            ForEach(hours) { hour in
                if let precipitation = hour.precipitationProbability,
                   precipitation > 0 {
                    BarMark(
                        x: .value("Hour", hour.time),
                        yStart: .value("Precipitation base", minimum),
                        yEnd: .value(
                            "Precipitation",
                            minimum + (maximum - minimum) * Double(precipitation) / 100
                        )
                    )
                    .foregroundStyle(.blue.opacity(0.18))
                }

                AreaMark(
                    x: .value("Hour", hour.time),
                    yStart: .value("Base", minimum),
                    yEnd: .value("Temperature", hour.temperature)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.orange.opacity(0.25), .orange.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Hour", hour.time),
                    y: .value("Temperature", hour.temperature)
                )
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }

            if let selected {
                RuleMark(x: .value("Selected hour", selected.time))
                    .foregroundStyle(.primary.opacity(0.25))
            }
        }
        .chartYScale(domain: minimum...maximum)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(
                            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                        ))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let temperature = value.as(Double.self) {
                        Text("\(Int(temperature))°")
                    }
                }
            }
        }
        .chartOverlay { proxy in hoverOverlay(proxy: proxy) }
    }

    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              let frame = proxy.plotFrame.map({ geometry[$0] }),
                              frame.contains(location),
                              let date: Date = proxy.value(atX: location.x - frame.minX) else {
                            selected = nil
                            return
                        }
                        selected = hours.min {
                            abs($0.time.timeIntervalSince(date))
                                < abs($1.time.timeIntervalSince(date))
                        }
                    }

                if let selected,
                   let frame = proxy.plotFrame.map({ geometry[$0] }),
                   let x = proxy.position(forX: selected.time) {
                    forecastCard(
                        title: selected.time.formatted(
                            .dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                        ),
                        temperature: "\(Int(selected.temperature.rounded()))°",
                        code: selected.weatherCode,
                        precipitation: selected.precipitationProbability
                    )
                    .frame(width: 190, alignment: .leading)
                    .position(
                        x: min(max(frame.minX + x, 95), geometry.size.width - 95),
                        y: frame.minY + 38
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct DailyTemperatureChart: View {
    let days: [DailyWeatherData]
    @State private var selected: DailyWeatherData?

    private var minimum: Double {
        (days.map(\.minimumTemperature).min() ?? 0) - 2
    }

    private var maximum: Double {
        (days.map(\.maximumTemperature).max() ?? 1) + 2
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                AreaMark(
                    x: .value("Day", day.date),
                    yStart: .value("Low", day.minimumTemperature),
                    yEnd: .value("High", day.maximumTemperature)
                )
                .foregroundStyle(.orange.opacity(0.13))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Day", day.date),
                    y: .value("High", day.maximumTemperature),
                    series: .value("Temperature", "High")
                )
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Low", day.minimumTemperature),
                    series: .value("Temperature", "Low")
                )
                .foregroundStyle(.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }

            if let selected {
                RuleMark(x: .value("Selected day", selected.date))
                    .foregroundStyle(.primary.opacity(0.25))
            }
        }
        .chartYScale(domain: minimum...maximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let temperature = value.as(Double.self) {
                        Text("\(Int(temperature))°")
                    }
                }
            }
        }
        .chartOverlay { proxy in hoverOverlay(proxy: proxy) }
    }

    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              let frame = proxy.plotFrame.map({ geometry[$0] }),
                              frame.contains(location),
                              let date: Date = proxy.value(atX: location.x - frame.minX) else {
                            selected = nil
                            return
                        }
                        selected = days.min {
                            abs($0.date.timeIntervalSince(date))
                                < abs($1.date.timeIntervalSince(date))
                        }
                    }

                if let selected,
                   let frame = proxy.plotFrame.map({ geometry[$0] }),
                   let x = proxy.position(forX: selected.date) {
                    forecastCard(
                        title: selected.date.formatted(.dateTime.weekday(.wide)),
                        temperature: "\(Int(selected.maximumTemperature.rounded()))° / \(Int(selected.minimumTemperature.rounded()))°",
                        code: selected.weatherCode,
                        precipitation: selected.precipitationProbability
                    )
                    .frame(width: 190, alignment: .leading)
                    .position(
                        x: min(max(frame.minX + x, 95), geometry.size.width - 95),
                        y: frame.minY + 38
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

@MainActor
private func forecastCard(
    title: String,
    temperature: String,
    code: Int,
    precipitation: Int?
) -> some View {
    HStack(spacing: 8) {
        Image(systemName: WeatherManager.symbolName(for: code))
            .symbolRenderingMode(.multicolor)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text("\(temperature) · \(WeatherManager.conditionName(for: code))")
                .font(.caption2)
            if let precipitation, precipitation > 0 {
                Label("\(precipitation)% precipitation", systemImage: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
}

private struct SunlightView: View {
    let sunlight: SunlightData

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let progress = CGFloat(min(max(
                    context.date.timeIntervalSince(sunlight.sunrise)
                        / sunlight.sunset.timeIntervalSince(sunlight.sunrise),
                    0
                ), 1))
            let solarNoon = sunlight.sunrise.addingTimeInterval(
                sunlight.sunset.timeIntervalSince(sunlight.sunrise) / 2
            )

            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon(at: context.date))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow)
                    Text(status(at: context.date))
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(sunlight.daylightMinutes / 60)h \(sunlight.daylightMinutes % 60)m daylight")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                SunArc(
                    progress: progress,
                    isDaylight: (sunlight.sunrise...sunlight.sunset).contains(context.date)
                )
                .frame(height: 62)
                .accessibilityHidden(true)

                HStack(spacing: 0) {
                    sunTime("Sunrise", date: sunlight.sunrise)
                    sunTime("Solar noon", date: solarNoon)
                    sunTime("Sunset", date: sunlight.sunset)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private func sunTime(_ title: String, date: Date) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(date, style: .time)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .environment(\.timeZone, sunlight.timeZone)
        }
        .frame(maxWidth: .infinity)
    }

    private func status(at date: Date) -> String {
        if date < sunlight.sunrise {
            return "Sunrise in \(duration(until: sunlight.sunrise, from: date))"
        }
        if date < sunlight.sunset {
            return "Sunset in \(duration(until: sunlight.sunset, from: date))"
        }
        return "Sun below horizon"
    }

    private func statusIcon(at date: Date) -> String {
        date < sunlight.sunrise ? "sunrise.fill" : date < sunlight.sunset ? "sun.max.fill" : "sunset.fill"
    }

    private func duration(until target: Date, from date: Date) -> String {
        let minutes = max(Int(target.timeIntervalSince(date) / 60), 0)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct SunArc: View {
    let progress: CGFloat
    let isDaylight: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let inset: CGFloat = 7
            let start = CGPoint(x: inset, y: height - inset)
            let end = CGPoint(x: width - inset, y: height - inset)
            let peak = position(at: 0.5, in: geometry.size)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(
                    Color.primary.opacity(0.08),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                )
                Path { path in
                    path.move(to: peak)
                    path.addLine(to: CGPoint(x: peak.x, y: height - inset))
                }
                .stroke(
                    Color.primary.opacity(0.1),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 4])
                )
                SunArcShape()
                    .stroke(
                        Color.primary.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])
                    )
                SunArcShape()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.yellow.opacity(0.8),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                ForEach([CGFloat(0), 0.5, 1], id: \.self) { phase in
                    Circle()
                        .fill(phase == 0.5 ? Color.yellow.opacity(0.85) : Color.primary.opacity(0.25))
                        .frame(width: phase == 0.5 ? 6 : 4, height: phase == 0.5 ? 6 : 4)
                        .position(position(at: phase, in: geometry.size))
                }
                if isDaylight {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.yellow)
                        .shadow(color: .yellow.opacity(0.4), radius: 4)
                        .position(position(at: progress, in: geometry.size))
                }
            }
        }
    }

    private func position(at progress: CGFloat, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 7
        let inverse = 1 - progress
        let start = CGPoint(x: inset, y: size.height - inset)
        let control = CGPoint(x: size.width / 2, y: 36 - (size.height - inset))
        let end = CGPoint(x: size.width - inset, y: size.height - inset)
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
            y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y
        )
    }
}

private struct SunArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 7
        let base = rect.maxY - inset
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + inset, y: base))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - inset, y: base),
                control: CGPoint(x: rect.midX, y: 36 - base)
            )
        }
    }
}
