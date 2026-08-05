import SwiftUI

struct AirPodsBatteryWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var manager = AirPodsBatteryManager.shared

    private var config: ConfigData { configProvider.config }
    private var lowBatteryThreshold: Int {
        Int(max(1, min(100, config["low-battery-threshold"]?.doubleValue ?? 11)))
    }
    private var warningColor: Color {
        Color(hex: config["warning-color"]?.stringValue ?? "#D94B4B") ?? .red
    }

    var body: some View {
        if manager.isConnected, let left = manager.leftBattery, let right = manager.rightBattery {
            let rowFont = Font.system(size: 11, weight: .medium, design: .monospaced)
            let leftIsLow = left <= lowBatteryThreshold
            let rightIsLow = right <= lowBatteryThreshold

            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 0) {
                GridRow {
                    Text("L")
                    Group {
                        if left >= 100 {
                            Text("00")
                                .hidden()
                                .overlay(alignment: .leading) {
                                    Text("\(left)").fixedSize()
                                }
                        } else {
                            Text("\(left)")
                        }
                    }
                }
                    .foregroundStyle(leftIsLow ? warningColor : Color.foregroundOutside)
                    .help("Left AirPod battery · warning at \(lowBatteryThreshold)%")
                GridRow {
                    Text("R")
                    Group {
                        if right >= 100 {
                            Text("00")
                                .hidden()
                                .overlay(alignment: .leading) {
                                    Text("\(right)").fixedSize()
                                }
                        } else {
                            Text("\(right)")
                        }
                    }
                }
                    .foregroundStyle(rightIsLow ? warningColor : Color.foregroundOutside)
                    .opacity(rightIsLow ? 1 : 0.7)
                    .help("Right AirPod battery · warning at \(lowBatteryThreshold)%")
            }
            .font(rowFont)
            .fixedSize(horizontal: true, vertical: false)
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.001))
        }
    }
}

struct AirPodsBatteryWidget_Previews: PreviewProvider {
    static var previews: some View {
        AirPodsBatteryWidget()
            .environmentObject(ConfigProvider(config: [:]))
            .frame(width: 80, height: 30)
            .background(.gray)
    }
}
