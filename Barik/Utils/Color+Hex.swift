import SwiftUI

extension Color {
    /// Initialize from a hex string like "#62BA46" or "62BA46".
    /// Supports 6-digit (RGB) and 8-digit (RRGGBBAA) formats.
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        switch hex.count {
        case 6:
            self.init(
                red:   Double((value >> 16) & 0xFF) / 255,
                green: Double((value >>  8) & 0xFF) / 255,
                blue:  Double( value        & 0xFF) / 255
            )
        case 8:
            self.init(
                red:     Double((value >> 24) & 0xFF) / 255,
                green:   Double((value >> 16) & 0xFF) / 255,
                blue:    Double((value >>  8) & 0xFF) / 255,
                opacity: Double( value        & 0xFF) / 255
            )
        default:
            return nil
        }
    }
}
