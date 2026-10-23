import SwiftUI

enum GraphStyle {
    static let laneWidth: CGFloat = 14
    static let rowHeight: CGFloat = 22
    static let nodeRadius: CGFloat = 4.5

    static let palette: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.87),
        Color(red: 0.86, green: 0.30, blue: 0.24),
        Color(red: 0.22, green: 0.66, blue: 0.36),
        Color(red: 0.62, green: 0.36, blue: 0.80),
        Color(red: 0.93, green: 0.58, blue: 0.15),
        Color(red: 0.10, green: 0.65, blue: 0.70),
        Color(red: 0.85, green: 0.35, blue: 0.62),
        Color(red: 0.55, green: 0.55, blue: 0.20),
        Color(red: 0.45, green: 0.45, blue: 0.85),
        Color(red: 0.60, green: 0.40, blue: 0.25),
    ]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }

    static func x(_ lane: Int) -> CGFloat { CGFloat(lane) * laneWidth + laneWidth / 2 + 2 }
}

struct GraphCell: View {
    let row: GraphRow
    let isHead: Bool
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let h = size.height
            func y(_ anchor: GraphEdge.Anchor) -> CGFloat {
                switch anchor {
                case .top: 0
                case .middle: h / 2
                case .bottom: h
                }
            }
            for edge in row.edges {
                let start = CGPoint(x: GraphStyle.x(edge.fromLane), y: y(edge.from))
                let end = CGPoint(x: GraphStyle.x(edge.toLane), y: y(edge.to))
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let midY = (start.y + end.y) / 2
                    path.addCurve(to: end,
                                  control1: CGPoint(x: start.x, y: midY),
                                  control2: CGPoint(x: end.x, y: midY))
                }
                context.stroke(path, with: .color(GraphStyle.color(edge.color)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            let center = CGPoint(x: GraphStyle.x(row.nodeLane), y: h / 2)
            let r = GraphStyle.nodeRadius
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            let color = GraphStyle.color(row.nodeColor)
            if isHead {
                context.fill(circle, with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(circle, with: .color(color), lineWidth: 2.5)
            } else {
                context.fill(circle, with: .color(color))
            }
        }
        .frame(width: width, height: GraphStyle.rowHeight)
        .clipped()
    }
}
