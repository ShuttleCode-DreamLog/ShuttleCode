import SwiftUI

struct Bubble: Identifiable {
    let id: String
    let label: String
    let weight: Double
    var dashed = false
}

// Translucent glass bubbles packed into one cluster, each drifting a little like a real bubble: the Garden of patterns on
// Home and on the Patterns screen.
struct BubbleCluster: View {
    let bubbles: [Bubble]
    var selected: String?
    let select: (String) -> Void
    private static let tints: [Color] = [.tintYellow, .tintGreen, .tintBlue, .tintLavender, .tintPeach]
    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ClusterLayout {
                ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                    BubbleView(bubble: bubble, tint: Self.tints[index % Self.tints.count], chosen: bubble.id == selected, phase: index) { select(bubble.id) }
                        .layoutValue(key: ClusterLayout.Weight.self, value: bubble.weight)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// One bubble drifts between two offsets forever; Core Animation interpolates the motion, so the view draws no frames itself.
private struct BubbleView: View {
    let bubble: Bubble
    let tint: Color
    let chosen: Bool
    let phase: Int
    let select: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var afloat = false
    private static let drifts: [(CGSize, CGSize)] = [
        (CGSize(width: -4, height: 4), CGSize(width: 5, height: -4)), (CGSize(width: 4, height: 3), CGSize(width: -5, height: -3)),
        (CGSize(width: -3, height: -4), CGSize(width: 3, height: 5)), (CGSize(width: 5, height: -2), CGSize(width: -4, height: 4))
    ]
    var body: some View {
        let drift = Self.drifts[phase % Self.drifts.count]
        Button(action: select) {
            Text(bubble.label).font(.system(size: 18, design: .serif)).foregroundStyle(Color.ink)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6).padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular.tint(tint.opacity(chosen ? 0.9 : 0.55)), in: .circle)
                .overlay(Circle().strokeBorder(chosen ? Color.sage : Color.bubble, style: StrokeStyle(lineWidth: chosen ? 2 : 1, dash: bubble.dashed ? [4, 3] : [])))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .offset(reduceMotion ? .zero : afloat ? drift.1 : drift.0)
        // Scoped to the offset: a withAnimation(.repeatForever) in onAppear leaks into every transaction, including the
        // scroll view's, which then could not be scrolled past the cluster.
        .animation(reduceMotion ? nil : .easeInOut(duration: 2.8 + Double(phase % 3) * 0.6).delay(Double(phase) * 0.3).repeatForever(autoreverses: true), value: afloat)
        .onAppear { afloat = true }
    }
}

// Greedy packing: the heaviest bubble sits at the center and each next one walks outwards until it overlaps the placed
// ones by a fifth at most; the cluster is then scaled down to the width it is given.
nonisolated struct ClusterLayout: Layout {
    struct Weight: LayoutValueKey { static let defaultValue = 1.0 }
    private struct Disc { var center: CGPoint; var radius: CGFloat }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        pack(subviews, width: proposal.width ?? 360).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, disc) in zip(subviews, pack(subviews, width: bounds.width).discs) {
            subview.place(at: CGPoint(x: bounds.minX + disc.center.x, y: bounds.minY + disc.center.y), anchor: .center,
                          proposal: ProposedViewSize(width: disc.radius * 2, height: disc.radius * 2))
        }
    }
    private func pack(_ subviews: Subviews, width: CGFloat) -> (discs: [Disc], size: CGSize) {
        let weights = subviews.map { $0[Weight.self] }
        guard let largest = weights.max(), largest > 0 else { return ([], .zero) }
        var discs: [Disc] = []
        for (index, weight) in weights.enumerated() {
            let radius = 36 + 24 * CGFloat(weight / largest)
            var distance: CGFloat = 0
            var center = CGPoint.zero
            search: while true {
                for step in 0..<36 {
                    let angle = CGFloat(step) / 36 * 2 * .pi + CGFloat(index) * 2.4
                    let candidate = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
                    if discs.allSatisfy({ hypot(candidate.x - $0.center.x, candidate.y - $0.center.y) >= ($0.radius + radius) * 0.8 }) {
                        center = candidate
                        break search
                    }
                }
                distance += 4
            }
            discs.append(Disc(center: center, radius: radius))
        }
        let minX = discs.map { $0.center.x - $0.radius }.min() ?? 0, maxX = discs.map { $0.center.x + $0.radius }.max() ?? 0
        let minY = discs.map { $0.center.y - $0.radius }.min() ?? 0, maxY = discs.map { $0.center.y + $0.radius }.max() ?? 0
        let scale = min(1, width / max(1, maxX - minX))
        let fitted = discs.map { Disc(center: CGPoint(x: ($0.center.x - minX) * scale, y: ($0.center.y - minY) * scale), radius: $0.radius * scale) }
        return (fitted, CGSize(width: (maxX - minX) * scale, height: (maxY - minY) * scale))
    }
}
