import AppKit
import SwiftUI

/// Unified diff viewer. When `selection` is provided, +/- lines can be selected
/// (click, ⇧-click for a range, ⌘-click to toggle, click a hunk header for the whole hunk).
struct DiffView: View {
    let diff: ParsedDiff
    var selection: Binding<Set<Int>>?
    var placeholder = "Select a file to see its changes"

    @State private var anchor: Int?

    private var gutterWidth: CGFloat {
        let maxNo = diff.lines.compactMap { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0
        return CGFloat(max(String(maxNo).count, 3)) * 7.5 + 8
    }

    var body: some View {
        if diff.lines.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else if diff.isBinary {
            Text("Binary file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines.filter { $0.kind != .fileHeader }) { line in
                            lineView(line, minWidth: geo.size.width)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func lineView(_ line: DiffLine, minWidth: CGFloat) -> some View {
        let isSelected = selection?.wrappedValue.contains(line.id) ?? false
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: gutterWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLine.map(String.init) ?? "")
                .frame(width: gutterWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(prefix(line))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(foreground(line))
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(foreground(line))
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minWidth: minWidth, alignment: .leading)
        .frame(height: 17)
        .background(background(line, selected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture { tap(line) }
    }

    private func prefix(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        default: ""
        }
    }

    private func foreground(_ line: DiffLine) -> Color {
        switch line.kind {
        case .hunkHeader: .blue
        case .noNewline: .secondary
        default: .primary
        }
    }

    private func background(_ line: DiffLine, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.45) }
        switch line.kind {
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        case .hunkHeader: return Color.blue.opacity(0.08)
        default: return .clear
        }
    }

    private func tap(_ line: DiffLine) {
        guard let selection else { return }
        let flags = NSEvent.modifierFlags
        if line.kind == .hunkHeader, let hunk = line.hunk {
            let ids = diff.changeIds(inHunk: hunk)
            if flags.contains(.command) {
                selection.wrappedValue.formUnion(ids)
            } else {
                selection.wrappedValue = ids
            }
            anchor = nil
            return
        }
        guard line.isChange else {
            if !flags.contains(.command) && !flags.contains(.shift) { selection.wrappedValue = [] }
            return
        }
        if flags.contains(.shift), let anchor {
            let range = min(anchor, line.id)...max(anchor, line.id)
            let ids = diff.lines.filter { range.contains($0.id) && $0.isChange }.map(\.id)
            selection.wrappedValue.formUnion(ids)
        } else if flags.contains(.command) {
            if selection.wrappedValue.contains(line.id) {
                selection.wrappedValue.remove(line.id)
            } else {
                selection.wrappedValue.insert(line.id)
            }
            anchor = line.id
        } else {
            selection.wrappedValue = [line.id]
            anchor = line.id
        }
    }
}

struct FileChangeRow: View {
    let file: FileChange

    private var color: Color {
        switch file.kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .unmerged: .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(file.kind.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
            Text(file.fileName)
                .lineLimit(1)
            Text(file.oldPath.map { "← \($0)" } ?? file.directory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 12))
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// File list on the left, diff on the right. The list keeps a fixed width that the user
/// can drag (shared by all bottom panes and remembered), so the diff gets the rest of the space.
struct FileListSplit<List: View, Detail: View>: View {
    @ViewBuilder let list: () -> List
    @ViewBuilder let detail: () -> Detail

    @AppStorage("fileListWidth") private var width = 280.0
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                list()
                    .frame(width: clamped(width, total: geo.size.width))
                divider(total: geo.size.width)
                detail()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func clamped(_ value: Double, total: CGFloat) -> CGFloat {
        min(max(value, 160), max(160, total - 300))
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(clamped(width, total: total))
                        dragStart = start
                        width = Double(clamped(start + value.translation.width, total: total))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { width = 280 }
            .help("Drag to resize, double-click to reset")
    }
}
