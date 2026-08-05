import Foundation
import SwiftUI

struct RootToml: Decodable {
    var theme: String?
    var yabai: YabaiConfig?
    var aerospace: AerospaceConfig?
    var experimental: ExperimentalConfig?
    var widgets: WidgetsSection
    var builtinDisplay: BuiltinDisplayConfig?

    init() {
        self.theme = nil
        self.yabai = nil
        self.aerospace = nil
        self.widgets = WidgetsSection(displayed: [], others: [:])
        self.builtinDisplay = nil
    }

    enum CodingKeys: String, CodingKey {
        case theme, yabai, aerospace, experimental, widgets
        case builtinDisplay = "builtin-display"
    }
}

struct Config {
    let rootToml: RootToml

    init(rootToml: RootToml = RootToml()) {
        self.rootToml = rootToml
    }

    var theme: String {
        rootToml.theme ?? "dark"
    }

    var yabai: YabaiConfig {
        rootToml.yabai ?? YabaiConfig()
    }

    var aerospace: AerospaceConfig {
        rootToml.aerospace ?? AerospaceConfig()
    }

    var experimental: ExperimentalConfig {
        rootToml.experimental ?? ExperimentalConfig()
    }

    var builtinDisplay: BuiltinDisplayConfig {
        rootToml.builtinDisplay ?? BuiltinDisplayConfig()
    }
}

typealias ConfigData = [String: TOMLValue]

class ConfigProvider: ObservableObject {
    @Published var config: ConfigData

    init(config: ConfigData) {
        self.config = config
    }
}

struct WidgetsSection: Decodable {
    let displayed: [TomlWidgetItem]
    let others: [String: ConfigData]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(
        displayed: [TomlWidgetItem],
        others: [String: ConfigData]
    ) {
        self.displayed = displayed
        self.others = others
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        let displayedKey = DynamicKey(stringValue: "displayed")!
        let displayedArray = try container.decode(
            [TomlWidgetItem].self, forKey: displayedKey)
        self.displayed = displayedArray

        var tempDict = [String: ConfigData]()

        for key in container.allKeys {
            guard key.stringValue != "displayed" else { continue }

            // Decode the entire sub-tree as a TOMLValue in one shot.
            // Using nestedContainer risks missing keys of implicit parent tables
            // (e.g. [widgets.default] never explicitly declared, only its children are).
            if let value = try? container.decode(TOMLValue.self, forKey: key),
               let dict = value.dictionaryValue {
                tempDict[key.stringValue] = dict
            }
        }

        self.others = tempDict
    }

    func config(for widgetId: String) -> ConfigData? {
        let keys = widgetId.split(separator: ".").map { String($0) }
        guard let firstKey = keys.first,
              let topLevel = others[firstKey] else { return nil }

        var current: ConfigData = topLevel
        for key in keys.dropFirst() {
            guard let nested = current[key]?.dictionaryValue else { return nil }
            current = nested
        }
        return current
    }
}

struct TomlWidgetItem: Decodable, Equatable, Hashable {
    let instanceID: UUID
    let id: String
    let inlineParams: ConfigData

    init(id: String, inlineParams: ConfigData) {
        self.instanceID = UUID()
        self.id = id
        self.inlineParams = inlineParams
    }

    init(from decoder: Decoder) throws {
        self.instanceID = UUID()
        let container = try decoder.singleValueContainer()

        if let strValue = try? container.decode(String.self) {
            self.id = strValue
            self.inlineParams = [:]
            return
        }

        let dictValue = try container.decode([String: ConfigData].self)

        guard dictValue.count == 1,
            let (widgetId, params) = dictValue.first
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Uncorrect inline-table in [widgets.displayed]"
                )
            )
        }

        self.id = widgetId
        self.inlineParams = params
    }

    static func == (lhs: TomlWidgetItem, rhs: TomlWidgetItem) -> Bool {
        lhs.instanceID == rhs.instanceID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(instanceID)
    }

    func toTomlString() -> String {
        if inlineParams.isEmpty {
            return "\"\(id.tomlEscaped)\""
        }
        let parameters = inlineParams
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key) = \(value.toTomlValueString())"
            }
            .joined(separator: ", ")
        return "{ \"\(id.tomlEscaped)\" = { \(parameters) } }"
    }
}

