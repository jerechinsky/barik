// ABOUTME: Compact OnePlus status widget with quick click and contextual automation controls

import SwiftUI

struct OnePlusWidget: View {
    @ObservedObject private var manager = OnePlusManager.shared

    var body: some View {
        if manager.isConnected {
            Image(systemName: manager.isScreenless ? "iphone.gen3.slash" : "iphone.gen3")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 16, height: 16)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(manager.isScreenless ? Color.indigo : Color.green)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
                .foregroundStyle(.foregroundOutside)
                .opacity(manager.isBusy ? 0.45 : 1)
                .shadow(color: .foregroundShadowOutside, radius: 3)
                .experimentalConfiguration(cornerRadius: 15)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(.black.opacity(0.001))
                .onTapGesture { manager.toggleScreen() }
                .contextMenu { controls }
                .help(manager.helpText)
                .accessibilityLabel("OnePlus 7 controls")
                .accessibilityValue(manager.isScreenless ? "Connected, OLED off" : "Connected, OLED on")
                .accessibilityAction { manager.toggleScreen() }
                .animation(.easeInOut(duration: 0.15), value: manager.isScreenless)
                .animation(.easeInOut(duration: 0.15), value: manager.isBusy)
        }
    }

    @ViewBuilder
    private var controls: some View {
        Button(manager.isScreenless ? "Turn OLED On" : "Turn OLED Off",
               systemImage: manager.isScreenless ? "sun.max.fill" : "moon.fill") {
            manager.toggleScreen()
        }
        Button("Use 20-minute Auto Mode", systemImage: "timer") {
            manager.useAutomaticDisplayMode()
        }

        Divider()

        Button("Open Skip Pay", systemImage: "creditcard.fill") {
            manager.launchSkipPay()
        }
        Button("Go to Home Screen", systemImage: "house.fill") {
            manager.goHome()
        }
        Button("Run Raffle Now", systemImage: "party.popper.fill") {
            manager.runRaffle()
        }
        .disabled(!manager.hasRaffleScript)

        Divider()

        Button("Take Screenshot", systemImage: "camera.fill") {
            manager.takeScreenshot()
        }
        Button("Save UI Snapshot", systemImage: "viewfinder") {
            manager.saveUISnapshot()
        }
        Button("Open Captures", systemImage: "folder.fill") {
            manager.openCaptureFolder()
        }

        Divider()

        Button("Restart Screenless Service", systemImage: "arrow.clockwise") {
            manager.restartScreenlessService()
        }
        Button("Copy ADB Command", systemImage: "terminal.fill") {
            manager.copyADBCommand()
        }

        Divider()

        Text(manager.lastMessage)
    }
}
