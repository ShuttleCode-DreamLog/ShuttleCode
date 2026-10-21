import SwiftUI
import UIKit

// DreamLog_User_Test.html visual system: ink on paper, one sage-green primary, serif headings, bordered cards and eyebrow labels.
private func shade(_ light: UInt32, _ dark: UInt32) -> UIColor {
    let channel = { (hex: UInt32, shift: UInt32) in CGFloat(hex >> shift & 0xFF) / 255 }
    let color = { (hex: UInt32) in UIColor(red: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1) }
    return UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
}
let inkColor = shade(0x303C39, 0xE6E9E4)
let paperColor = shade(0xFAF9F5, 0x1B201E)
let lineColor = shade(0xE0E5DC, 0x363F3A)

extension Color {
    static let ink = Color(uiColor: inkColor)
    static let paper = Color(uiColor: paperColor)
    static let line = Color(uiColor: lineColor)
    static let muted = Color(uiColor: shade(0x7B8882, 0x9AA59F))
    static let sage = Color(uiColor: shade(0x527666, 0x8FB39F))
    static let card = Color(uiColor: shade(0xFFFEFA, 0x232927))
    static let soft = Color(uiColor: shade(0xEEF2E9, 0x2A332E))
    static let danger = Color(uiColor: shade(0xA45650, 0xD98A84))
    static let motif = Color(uiColor: shade(0x93A684, 0x6F8A6B))
    static let bubble = Color(uiColor: shade(0xB9C7AA, 0x5E7360))
}

extension Font {
    static let display = Font.system(.title, design: .serif)
    static let heading = Font.system(.title3, design: .serif)
    static let glyph = Font.system(size: 56, design: .serif)
}

// Serif titles in the navigation bar, as the prototype's Georgia headers, on paper instead of the system bar material.
// Roots use inline titles: their page heading is the prototype's h2 in the content, and iOS 27 did not draw a styled large title.
func applyHeaderStyle() {
    let bar = UINavigationBar.appearance()
    bar.standardAppearance = headerAppearance(hairline: true)
    bar.scrollEdgeAppearance = headerAppearance(hairline: false)
}

private func headerAppearance(hairline: Bool) -> UINavigationBarAppearance {
    let serif = { (style: UIFont.TextStyle) in
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
        return UIFont(descriptor: base.withDesign(.serif) ?? base, size: base.pointSize)
    }
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = paperColor
    appearance.shadowColor = hairline ? lineColor : .clear
    appearance.titleTextAttributes = [.font: serif(.headline), .foregroundColor: inkColor]
    return appearance
}

extension View {
    func dreamPage() -> some View { foregroundStyle(Color.ink).background(Color.paper.ignoresSafeArea()) }
    func card() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.line))
    }
    func field() -> some View {
        padding(12).background(Color.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
    }
    func switchRow() -> some View {
        padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
    // Pull to refresh on a ScrollView (iOS 27) cancels its task as soon as the content changes, which turned the in-flight
    // load into "interrupted" and emptied the list; the load runs in its own task so the pull only ends the spinner.
    func reloadable(_ load: @escaping @MainActor () async -> Void) -> some View {
        refreshable { await Task { await load() }.value }
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(Color.sage) }
}

struct PageHeading: View {
    let title: String
    let lede: String?
    init(_ title: String, lede: String? = nil) { self.title = title; self.lede = lede }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.display)
            if let lede { Hint(lede) }
        }
    }
}

struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.heading).padding(.top, 14) }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(Color.muted) }
}

struct Pill: View {
    let text: String
    var struck = false
    init(_ text: String, struck: Bool = false) { self.text = text; self.struck = struck }
    var body: some View {
        Text(text).strikethrough(struck).font(.caption2).foregroundStyle(struck ? Color.muted : Color.ink)
            .padding(.horizontal, 9).padding(.vertical, 3).background(Color.soft, in: Capsule())
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { HStack { Hint(title); Spacer(); content }.padding(.vertical, 4) }
}

struct ErrorCard: View {
    let text: String
    var retryTitle = "Try again"
    var retry: (() -> Void)?
    init(_ text: String, retryTitle: String = "Try again", retry: (() -> Void)? = nil) { self.text = text; self.retryTitle = retryTitle; self.retry = retry }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.callout).foregroundStyle(Color.danger)
            if let retry { Button(retryTitle, action: retry).buttonStyle(.secondary) }
        }.card()
    }
}

struct EmptyCard: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.heading)
            Hint(text)
        }.card()
    }
}

struct PrimaryButton: ButtonStyle {
    var wide = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.medium)).foregroundStyle(.white)
            .frame(maxWidth: wide ? .infinity : nil).padding(.vertical, 12).padding(.horizontal, 19)
            .background(Color.sage, in: RoundedRectangle(cornerRadius: 13))
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.5)
    }
}

struct SecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout).foregroundStyle(configuration.role == .destructive ? Color.danger : Color.ink)
            .padding(.vertical, 10).padding(.horizontal, 15)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.5)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout).foregroundStyle(configuration.role == .destructive ? Color.danger : Color.sage)
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == PrimaryButton {
    static var primary: PrimaryButton { PrimaryButton() }
    static var primaryWide: PrimaryButton { PrimaryButton(wide: true) }
}
extension ButtonStyle where Self == SecondaryButton { static var secondary: SecondaryButton { SecondaryButton() } }
extension ButtonStyle where Self == QuietButton { static var quiet: QuietButton { QuietButton() } }

// Rows of pills or bubbles that wrap like inline elements.
struct Wrap: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0, points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

// The prototype's card motifs, chosen by the dream's mood.
func glyph(_ mood: Mood?) -> String {
    switch mood {
    case .happy: "❀"
    case .calm: "☾"
    case .excited: "✦"
    case .confused: "❂"
    case .sad: "❆"
    case .anxious: "✧"
    case .afraid: "☽"
    case .angry: "✶"
    case .unknown, nil: "✺"
    }
}

nonisolated func displayDate(_ value: String) -> String { journalDay(value).formatted(date: .abbreviated, time: .omitted) }
nonisolated func shortDate(_ value: String) -> String { journalDay(value).formatted(.dateTime.month(.abbreviated).day()) }