extension Array where Element == TomlWidgetItem {
    func toTomlDisplayedArray() -> String {
        let rows = map { "    \($0.toTomlString())" }.joined(separator: ",\n")
        return "[\n\(rows)\n]"
    }
}

enum TOMLValue: Decodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([TOMLValue])
    case dictionary(ConfigData)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let str = try? container.decode(String.self) {
            self = .string(str)
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .double(d)
            return
        }
        if let arr = try? container.decode([TOMLValue].self) {
            self = .array(arr)
            return
        }
        if let dict = try? container.decode(ConfigData.self) {
            self = .dictionary(dict)
            return
        }

        self = .null
    }
}

extension TOMLValue {
    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case let .int(i) = self { return i }
        return nil
    }

    var doubleValue: Double? {
        if case let .double(d) = self { return d }
        if case let .int(i) = self { return Double(i) }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var arrayValue: [TOMLValue]? {
        if case let .array(arr) = self { return arr }
        return nil
    }

    var dictionaryValue: ConfigData? {
        if case let .dictionary(dict) = self { return dict }
        return nil
    }

    func toTomlValueString() -> String {
        switch self {
        case .string(let value):
            return "\"\(value.tomlEscaped)\""
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return "\(value)"
        case .double(let value):
            return "\(value)"
        case .array(let values):
            return "[\(values.map { $0.toTomlValueString() }.joined(separator: ", "))]"
        case .dictionary(let values):
            let content = values.sorted { $0.key < $1.key }
                .map { "\($0.key) = \($0.value.toTomlValueString())" }
                .joined(separator: ", ")
            return "{ \(content) }"
        case .null:
            return "\"\""
        }
    }
}

private extension String {
    var tomlEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct YabaiConfig: Decodable {
    let path: String

    init() {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/yabai") {
            self.path = "/opt/homebrew/bin/yabai"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/yabai") {
            self.path = "/usr/local/bin/yabai"
        } else {
            self.path = "/opt/homebrew/bin/yabai"
        }
    }
}

struct AerospaceConfig: Decodable {
    let path: String

    init() {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/aerospace") {
            self.path = "/opt/homebrew/bin/aerospace"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/aerospace") {
            self.path = "/usr/local/bin/aerospace"
        } else {
            self.path = "/opt/homebrew/bin/aerospace"
        }
    }
}

struct BuiltinDisplayConfig: Decodable {
    let hiddenWidgets: [String]

    init() {
        self.hiddenWidgets = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenWidgets = try container.decodeIfPresent([String].self, forKey: .hiddenWidgets) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case hiddenWidgets = "hidden-widgets"
    }
}

struct ExperimentalConfig: Decodable {
    let foreground: ForegroundConfig
    let background: BackgroundConfig
    
    enum CodingKeys: String, CodingKey {
        case foreground, background
    }
    
    init() {
        self.foreground = ForegroundConfig()
        self.background = BackgroundConfig()
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try container.decodeIfPresent(ForegroundConfig.self, forKey: .foreground) ?? ForegroundConfig()
        background = try container.decodeIfPresent(BackgroundConfig.self, forKey: .background) ?? BackgroundConfig()
    }
}

struct ForegroundConfig: Decodable {
    let height: BackgroundForegroundHeight
    let horizontalPadding: CGFloat
    let widgetsBackground: WidgetBackgroundConfig
    let spacing: CGFloat
    
    init() {
        self.height = .barikDefault
        self.horizontalPadding = Constants.menuBarHorizontalPadding
        self.widgetsBackground = WidgetBackgroundConfig()
        self.spacing = 15
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        height = try container.decodeIfPresent(BackgroundForegroundHeight.self, forKey: .height) ?? .barikDefault
        horizontalPadding = try container.decodeIfPresent(CGFloat.self, forKey: .horizontalPadding) ?? Constants.menuBarHorizontalPadding
        widgetsBackground = try container.decodeIfPresent(WidgetBackgroundConfig.self, forKey: .widgetsBackground) ?? WidgetBackgroundConfig()
        spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 15
    }
    
