import Carbon
import Foundation

class InputSourceManager: ObservableObject {
    static let shared = InputSourceManager()

    @Published private(set) var sourceID: String = ""

    private init() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { self.refresh() }
    }

    private func refresh() {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        sourceID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
    }

    func cycleLatinScript() {
        cycle(["com.apple.keylayout.US", "com.apple.keylayout.Czech-QWERTY"])
    }

    func cycleCyrillicScript() {
        cycle(["com.apple.keylayout.Ukrainian-QWERTY", "com.apple.keylayout.Russian-Phonetic"])
    }

    private func cycle(_ sourceIDs: [String]) {
        let next = sourceIDs.firstIndex(of: sourceID).map { ($0 + 1) % sourceIDs.count } ?? 0
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first(where: { inputSourceID($0) == sourceIDs[next] }) else { return }
        TISSelectInputSource(source)
    }

    private func inputSourceID(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    /// Short label shown in the badge, e.g. "US", "CZ", "УК", "РУ"
    var label: String {
        switch sourceID {
        case "com.apple.keylayout.US":               return "US"
        case "com.apple.keylayout.Czech-QWERTY":     return "CZ"
        case "com.apple.keylayout.Ukrainian-QWERTY": return "УК"
        case "com.apple.keylayout.Russian-Phonetic": return "РУ"
        default:
            // Fallback: last path component of the ID, truncated to 2 chars
            let last = sourceID.split(separator: ".").last.map(String.init) ?? sourceID
            return String(last.prefix(2)).uppercased()
        }
    }
}
