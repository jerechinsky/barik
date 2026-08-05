import AppKit

struct YabaiWindowFrame: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
}

struct YabaiWindow: WindowModel {
    let id: Int
    let title: String
    let appName: String?
    var isFocused: Bool
    let stackIndex: Int
    var appIcon: NSImage?
    let isHidden: Bool
    let isVisible: Bool
    let isFloating: Bool
    let isSticky: Bool
    let opacity: Float
    let spaceId: Int
    let frame: YabaiWindowFrame?
    let role: String
    let subrole: String

    enum CodingKeys: String, CodingKey {
        case id
        case spaceId = "space"
        case title
        case appName = "app"
        case isFocused = "has-focus"
        case stackIndex = "stack-index"
        case isHidden = "is-hidden"
        case isVisible = "is-visible"
        case isFloating = "is-floating"
        case isSticky = "is-sticky"
        case opacity
        case frame
        case role
        case subrole
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        spaceId = try container.decode(Int.self, forKey: .spaceId)
        title =
            try container.decodeIfPresent(String.self, forKey: .title)
            ?? "Unnamed"
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        isFocused = try container.decode(Bool.self, forKey: .isFocused)
        stackIndex =
            try container.decodeIfPresent(Int.self, forKey: .stackIndex) ?? 0
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isFloating = try container.decode(Bool.self, forKey: .isFloating)
        isSticky = try container.decode(Bool.self, forKey: .isSticky)
        opacity = try container.decode(Float.self, forKey: .opacity)
        frame = try container.decodeIfPresent(YabaiWindowFrame.self, forKey: .frame)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "AXWindow"
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole) ?? "AXStandardWindow"
        if let name = appName {
            appIcon = IconCache.shared.icon(for: name)
        }
    }
}

struct YabaiSpace: SpaceModel {
    typealias WindowType = YabaiWindow
    let id: Int
    var isFocused: Bool
    let display: Int
    var windows: [YabaiWindow] = []

    enum CodingKeys: String, CodingKey {
        case id = "index"
        case isFocused = "has-focus"
        case display
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        isFocused = try container.decode(Bool.self, forKey: .isFocused)
        display = try container.decodeIfPresent(Int.self, forKey: .display) ?? 1
    }
}