    enum CodingKeys: String, CodingKey {
        case height
        case horizontalPadding = "horizontal-padding"
        case widgetsBackground = "widgets-background"
        case spacing
    }
    
    func resolveHeight() -> CGFloat {
        switch height {
        case .barikDefault:
            return CGFloat(Constants.menuBarHeight)
        case .menuBar:
            return NSApplication.shared.mainMenu.map({ CGFloat($0.menuBarHeight) }) ?? 0
        case .float(let value):
            return CGFloat(value)
        }
    }
}

struct WidgetBackgroundConfig: Decodable {
    let displayed: Bool
    let blur: Material
    
    init() {
        self.displayed = false
        self.blur = .regular
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        displayed = try container.decodeIfPresent(Bool.self, forKey: .displayed) ?? false
        
        var materialIndex = try container.decodeIfPresent(Int.self, forKey: .blur) ?? 1
        if materialIndex < 1 {
            materialIndex = 1
        } else if materialIndex > 6 {
            materialIndex = 6
        }
        
        blur = [.ultraThin, .thin, .regular, .thick, .ultraThick, .bar][materialIndex - 1]
    }

    enum CodingKeys: String, CodingKey {
        case displayed, height, blur
    }
}

struct BackgroundConfig: Decodable {
    let displayed: Bool
    let height: BackgroundForegroundHeight
    let blur: Material
    let black: Bool

    init() {
        self.displayed = true
        self.height = .barikDefault
        self.blur = .regular
        self.black = false
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayed = try container.decodeIfPresent(Bool.self, forKey: .displayed) ?? true
        height = try container.decodeIfPresent(BackgroundForegroundHeight.self, forKey: .height) ?? .barikDefault
        
        var materialIndex = try container.decodeIfPresent(Int.self, forKey: .blur) ?? 1
        if materialIndex < 1 {
            materialIndex = 1
        } else if materialIndex > 7 {
            materialIndex = 7
        }
        
        blur = [.ultraThin, .thin, .regular, .thick, .ultraThick, .bar, .bar][materialIndex - 1]
        self.black = materialIndex == 7
    }

    enum CodingKeys: String, CodingKey {
        case displayed, height, blur
    }

    func resolveHeight() -> CGFloat? {
        switch height {
        case .barikDefault:
            return nil
        case .menuBar:
            return NSApplication.shared.mainMenu.map({ CGFloat($0.menuBarHeight) }) ?? 0
        case .float(let value):
            return CGFloat(value)
        }
    }
}

enum ForegroundPadding: Decodable {
    case float(Float)
    
    init(from decoder: Decoder) throws {
        if let floatValue = try? decoder.singleValueContainer().decode(Float.self) {
            self = .float(floatValue)
            return
        }
        
        if let intValue = try? decoder.singleValueContainer().decode(Int.self) {
            self = .float(Float(intValue))
            return
        }
        
        throw DecodingError.typeMismatch(
            ForegroundPadding.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a float value"
            )
        )
    }
}

enum BackgroundForegroundHeight: Decodable {
    case barikDefault
    case menuBar
    case float(Float)
    
    init(from decoder: Decoder) throws {
        if let floatValue = try? decoder.singleValueContainer().decode(Float.self) {
            self = .float(floatValue)
            return
        }
        
        if let intValue = try? decoder.singleValueContainer().decode(Int.self) {
            self = .float(Float(intValue))
            return
        }
        
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            if stringValue == "default" {
                self = .barikDefault
                return
            }
            
            if stringValue == "menu-bar" {
                self = .menuBar
                return
            }
            
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected 'default', 'menu-bar' or a float value, but found \(stringValue)"
            )
        }
        
        throw DecodingError.typeMismatch(
            ForegroundPadding.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected 'default', 'menu-bar' or a float value"
            )
        )
    }
}
