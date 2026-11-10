import SwiftUI
import UIKit

// The prototype's header: a left-aligned serif title between the page's leading and trailing controls, on paper with a hairline.
struct Header<Leading: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let trailing: Trailing
    init(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            leading
            Text(title).font(.system(size: 29, design: .serif)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.top, 14).padding(.horizontal, 20).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paper.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

extension Header where Leading == EmptyView {
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, leading: { EmptyView() }, trailing: trailing)
    }
}
extension Header where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: String) { self.init(title, leading: { EmptyView() }, trailing: { EmptyView() }) }
}

struct BackButton: View {
    var label = "Back"
    var action: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { if let action { action() } else { dismiss() } } label: {
            Image(systemName: "chevron.left").font(.system(size: 22)).foregroundStyle(Color.ink).padding(.trailing, 2)
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct HomeButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button { app.goHome() } label: { Image(systemName: "house").font(.system(size: 22)).foregroundStyle(Color.ink) }
            .buttonStyle(.plain).accessibilityLabel("Home")
    }
}

// A page hides the system bar behind the prototype's header, which stays put while the content scrolls, and keeps its
// scrolling content clear of the bottom bar when it is shown inside the shell.
private struct Page<Header: View>: ViewModifier {
    let header: Header
    let aboveBar: Bool
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .contentMargins(.bottom, aboveBar ? app.barHeight : 0, for: .scrollContent)
            .gesture(KeyboardDismissal())
    }
}

// SwiftUI has no tap-outside to put the keyboard away, and a SwiftUI tap on the page would also fire on the text input itself;
// a UIKit tap that ignores touches inside text inputs, cancels nothing and runs beside every other gesture ends editing on
// any other tap while buttons and rows under it still act.
private struct KeyboardDismissal: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.view?.window?.endEditing(true)
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = touch.view else { return true }
            return !sequence(first: view, next: \.superview).contains { $0 is UITextInput }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

extension View {
    func page(_ header: some View, aboveBar: Bool = true) -> some View { modifier(Page(header: header, aboveBar: aboveBar)) }
}

// The prototype's bottom bar: four screens and the + that opens the dream editor, or the note editor on Life notes.
// Patterns' + reads Add pattern and still opens the dream editor.
// Since 10 November 2026 Patterns' + opens the new-pattern sheet: a title and the supporting dreams.
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let addsNote = app.tab == .notes && !app.showingHome
        HStack(alignment: .top, spacing: 0) {
            item("Journal", "list.bullet.rectangle.portrait", .journal)
            item("Pattern", "lightbulb", .patterns)
            Button {
                switch (addsNote, app.tab == .patterns && !app.showingHome) {
                case (true, _): app.newNote = EntryRoute(id: newID())
                case (_, true): app.newPattern = true
                default: app.newDream = EntryRoute(id: newID())
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 42, height: 32).background(Color.sage, in: RoundedRectangle(cornerRadius: 12))
                    // Five equal columns leave about 74 points; a label that wrapped would make the whole bar taller.
                    Text(addLabel).font(.caption2).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(Color.muted)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).accessibilityIdentifier("tab_add")
            item("Life notes", "pencil", .notes)
            item("Settings", "gearshape", .settings)
        }
        .padding(.top, 10).padding(.horizontal, 9).padding(.bottom, 4)
        .background(Color.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.barHeight = $0 }
    }
    // Life notes' + adds a note. Pattern's opens the dream editor too: patterns are found in dreams and cannot be made by hand.
    // Settings and Home keep the core action rather than the last tab's, which the screen would not show.
    private var addLabel: String {
        guard !app.showingHome else { return "Add dream" }
        return switch app.tab {
        case .notes: "Add life note"
        case .patterns: "Add pattern"
        case .journal, .settings: "Add dream"
        }
    }
    private func item(_ title: String, _ icon: String, _ tab: AppTab) -> some View {
        let active = app.tab == tab && !app.showingHome
        return Button { app.tab = tab; app.showingHome = false } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 22)).frame(height: 32)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundStyle(active ? Color.sage : Color.muted)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab_\(tab)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// With the system bar hidden UIKit drops the swipe-back gesture; the stack's own delegate keeps it for pushed pages.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
