import AppKit

protocol SpaceModel: Identifiable, Equatable, Codable {
    associatedtype WindowType: WindowModel
    var isFocused: Bool { get set }
    var windows: [WindowType] { get set }
}

protocol WindowModel: Identifiable, Equatable, Codable {
    var id: Int { get }
    var title: String { get }
    var appName: String? { get }
    var isFocused: Bool { get }
    var appIcon: NSImage? { get set }
}

protocol SpacesProvider {
    associatedtype SpaceType: SpaceModel
    func getSpacesWithWindows() -> [SpaceType]?
    /// Fast single-query path: returns just the currently focused space ID.
    func getFocusedSpaceId() -> String?
}

protocol SwitchableSpacesProvider: SpacesProvider {
    func focusSpace(spaceId: String, needWindowFocus: Bool)
    func focusWindow(windowId: String)
    func closeWindow(windowId: String)
}

protocol MovableWindowsProvider: SpacesProvider {
    func moveWindow(windowId: Int, toSpace: String) -> Bool
    func swapWindows(_ first: Int, _ second: Int) -> Bool
    func arrangeWindow(_ id: Int, relativeTo target: Int, direction: String?, detachFirst: Bool) -> Bool
}

struct AnyWindow: Identifiable, Equatable {
    let id: Int
    let title: String
    let appName: String?
    var isFocused: Bool
    let appIcon: NSImage?
    let stackIndex: Int
    let frame: CGRect?

    init<W: WindowModel>(_ window: W) {
        self.id = window.id
        self.title = window.title
        self.appName = window.appName
        self.isFocused = window.isFocused
        self.appIcon = window.appIcon
        if let yabaiWindow = window as? YabaiWindow {
            self.stackIndex = yabaiWindow.stackIndex
            self.frame = yabaiWindow.frame.map {
                CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)
            }
        } else {
            self.stackIndex = 0
            self.frame = nil
        }
    }

    static func == (lhs: AnyWindow, rhs: AnyWindow) -> Bool {
        return lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.appName == rhs.appName && lhs.isFocused == rhs.isFocused
            && lhs.stackIndex == rhs.stackIndex && lhs.frame == rhs.frame
    }
}

struct AnySpace: Identifiable, Equatable {
    let id: String
    let isFocused: Bool
    var windows: [AnyWindow]
    let displayIndex: Int?

    init(id: String, isFocused: Bool, windows: [AnyWindow], displayIndex: Int? = nil) {
        self.id = id
        self.isFocused = isFocused
        self.windows = windows
        self.displayIndex = displayIndex
    }

    init<S: SpaceModel>(_ space: S) {
        if let aero = space as? AeroSpace {
            self.id = aero.workspace
            self.displayIndex = nil
        } else if let yabai = space as? YabaiSpace {
            self.id = String(yabai.id)
            self.displayIndex = yabai.display
        } else {
            self.id = "0"
            self.displayIndex = nil
        }
        self.isFocused = space.isFocused
        self.windows = space.windows.map { AnyWindow($0) }
    }

    static func == (lhs: AnySpace, rhs: AnySpace) -> Bool {
        return lhs.id == rhs.id && lhs.isFocused == rhs.isFocused
            && lhs.windows == rhs.windows && lhs.displayIndex == rhs.displayIndex
    }
}

class AnySpacesProvider {
    private let _getSpacesWithWindows: () -> [AnySpace]?
    private let _getFocusedSpaceId: () -> String?
    private let _focusSpace: ((String, Bool) -> Void)?
    private let _focusWindow: ((String) -> Void)?
    private let _closeWindow: ((String) -> Void)?
    private let movable: (any MovableWindowsProvider)?

    init<P: SpacesProvider>(_ provider: P) {
        movable = provider as? any MovableWindowsProvider
        _getSpacesWithWindows = {
            provider.getSpacesWithWindows()?.map { AnySpace($0) }
        }
        _getFocusedSpaceId = {
            provider.getFocusedSpaceId()
        }
        if let switchable = provider as? any SwitchableSpacesProvider {
            _focusSpace = { spaceId, needWindowFocus in
                switchable.focusSpace(
                    spaceId: spaceId, needWindowFocus: needWindowFocus)
            }
            _focusWindow = { windowId in
                switchable.focusWindow(windowId: windowId)
            }
            _closeWindow = { windowId in
                switchable.closeWindow(windowId: windowId)
            }
        } else {
            _focusSpace = nil
            _focusWindow = nil
            _closeWindow = nil
        }
    }

    func getSpacesWithWindows() -> [AnySpace]? {
        _getSpacesWithWindows()
    }

    func getFocusedSpaceId() -> String? {
        _getFocusedSpaceId()
    }

    func focusSpace(spaceId: String, needWindowFocus: Bool) {
        _focusSpace?(spaceId, needWindowFocus)
    }

    func focusWindow(windowId: String) {
        _focusWindow?(windowId)
    }

    func moveWindow(_ id: Int, toSpace: String) -> Bool {
        movable?.moveWindow(windowId: id, toSpace: toSpace) ?? false
    }
    func arrangeWindow(_ id: Int, relativeTo target: Int, direction: String?, detachFirst: Bool) -> Bool {
        movable?.arrangeWindow(id, relativeTo: target, direction: direction, detachFirst: detachFirst) ?? false
    }
    func swapWindows(_ first: Int, _ second: Int) -> Bool {
        movable?.swapWindows(first, second) ?? false
    }

    func closeWindow(windowId: String) {
        _closeWindow?(windowId)
    }
}
