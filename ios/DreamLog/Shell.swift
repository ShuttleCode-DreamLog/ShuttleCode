import SwiftUI
import UIKit

// The prototype's header: a left-aligned serif title between the page's leading and trailing controls, on paper with a hairline.
struct Header<Leading: View, Trailing: View>: View {
    let title: String
    var editableTitle: Binding<String>? = nil
    var isEditing = false
    let leading: Leading
    let trailing: Trailing
    init(_ title: String, editableTitle: Binding<String>? = nil, isEditing: Bool = false, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.editableTitle = editableTitle; self.isEditing = isEditing; self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            leading
            if let editableTitle {
                InlineEditableText(text: editableTitle, isEditing: isEditing, placeholder: title, singleLine: true)
                    .font(.system(size: 29, design: .serif)).foregroundStyle(Color.ink)
                    .accessibilityIdentifier("editablePageTitle")
            } else {
                Text(title).font(.system(size: 29, design: .serif)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.6)
            }
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
    }
}

extension View {
    func page(_ header: some View, aboveBar: Bool = true) -> some View { modifier(Page(header: header, aboveBar: aboveBar)) }
}

// The prototype's bottom bar: four screens and the + that opens the dream editor, or the note editor on Life notes.
// Patterns' + reads Add pattern and still opens the dream editor.
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let addsNote = app.tab == .notes && !app.showingHome
        HStack(alignment: .top, spacing: 0) {
            item("Journal", "list.bullet.rectangle.portrait", .journal)
            item("Pattern", "lightbulb", .patterns)
            Button { if addsNote { app.newNote = EntryRoute(id: newID()) } else { app.newDream = EntryRoute(id: newID()) } } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 42, height: 32).background(Color.sage, in: RoundedRectangle(cornerRadius: 12))
                    Text(addLabel).font(.caption2).foregroundStyle(Color.muted)
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
                Text(title).font(.caption2)
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

// Reading and editing share the same layout; a field only appears after a double tap.
struct InlineEditableText: View {
    @Binding var text: String
    let isEditing: Bool
    var placeholder = ""
    var singleLine = false
    @State private var active = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing && active {
                TextField(placeholder, text: $text, axis: singleLine ? .horizontal : .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { if singleLine { active = false } }
            } else {
                Text(text.isEmpty ? placeholder : text)
                    .lineLimit(singleLine ? 1 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if isEditing { active = true } }
                    .accessibilityHint(isEditing ? "Double tap to edit" : "")
                    .accessibilityAction(named: "Edit text") { if isEditing { active = true } }
            }
        }
        .onChange(of: isEditing) { _, editing in if !editing { active = false; focused = false } }
        .onChange(of: focused) { _, value in if !value { active = false } }
    }
}

// A short wave travels across the characters, then pauses before starting again.
private struct EditingWaveText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date.now
    private let message = "edit in progress..."

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            HStack(spacing: 0) {
                ForEach(Array(message.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .offset(y: reduceMotion ? 0 : waveOffset(at: index, elapsed: elapsed))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Color.muted)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private func waveOffset(at index: Int, elapsed: TimeInterval) -> CGFloat {
        let travelDuration = 1.5
        let pauseDuration = 0.4
        let halfWidth = 2.0
        let time = elapsed.truncatingRemainder(dividingBy: travelDuration + pauseDuration)
        guard time < travelDuration else { return 0 }

        // Start and end outside the text so the whole pulse enters and leaves smoothly.
        let center = -halfWidth + (Double(message.count - 1) + 2 * halfWidth) * time / travelDuration
        let distance = (Double(index) - center) / halfWidth
        guard abs(distance) < 1 else { return 0 }

        let envelope = (1 + cos(.pi * distance)) / 2
        return CGFloat(2.5 * sin(.pi * distance) * envelope)
    }
}

private struct EditingIndicator: ViewModifier {
    @Environment(AppModel.self) private var app
    let editing: Bool
    let aboveBar: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if editing {
                VStack(alignment: .trailing, spacing: 4) {
                    EditingWaveText()
                        .accessibilityIdentifier("editingIndicator")
                    Text("double tap your text to edit.")
                        .font(.caption)
                        .foregroundStyle(Color.muted)
                        .accessibilityLabel("double tap your text to edit.")
                }
                    .multilineTextAlignment(.trailing)
                    .padding(10).background(Color.paper, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.trailing, 20).padding(.bottom, (aboveBar ? app.barHeight : 0) + 10)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func editingIndicator(_ editing: Bool, aboveBar: Bool = true) -> some View {
        modifier(EditingIndicator(editing: editing, aboveBar: aboveBar))
    }
}
