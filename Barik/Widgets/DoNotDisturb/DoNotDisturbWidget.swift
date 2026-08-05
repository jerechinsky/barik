import SwiftUI

struct DoNotDisturbWidget: View {
    @ObservedObject private var manager = DoNotDisturbManager.shared

    var body: some View {
        Image(systemName: "moon.fill")
            .font(.system(size: 14))
            .foregroundStyle(.foregroundOutside)
            .frame(maxHeight: .infinity)
            .help("Do Not Disturb is on")
            .accessibilityLabel("Do Not Disturb is on")
    }
}

@MainActor
final class DoNotDisturbManager: ObservableObject {
    static let shared = DoNotDisturbManager()

    @Published private(set) var isActive = false

    private static let modeIdentifier = "com.apple.donotdisturb.mode.default"
    private let assertionsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json").path
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var process: Process?

    private init() {
        #if DEBUG
        let sample = Data(
            #"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}"#.utf8
        )
        assert(Self.isDNDActive(in: sample))
        assert(!Self.isDNDActive(in: Data(#"{"data":[]}"#.utf8)))
        #endif
        refresh()
        startWatching()
    }

    deinit {
        fileWatchSource?.cancel()
        process?.terminate()
    }

    func toggle() {
        guard process == nil else { return }
        refresh()
        runShortcut(named: isActive ? "Barik DND Off" : "Barik DND On")
    }

    private func runShortcut(named shortcutName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.refresh()
            }
        }

        do {
            self.process = process
            try process.run()
        } catch {
            self.process = nil
            print("Could not toggle Do Not Disturb: \(error)")
        }
    }

    private func refresh() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: assertionsPath)) else {
            return
        }
        isActive = Self.isDNDActive(in: data)
    }

    private func startWatching() {
        fileWatchSource?.cancel()
        let descriptor = open(assertionsPath, O_EVTONLY)
        guard descriptor != -1 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let needsReattach = !source.data.intersection([.rename, .delete]).isEmpty
            Task { @MainActor in
                self.refresh()
                if needsReattach { self.startWatching() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        fileWatchSource = source
        source.resume()
    }

    private static func isDNDActive(in data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stores = root["data"] as? [[String: Any]]
        else { return false }

        let modes = stores.flatMap { store in
            (store["storeAssertionRecords"] as? [[String: Any]] ?? []).compactMap {
                ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"]
                    as? String
            }
        }
        return modes.contains(modeIdentifier)
    }
}
