import Foundation

/// One line segment of the revision graph within a single row.
/// Rows are split into a top half (row top -> node) and bottom half (node -> row bottom).
struct GraphEdge: Hashable {
    enum Anchor { case top, middle, bottom }

    let fromLane: Int
    let from: Anchor
    let toLane: Int
    let to: Anchor
    let color: Int
}

struct GraphRow {
    let nodeLane: Int
    let nodeColor: Int
    let edges: [GraphEdge]
    let laneCount: Int
}

/// Assigns lanes to commits (given in topological order), Git Extensions style:
/// each lane tracks the commit it is waiting for; a commit takes the lane that expects it,
/// its first parent continues in that lane and further parents open new lanes.
enum GraphLayout {
    private struct Lane {
        var sha: String
        var color: Int
    }

    static func layout(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [Lane?] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            var edges: [GraphEdge] = []
            let before = lanes

            // Lanes that were waiting for this commit converge into it.
            let incoming = before.indices.filter { before[$0]?.sha == commit.sha }
            let nodeLane: Int
            let nodeColor: Int
            if let first = incoming.first {
                nodeLane = first
                nodeColor = before[first]!.color
            } else {
                nodeLane = freeLane()
                nodeColor = nextColor
                nextColor += 1
            }

            for i in incoming {
                edges.append(GraphEdge(fromLane: i, from: .top, toLane: nodeLane, to: .middle, color: before[i]!.color))
                lanes[i] = nil
            }

            // Lanes moved into the node's lane, so the first-parent line stays leftmost.
            var relocated: Set<Int> = []

            // Parents.
            for (index, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0?.sha == parent }) {
                    if index == 0 && existing > nodeLane && lanes[nodeLane] == nil {
                        let lane = lanes[existing]!
                        lanes[existing] = nil
                        lanes[nodeLane] = Lane(sha: lane.sha, color: nodeColor)
                        relocated.insert(existing)
                        edges.append(GraphEdge(fromLane: existing, from: .top, toLane: nodeLane, to: .bottom, color: lane.color))
                        edges.append(GraphEdge(fromLane: nodeLane, from: .middle, toLane: nodeLane, to: .bottom, color: nodeColor))
                        continue
                    }
                    edges.append(GraphEdge(fromLane: nodeLane, from: .middle, toLane: existing, to: .bottom, color: lanes[existing]!.color))
                    continue
                }
                let target: Int
                let color: Int
                if index == 0 && lanes[nodeLane] == nil {
                    target = nodeLane
                    color = nodeColor
                } else {
                    target = freeLane()
                    color = nextColor
                    nextColor += 1
                }
                lanes[target] = Lane(sha: parent, color: color)
                edges.append(GraphEdge(fromLane: nodeLane, from: .middle, toLane: target, to: .bottom, color: color))
            }

            // Pass-through lanes.
            for i in before.indices where !incoming.contains(i) && !relocated.contains(i) {
                if let lane = before[i] {
                    edges.append(GraphEdge(fromLane: i, from: .top, toLane: i, to: .bottom, color: lane.color))
                }
            }

            while let last = lanes.last, last == nil { lanes.removeLast() }
            let laneCount = max(before.count, lanes.count, nodeLane + 1)
            rows.append(GraphRow(nodeLane: nodeLane, nodeColor: nodeColor, edges: edges, laneCount: laneCount))
        }
        return rows
    }
}
