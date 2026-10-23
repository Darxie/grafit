import Foundation

struct DiffLine: Identifiable, Hashable {
    enum Kind { case fileHeader, hunkHeader, context, added, removed, noNewline }

    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let hunk: Int?

    var isChange: Bool { kind == .added || kind == .removed }
}

/// A unified diff of a single file, parsed into lines and hunks.
struct ParsedDiff {
    let fileHeader: [String]
    let lines: [DiffLine]
    let isBinary: Bool

    static let empty = ParsedDiff(fileHeader: [], lines: [], isBinary: false)

    init(fileHeader: [String], lines: [DiffLine], isBinary: Bool) {
        self.fileHeader = fileHeader
        self.lines = lines
        self.isBinary = isBinary
    }

    init(_ text: String) {
        var header: [String] = []
        var lines: [DiffLine] = []
        var binary = false
        var oldNo = 0, newNo = 0
        var hunk = -1
        var raw = text.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }

        for line in raw {
            let id = lines.count
            if line.hasPrefix("@@") {
                hunk += 1
                let (o, n) = ParsedDiff.parseHunkStarts(line)
                oldNo = o; newNo = n
                lines.append(DiffLine(id: id, kind: .hunkHeader, text: line, oldLine: nil, newLine: nil, hunk: hunk))
                continue
            }
            if hunk < 0 {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { binary = true }
                header.append(line)
                lines.append(DiffLine(id: id, kind: .fileHeader, text: line, oldLine: nil, newLine: nil, hunk: nil))
                continue
            }
            switch line.first {
            case "+":
                lines.append(DiffLine(id: id, kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: newNo, hunk: hunk))
                newNo += 1
            case "-":
                lines.append(DiffLine(id: id, kind: .removed, text: String(line.dropFirst()), oldLine: oldNo, newLine: nil, hunk: hunk))
                oldNo += 1
            case "\\":
                lines.append(DiffLine(id: id, kind: .noNewline, text: line, oldLine: nil, newLine: nil, hunk: hunk))
            default:
                lines.append(DiffLine(id: id, kind: .context, text: String(line.dropFirst()), oldLine: oldNo, newLine: newNo, hunk: hunk))
                oldNo += 1; newNo += 1
            }
        }
        self.init(fileHeader: header, lines: lines, isBinary: binary)
    }

    private static func parseHunkStarts(_ header: String) -> (Int, Int) {
        // "@@ -12,7 +12,9 @@ context"
        let parts = header.split(separator: " ")
        func start(_ s: Substring?) -> Int {
            guard let s else { return 0 }
            return Int(s.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }

    var hasChanges: Bool { lines.contains(where: \.isChange) }

    /// Builds a patch that contains only the selected +/- lines.
    ///
    /// `reverse` is for patches applied with `git apply -R` (unstaging from the index
    /// or discarding from the working tree): the patch's "new" side must match the target,
    /// so unselected additions become context and unselected removals are dropped.
    /// Forward patches (staging) do the opposite.
    func partialPatch(selected: Set<Int>, reverse: Bool) -> String? {
        guard !fileHeader.isEmpty else { return nil }
        var out = fileHeader.filter { !$0.hasPrefix("index ") }
        var any = false

        let hunks = Dictionary(grouping: lines.filter { $0.hunk != nil }, by: { $0.hunk! })
        for key in hunks.keys.sorted() {
            guard let hunkLines = hunks[key], let headerLine = hunkLines.first, headerLine.kind == .hunkHeader else { continue }
            var body: [String] = []
            var oldCount = 0, newCount = 0
            var hasSelectedChange = false
            var lastKept = true

            for line in hunkLines.dropFirst() {
                let isSelected = selected.contains(line.id)
                switch line.kind {
                case .context:
                    body.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                case .added:
                    if isSelected {
                        body.append("+" + line.text); newCount += 1; hasSelectedChange = true; lastKept = true
                    } else if reverse {
                        body.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                    } else {
                        lastKept = false
                    }
                case .removed:
                    if isSelected {
                        body.append("-" + line.text); oldCount += 1; hasSelectedChange = true; lastKept = true
                    } else if !reverse {
                        body.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                    } else {
                        lastKept = false
                    }
                case .noNewline:
                    if lastKept { body.append(line.text) }
                default:
                    break
                }
            }
            guard hasSelectedChange else { continue }
            any = true
            let (oldStart, newStart) = ParsedDiff.parseHunkStarts(headerLine.text)
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += body
        }
        return any ? out.joined(separator: "\n") + "\n" : nil
    }

    /// All change-line ids belonging to the given hunk.
    func changeIds(inHunk hunk: Int) -> Set<Int> {
        Set(lines.filter { $0.hunk == hunk && $0.isChange }.map(\.id))
    }
}
