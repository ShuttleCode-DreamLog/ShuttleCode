import SwiftUI
import UIKit

// The prototype's header: a left-aligned serif title between the page's leading and trailing controls, on paper with a hairline.
struct Header<Leading: View, Trailing: View>: View {
    let title: String
    let onTitle: (() -> Void)?
    let leading: Leading
    let trailing: Trailing
    init(_ title: String, onTitle: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.onTitle = onTitle; self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            leading
            if let onTitle {
                Button(action: onTitle) {
                    HStack(spacing: 6) {
                        titleText
                        Image(systemName: "pencil").font(.callout).foregroundStyle(Color.muted)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("dreamTitle")
            } else { titleText }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.top, 14).padding(.horizontal, 20).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paper.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
    private var titleText: some View {
        Text(title).font(.system(size: 29, design: .serif)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.6)
    }
}

extension Header where Leading == EmptyView {
    init(_ title: String, onTitle: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, onTitle: onTitle, leading: { EmptyView() }, trailing: trailing)
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

// The prototype's bottom bar: four screens and the + that opens the dream editor.
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            item("Journal", "list.bullet.rectangle.portrait", .journal)
            item("Pattern", "lightbulb", .patterns)
            Button { app.newDream = EntryRoute(id: newID()) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 42, height: 32).background(Color.sage, in: RoundedRectangle(cornerRadius: 12))
                    Text("Add dream").font(.caption2).foregroundStyle(Color.muted)
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
