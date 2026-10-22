import SwiftUI

// The prototype's Home: the screen the app opens on and the one ⌂ returns to from every page. Its bubbles are the Garden,
// the recurring patterns across the dreams; a bubble opens the pattern's page.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var model = JournalModel()
    @State private var patterns = PatternsModel()
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Eyebrow("A little space for your inner world")
                    PageHeading("Your dreams, connected.", lede: "Notice what stays with you.")
                    if let latest = model.rows.first(where: { $0.item != nil }) { latestCard(latest) }
                    if let findings = patterns.response?.findings, !findings.isEmpty {
                        BubbleCluster(bubbles: findings.map { Bubble(id: $0.groupId, label: $0.name, weight: Double($0.supportingDreams)) }) {
                            path.append(PatternRoute(groupId: $0))
                        }
                        .padding(.vertical, 8)
                    }
                    Button("Type a dream") { app.newDream = EntryRoute(id: newID()) }
                        .buttonStyle(.primaryWide).accessibilityIdentifier("typeDream")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .page(Header("DreamLog") { HomeButton() })
            .routeDestinations()
            .navigationDestination(for: PatternRoute.self) { route in PatternDetailView(groupId: route.groupId, model: patterns) }
            .reloadable { await load() }
            .task { await load() }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await load() } } }
            .onChange(of: app.refreshes) { Task { await load() } }
            .onChange(of: app.homeVisits) { path = NavigationPath() }
        }
    }
    private func load() async {
        async let dreams: Void = model.load(app)
        async let findings: Void = patterns.load(app)
        _ = await (dreams, findings)
    }
    private func latestCard(_ row: JournalRow) -> some View {
        NavigationLink(value: Route.dream(row.id)) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(row.date == journalDate() ? "Today's dream" : "Latest dream")
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.heading)
                        if !row.preview.isEmpty { Text(row.preview).font(.callout).foregroundStyle(Color.muted).lineLimit(3) }
                    }
                    Spacer(minLength: 0)
                    Text(glyph(row.item?.mood)).font(.glyph).foregroundStyle(Color.motif)
                }
            }
            .multilineTextAlignment(.leading)
            .card()
        }.buttonStyle(.plain)
    }
}
