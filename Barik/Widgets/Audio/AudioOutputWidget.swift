import SwiftUI

struct AudioOutputWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var audioManager = AudioOutputManager.shared

    @State private var rect: CGRect = CGRect()

    var body: some View {
        Image(systemName: deviceIcon)
            .font(.system(size: 14))
            .overlay(alignment: .topTrailing) {
                Text(audioManager.currentInputDevice?.microphoneLetter ?? "?")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .offset(x: 4, y: -4)
            }
            .foregroundStyle(.foregroundOutside)
            .opacity(audioManager.isMuted ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.15), value: audioManager.isMuted)
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            rect = geometry.frame(in: .global)
                        }
                        .onChange(of: geometry.frame(in: .global)) { oldState, newState in
                            rect = newState
                        }
                }
            )
            .background(.black.opacity(0.001))
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    audioManager.toggleHeadsetCameraInput()
                } else {
                    MenuBarPopup.show(
                        rect: rect, id: "audiooutput", colorScheme: colorScheme
                    ) {
                        AudioOutputPopup()
                    }
                }
            }
            .help("Click: audio devices. Option-click: switch between camera and headset microphones.")
    }

    private var deviceIcon: String {
        audioManager.currentDevice?.icon ?? "speaker.wave.2.fill"
    }
}

struct AudioOutputWidget_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AudioOutputWidget()
        }
        .frame(width: 200, height: 100)
        .background(.yellow)
        .environmentObject(ConfigProvider(config: [:]))
    }
}
