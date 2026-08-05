import SwiftUI

struct BackgroundView: View {
    @ObservedObject var configManager = ConfigManager.shared

    private func spacer(_ geometry: GeometryProxy) -> some View {
        let theme: ColorScheme? = {
            switch configManager.config.rootToml.theme {
            case "dark": return .dark
            case "light": return .light
            default: return nil
            }
        }()
        
        let height = configManager.config.experimental.background.resolveHeight()
        
        return Color.clear
            .frame(height: height ?? geometry.size.height)
            .preferredColorScheme(theme)
        
    }
    
    var body: some View {
        if configManager.config.experimental.background.displayed {
            GeometryReader { geometry in
                if configManager.config.experimental.background.black {
                    spacer(geometry)
                        .background(.black)
                        .id("black")
                } else {
                    spacer(geometry)
                        .background {
                            Rectangle()
                                .fill(configManager.config.experimental.background.blur)
                                .opacity(0.7)
                        }
                        .overlay {
                            VStack(spacing: 0) {
                                Rectangle().frame(height: 0.5)
                                Spacer()
                                Rectangle().frame(height: 0.5)
                            }
                            .foregroundStyle(.white.opacity(0.55))
                        }
                        .id("blur")
                }
            }
        }
    }
}
