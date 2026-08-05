import Foundation
import SwiftUI
import TOMLDecoder

final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published private(set) var config = Config()
    @Published private(set) var initError: String?
    @Published private(set) var rawWidgetsConfig: [String: Any] = [:]
    
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var configFilePath: String?

    private init() {
        loadOrCreateConfigIfNeeded()
    }

    private func loadOrCreateConfigIfNeeded() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let path1 = "\(homePath)/.barik-config.toml"
        let path2 = "\(homePath)/.config/barik/config.toml"
        var chosenPath: String?

        if FileManager.default.fileExists(atPath: path1) {
            chosenPath = path1
        } else if FileManager.default.fileExists(atPath: path2) {
            chosenPath = path2
        } else {
            do {
                try createDefaultConfig(at: path1)
                chosenPath = path1
            } catch {
                initError = "Error creating default config: \(error.localizedDescription)"
                print("Error when creating default config:", error)
                return
            }
        }

        if let path = chosenPath {
            configFilePath = path
            parseConfigFile(at: path)
            startWatchingFile(at: path)
        }
    }

    private func parseConfigFile(at path: String) {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let decoder = TOMLDecoder()
            let rootToml = try decoder.decode(RootToml.self, from: content)
            let rawTable = (try? TOMLDecoder.tomlTable(from: content)) ?? [:]
            let rawWidgets = (rawTable["widgets"] as? [String: Any]) ?? [:]
            let apply = {
                self.config = Config(rootToml: rootToml)
                self.rawWidgetsConfig = rawWidgets
            }
            // Set synchronously if already on main (during init) so values are
            // available before the first SwiftUI render; otherwise dispatch.
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        } catch {
            initError = "Error parsing TOML file: \(error.localizedDescription)"
            print("Error when parsing TOML file:", error)
        }
    }

    private func createDefaultConfig(at path: String) throws {
        let defaultTOML = """
            # If you installed yabai or aerospace without using Homebrew,
            # manually set the path to the binary. For example:
            #
            # yabai.path = "/run/current-system/sw/bin/yabai"
            # aerospace.path = ...
            
            theme = "dark" # system, light, dark, adaptive
            [widgets]
            displayed = [ # widgets on menu bar
                "default.spaces",
                "spacer",
                "default.donotdisturb",
                "default.network",
                "default.battery",
                "divider",
                # { "default.time" = { time-zone = "America/Los_Angeles", format = "E d, hh:mm" } },
                "default.time"
            ]

            [widgets.default.spaces]
            space.show-key = true        # show space number (or character, if you use AeroSpace)
            window.show-title = true
            window.title.max-length = 50

            [widgets.default.battery]
            show-percentage = true
            warning-level = 30
            critical-level = 10

            [widgets.default.time]
            format = "E d, J:mm"
            calendar.format = "J:mm"

            calendar.show-events = true
            # calendar.allow-list = ["Home", "Personal"] # show only these calendars
            # calendar.deny-list = ["Work", "Boss"] # show all calendars except these

            [popup.default.time]
            view-variant = "box"
            
            [background]
            enabled = true
            """
        try defaultTOML.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func startWatchingFile(at path: String) {
        fileWatchSource?.cancel()

        let descriptor = open(path, O_EVTONLY)
        guard descriptor != -1 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global()
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let needsReattach = source.data.intersection([.rename, .delete]).isEmpty == false
            DispatchQueue.main.async {
                guard let path = self.configFilePath else { return }
                self.parseConfigFile(at: path)
                if needsReattach {
                    self.startWatchingFile(at: path)
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileWatchSource = source
        source.resume()
    }

    func updateConfigValue(key: String, newValue: String, quoted: Bool = true) {
        guard let path = configFilePath else {
            print("Config file path is not set")
            return
        }
        do {
            let currentText = try String(contentsOfFile: path, encoding: .utf8)
            let updatedText = Self.updatedTOMLString(
                original: currentText, key: key, newValue: newValue, quoted: quoted)
            try updatedText.write(
                toFile: path, atomically: false, encoding: .utf8)
            DispatchQueue.main.async {
                self.parseConfigFile(at: path)
            }
        } catch {
            print("Error updating config:", error)
        }
    }

    func updateDisplayedWidgets(_ items: [TomlWidgetItem]) {
        guard let path = configFilePath else { return }
        do {
            let currentText = try String(contentsOfFile: path, encoding: .utf8)
            let updatedText = replaceDisplayedArray(in: currentText, with: items)
            try updatedText.write(toFile: path, atomically: true, encoding: .utf8)
            parseConfigFile(at: path)
            // Atomic writes replace the inode, so continue watching the new file.
            startWatchingFile(at: path)
        } catch {
            print("Error updating displayed widgets:", error)
        }
    }

    func openConfigFile() {
        guard let configFilePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: configFilePath))
    }

    private func replaceDisplayedArray(
        in original: String,
        with items: [TomlWidgetItem]
    ) -> String {
        let lines = original.components(separatedBy: "\n")
        var inWidgetsSection = false
        var startIndex: Int?
        var endIndex: Int?
        var bracketDepth = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if startIndex != nil { break }
                inWidgetsSection = trimmed == "[widgets]"
                continue
            }

            if startIndex == nil, inWidgetsSection,
               trimmed.hasPrefix("displayed"), trimmed.contains("=") {
                startIndex = index
            }

            guard startIndex != nil else { continue }
            bracketDepth += line.reduce(into: 0) { depth, character in
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
            }
            if bracketDepth == 0 {
                endIndex = index
                break
            }
        }

        guard let startIndex, let endIndex else { return original }
        var newLines = Array(lines[..<startIndex])
        newLines.append("displayed = \(items.toTomlDisplayedArray())")
        if endIndex + 1 < lines.count {
            newLines.append(contentsOf: lines[(endIndex + 1)...])
        }
        return newLines.joined(separator: "\n")
    }

    private static func updatedTOMLString(
        original: String, key: String, newValue: String, quoted: Bool
    ) -> String {
        let value = quoted ? "\"\(newValue)\"" : newValue
        if key.contains(".") {
            let components = key.split(separator: ".").map(String.init)
            guard components.count >= 2 else {
                return original
            }

            let tablePath = components.dropLast().joined(separator: ".")
            let actualKey = components.last!

            let tableHeader = "[\(tablePath)]"
            let lines = original.components(separatedBy: "\n")
            var newLines: [String] = []
            var insideTargetTable = false
            var updatedKey = false
            var foundTable = false

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    if insideTargetTable && !updatedKey {
                        newLines.append("\(actualKey) = \(value)")
                        updatedKey = true
                    }
                    if trimmed == tableHeader {
                        foundTable = true
                        insideTargetTable = true
                    } else {
                        insideTargetTable = false
                    }
                    newLines.append(line)
                } else {
                    if insideTargetTable && !updatedKey {
                        let pattern =
                            "^\(NSRegularExpression.escapedPattern(for: actualKey))\\s*="
                        if line.range(of: pattern, options: .regularExpression)
                            != nil
                        {
                            newLines.append("\(actualKey) = \(value)")
                            updatedKey = true
                            continue
                        }
                    }
                    newLines.append(line)
                }
            }

            if foundTable && insideTargetTable && !updatedKey {
                newLines.append("\(actualKey) = \(value)")
            }

            if !foundTable {
                newLines.append("")
                newLines.append("[\(tablePath)]")
                newLines.append("\(actualKey) = \(value)")
            }
            return newLines.joined(separator: "\n")
        } else {
            let lines = original.components(separatedBy: "\n")
            var newLines: [String] = []
            var updatedAtLeastOnce = false

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("#") {
                    let pattern =
                        "^\(NSRegularExpression.escapedPattern(for: key))\\s*="
                    if line.range(of: pattern, options: .regularExpression)
                        != nil
                    {
                        newLines.append("\(key) = \(value)")
                        updatedAtLeastOnce = true
                        continue
                    }
                }
                newLines.append(line)
            }
            if !updatedAtLeastOnce {
                newLines.append("\(key) = \(value)")
            }
            return newLines.joined(separator: "\n")
        }
    }

    func rawWidgetConfig(for widgetId: String) -> [String: Any] {
        let keys = widgetId.split(separator: ".").map { String($0) }
        var current: [String: Any] = rawWidgetsConfig
        for key in keys {
            guard let next = current[key] as? [String: Any] else { return [:] }
            current = next
        }
        return current
    }

    func globalWidgetConfig(for widgetId: String) -> ConfigData {
        config.rootToml.widgets.config(for: widgetId) ?? [:]
    }

    func resolvedWidgetConfig(for item: TomlWidgetItem) -> ConfigData {
        let global = globalWidgetConfig(for: item.id)
        if item.inlineParams.isEmpty {
            return global
        }
        var merged = global
        for (key, value) in item.inlineParams {
            merged[key] = value
        }
        return merged
    }
}
