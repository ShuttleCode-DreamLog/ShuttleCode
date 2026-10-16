import SwiftUI
import UIKit

// EGMUIUX E-DB visual system: neutrals on a faint lavender page plus one dusk-lavender primary for main actions, selection and On switches.
extension Color {
    static let dusk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.81, green: 0.74, blue: 1, alpha: 1) : UIColor(red: 0x67 / 255, green: 0x50 / 255, blue: 0xA4 / 255, alpha: 1) })
    static let duskFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.23, green: 0.2, blue: 0.31, alpha: 1) : UIColor(red: 0xF1 / 255, green: 0xEC / 255, blue: 0xF8 / 255, alpha: 1) })
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGroupedBackground : UIColor(red: 0xF5 / 255, green: 0xF1 / 255, blue: 0xFB / 255, alpha: 1) })
}

extension View {
    func dreamPage() -> some View { scrollContentBackground(.hidden).background(Color.page) }
}

nonisolated func displayDate(_ value: String) -> String { journalDay(value).formatted(date: .abbreviated, time: .omitted) }
