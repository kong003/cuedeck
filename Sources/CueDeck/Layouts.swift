import SwiftUI

/// Lays out views left to right and wraps onto a new line when the row is
/// full, so controls never squash or clip in narrow windows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    var alignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = maxWidth.isFinite ? min(widest, maxWidth) : widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Group into lines first so each line can be vertically aligned.
        var lines: [[(Subviews.Element, CGSize)]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((view, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let height = line.map(\.1.height).max() ?? 0
            var lx = bounds.minX
            for (view, size) in line {
                let dy: CGFloat
                switch alignment {
                case .top: dy = 0
                case .bottom: dy = height - size.height
                default: dy = (height - size.height) / 2
                }
                view.place(at: CGPoint(x: lx, y: y + dy), anchor: .topLeading, proposal: ProposedViewSize(size))
                lx += size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}
