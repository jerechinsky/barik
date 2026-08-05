import SwiftUI

struct AudioOutputPopup: View {
    @ObservedObject private var audioManager = AudioOutputManager.shared
    @State private var localVolume: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Volume slider section
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: audioManager.volumeIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 20)
                        .onTapGesture {
                            audioManager.setMuted(!audioManager.isMuted)
                        }

                    Slider(value: $localVolume, in: 0...1) { editing in
                        if !editing {
                            audioManager.setVolume(localVolume)
                        }
                    }
                    .tint(.primary)
                    .onChange(of: localVolume) { _, newValue in
                        audioManager.setVolume(newValue)
                    }

                    Text("\(Int(localVolume * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.6))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)

            Divider()
                .background(Color.primary.opacity(0.2))

            // Output devices section
            VStack(alignment: .leading, spacing: 4) {
                Text("Output")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.horizontal, 4)

                ForEach(audioManager.outputDevices) { device in
                    DeviceRow(
                        device: device,
                        isSelected: device.isDefault,
                        icon: device.icon
                    ) {
                        audioManager.setDefaultOutputDevice(device)
                    }
                }
            }

            Divider()
                .background(Color.primary.opacity(0.2))

            VStack(alignment: .leading, spacing: 4) {
                Text("Input")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.horizontal, 4)

                ForEach(audioManager.inputDevices) { device in
                    DeviceRow(
                        device: device,
                        isSelected: device.isDefault,
                        icon: device.microphoneIcon
                    ) {
                        audioManager.setDefaultInputDevice(device)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            localVolume = audioManager.volume
        }
        .onChange(of: audioManager.volume) { _, newValue in
            localVolume = newValue
        }
    }

}

private struct DeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let icon: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 20)

                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AudioOutputPopup_Previews: PreviewProvider {
    static var previews: some View {
        AudioOutputPopup()
            .background(Color.black)
            .previewLayout(.sizeThatFits)
    }
}
