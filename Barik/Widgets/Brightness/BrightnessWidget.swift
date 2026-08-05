import Foundation
import SwiftUI

struct BrightnessWidget: View {
    @ObservedObject private var audioManager = AudioOutputManager.shared
    @ObservedObject private var brightnessManager = BrightnessManager.shared

    var body: some View {
        let volume = Int((audioManager.volume * 100).rounded())
        let brightness = brightnessManager.percentage

        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 0) {
            GridRow {
                Text("V")
                Group {
                    if volume >= 100 {
                        Text("00")
                            .hidden()
                            .overlay(alignment: .leading) {
                                Text("\(volume)").fixedSize()
                            }
                    } else {
                        Text("\(volume)")
                    }
                }
                    .help("Output volume")
            }
            .opacity(audioManager.isMuted ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.15), value: audioManager.isMuted)
            GridRow {
                Text("B")
                Group {
                    if let brightness, brightness >= 100, volume < 100 {
                        Text("00")
                            .hidden()
                            .overlay(alignment: .leading) {
                                Text("\(brightness)").fixedSize()
                            }
                    } else {
                        Text(brightness.map(String.init) ?? "--")
                    }
                }
                    .help("Display brightness")
            }
            .opacity(0.7)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.foregroundOutside)
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
    }
}

private final class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()

    @Published private(set) var percentage: Int?

    private let requestName = Notification.Name("com.betterdisplay.BetterDisplay.request")
    private let responseName = Notification.Name("com.betterdisplay.BetterDisplay.response")
    private let osdName = Notification.Name("pro.betterdisplay.BetterDisplay.osd")
    private var pendingUUID: String?
    private var responseObserver: NSObjectProtocol?
    private var osdObserver: NSObjectProtocol?
    private var timer: Timer?

    private struct Request: Encodable {
        let uuid: String
        let commands: [String]
        let parameters: [String: String?]
    }

    private struct Response: Decodable {
        let uuid: String?
        let result: Bool?
        let payload: String?
    }

    private struct OSDNotification: Decodable {
        let systemIconID: Int?
        let controlTarget: String?
        let value: Double?
        let maxValue: Double?
    }

    private init() {
        #if DEBUG
        assert(Self.percent(from: "0.625") == 63)
        assert(Self.percent(from: "invalid") == nil)
        #endif

        responseObserver = DistributedNotificationCenter.default().addObserver(
            forName: responseName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(notification)
        }
        osdObserver = DistributedNotificationCenter.default().addObserver(
            forName: osdName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleOSD(notification)
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.25
    }

    deinit {
        if let responseObserver {
            DistributedNotificationCenter.default().removeObserver(responseObserver)
        }
        if let osdObserver {
            DistributedNotificationCenter.default().removeObserver(osdObserver)
        }
        timer?.invalidate()
    }

    private func refresh() {
        let uuid = UUID().uuidString
        let request = Request(
            uuid: uuid,
            commands: ["get"],
            parameters: ["displayWithMainStatus": nil, "brightness": nil]
        )
        guard let data = try? JSONEncoder().encode(request),
              let object = String(data: data, encoding: .utf8) else { return }

        pendingUUID = uuid
        DistributedNotificationCenter.default().postNotificationName(
            requestName,
            object: object,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func handle(_ notification: Notification) {
        guard let object = notification.object as? String,
              let response = try? JSONDecoder().decode(
                  Response.self,
                  from: Data(object.utf8)
              ),
              response.uuid == pendingUUID else { return }

        pendingUUID = nil
        percentage = response.result == false ? nil : response.payload.flatMap(Self.percent)
    }

    private func handleOSD(_ notification: Notification) {
        guard let object = notification.object as? String,
              let osd = try? JSONDecoder().decode(
                  OSDNotification.self,
                  from: Data(object.utf8)
              ),
              osd.systemIconID == 1
                  || osd.controlTarget?.lowercased().contains("brightness") == true
        else { return }

        if let value = osd.value,
           let maxValue = osd.maxValue,
           let percent = Self.percent(value: value, maxValue: maxValue) {
            percentage = percent
        } else {
            refresh()
        }
    }

    private static func percent(from payload: String) -> Int? {
        guard let value = Double(payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let percent = percent(value: value, maxValue: 1) else { return nil }
        return percent
    }

    private static func percent(value: Double, maxValue: Double) -> Int? {
        guard value.isFinite, value >= 0, maxValue.isFinite, maxValue > 0 else { return nil }
        return Int((value / maxValue * 100).rounded())
    }
}

struct BrightnessWidget_Previews: PreviewProvider {
    static var previews: some View {
        BrightnessWidget()
            .frame(width: 70, height: 30)
            .background(.gray)
    }
}
