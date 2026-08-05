import SwiftUI

struct ResourceMonitorWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = ResourceMonitorManager.shared
    @State private var widgetFrame: CGRect = .zero

    private var config: ConfigData { configProvider.config }
    private var cpuWarningThreshold: Int {
        Int(max(1, min(100, config["cpu-warning-threshold"]?.doubleValue ?? 85)))
    }
    private var memoryWarningThreshold: Int {
        Int(max(1, min(100, config["memory-warning-threshold"]?.doubleValue ?? 90)))
    }
    private var warningColor: Color {
        Color(hex: config["warning-color"]?.stringValue ?? "#D94B4B") ?? .red
    }

    var body: some View {
        let rowFont = Font.system(size: 11, weight: .medium, design: .monospaced)
        let cpuIsHigh = manager.cpuPercent >= cpuWarningThreshold
        let memoryIsHigh = manager.memPercent >= memoryWarningThreshold

        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 0) {
            GridRow {
                Text("C")
                Text("\(manager.cpuPercent)")
            }
            .foregroundStyle(cpuIsHigh ? warningColor : Color.foregroundOutside)
            .help("CPU usage · warning at \(cpuWarningThreshold)%")
            GridRow {
                Text("M")
                Text("\(manager.memPercent)")
            }
            .foregroundStyle(memoryIsHigh ? warningColor : Color.foregroundOutside)
            .opacity(memoryIsHigh ? 1 : 0.7)
            .help("Memory usage · warning at \(memoryWarningThreshold)%")
        }
        .font(rowFont)
        .fixedSize(horizontal: true, vertical: false)
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { widgetFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in
                        widgetFrame = frame
                    }
            }
        )
        .background(.black.opacity(0.001))
        .onTapGesture {
            MenuBarPopup.show(
                rect: widgetFrame, id: "resource-monitor", colorScheme: colorScheme
            ) {
                ResourceMonitorPopup()
            }
        }
        .help("Click for recent CPU and memory peaks")
    }
}

private struct ResourceMonitorPopup: View {
    @ObservedObject private var manager = ResourceMonitorManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent Resource Peaks")
                    .font(.system(size: 14, weight: .semibold))
                Text("Highest samples from the last 5 minutes")
                    .font(.system(size: 11))
                    .opacity(0.5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider().opacity(0.25)
            consumerSection(
                title: "CPU", icon: "cpu",
                consumers: manager.recentCPUConsumers,
                value: { "\(Int($0.rounded()))%" }
            )
            Divider().opacity(0.25)
            consumerSection(
                title: "Memory", icon: "memorychip",
                consumers: manager.recentMemoryConsumers,
                value: {
                    ByteCountFormatter.string(
                        fromByteCount: Int64($0), countStyle: .memory)
                }
            )
        }
        .frame(width: 320)
    }

    private func consumerSection(
        title: String,
        icon: String,
        consumers: [ResourceConsumer],
        value: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.65)

            if consumers.isEmpty {
                Text("Collecting samples…")
                    .font(.system(size: 12))
                    .opacity(0.45)
            } else {
                ForEach(consumers) { consumer in
                    HStack(spacing: 8) {
                        Text(consumer.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(timeAgo(consumer.seenAt))
                            .font(.system(size: 10))
                            .opacity(0.4)
                        Text(value(consumer.value))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

struct ResourceMonitorWidget_Previews: PreviewProvider {
    static var previews: some View {
        ResourceMonitorWidget()
            .environmentObject(ConfigProvider(config: [:]))
            .frame(width: 80, height: 30)
            .background(.gray)
    }
}
