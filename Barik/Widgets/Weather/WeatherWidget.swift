import SwiftUI

struct WeatherWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    var config: ConfigData { configProvider.config }

    var latitude: Double { config["latitude"]?.doubleValue ?? 50.0755 }
    var longitude: Double { config["longitude"]?.doubleValue ?? 14.4378 }

    @StateObject private var manager = WeatherManager()
    @State private var widgetFrame: CGRect = .zero

    var body: some View {
        Button {
            MenuBarPopup.show(rect: widgetFrame, id: "weather", colorScheme: colorScheme) {
                WeatherPopup(manager: manager)
            }
        } label: {
            HStack(spacing: 4) {
                if let data = manager.weatherData {
                    Image(systemName: WeatherManager.symbolName(for: data.weatherCode))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.foregroundOutside)
                        .font(.system(size: 13, weight: .medium))

                    Text(formattedTemperature(data.temperature))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.foregroundOutside)
                        .monospacedDigit()
                } else {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.foregroundOutside.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { widgetFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                        widgetFrame = newFrame
                    }
            }
        )
        .background(.black.opacity(0.001))
        .onAppear {
            manager.updateCoordinates(latitude: latitude, longitude: longitude)
        }
    }

    private func formattedTemperature(_ temp: Double) -> String {
        "\(Int(temp.rounded()))°C"
    }
}

struct WeatherWidget_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WeatherWidget()
                .environmentObject(ConfigProvider(config: [:]))
        }
        .frame(width: 200, height: 60)
        .background(.gray)
    }
}
