import AppKit
import SwiftUI

enum CommitAction {
    case checkoutBranch(GitRef)
    case checkoutCommit(Commit)
    case createBranch(Commit)
    case createTag(Commit)
    case merge(target: String, label: String)
    case rebase(target: String, label: String)
    case cherryPick(Commit)
    case revert(Commit)
    case reset(Commit)
    case deleteBranch(GitRef)
    case deleteTag(GitRef)
}

struct CommitListView: View {
    @Bindable var model: RepoModel
    let onAction: (CommitAction) -> Void
    @FocusState private var focused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var graphWidth: CGFloat {
        CGFloat(min(model.maxLanes, 24)) * GraphStyle.laneWidth + 6
    }

    var body: some View {
        let visible = model.visibleIndices
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if model.status.totalCount > 0 && model.filterText.isEmpty {
                            WorkingTreeRow(model: model, graphWidth: graphWidth)
                        }
                        ForEach(visible, id: \.self) { index in
                            row(index)
                                .id(model.commits[index].sha)
                        }
                    }
                }
                .onChange(of: model.selectedSha) { _, sha in
                    guard let sha else { return }
                    proxy.scrollTo(sha)
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: visible); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: visible); return .handled }
            .onKeyPress(.pageDown) { move(20, in: visible); return .handled }
            .onKeyPress(.pageUp) { move(-20, in: visible); return .handled }
            .onAppear { focused = true }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Graph / Message")
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Author").frame(width: 160, alignment: .leading)
            Text("Date").frame(width: 120, alignment: .leading)
            Text("SHA").frame(width: 76, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .background(.bar)
    }

    private func move(_ delta: Int, in visible: [Int]) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { model.commits[$0].sha == model.selectedSha } ?? -1
        let next = min(max(current + delta, 0), visible.count - 1)
        model.selectedSha = model.commits[visible[next]].sha
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let commit = model.commits[index]
        let refs = (model.refsBySha[commit.sha] ?? []).sorted { $0.kind < $1.kind }
        let isSelected = commit.sha == model.selectedSha
        let isHead = commit.sha == model.headSha

        HStack(spacing: 0) {
            if index < model.graph.count {
                GraphCell(row: model.graph[index], isHead: isHead, width: graphWidth)
            }
            HStack(spacing: 4) {
                if isHead {
                    RefBadge(text: model.currentBranch.map { "HEAD → \($0)" } ?? "HEAD (detached)", kind: .head)
                }
                ForEach(refs) { ref in
                    if !(isHead && ref.kind == .localBranch && ref.shortName == model.currentBranch) {
                        RefBadge(text: ref.shortName, kind: ref.kind)
                    }
                }
                Text(commit.subject)
                    .fontWeight(isHead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(commit.isMerge && !isSelected ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.authorName)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
            Text(Self.dateFormatter.string(from: commit.authorDate))
                .monospacedDigit()
                .frame(width: 120, alignment: .leading)
            Text(commit.sha.prefix(8))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
        }
        .font(.system(size: 12))
        .frame(height: GraphStyle.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(focused ? 0.28 : 0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedSha = commit.sha
            focused = true
        }
        .contextMenu { contextMenu(for: commit, refs: refs) }
    }

    @ViewBuilder
    private func contextMenu(for commit: Commit, refs: [GitRef]) -> some View {
        let localBranches = refs.filter { $0.kind == .localBranch }
        let remoteBranches = refs.filter { $0.kind == .remoteBranch }
        let tags = refs.filter { $0.kind == .tag }
        let current = model.currentBranch ?? "HEAD"
        let targets: [(target: String, label: String)] =
            (localBranches + remoteBranches).map { ($0.shortName, $0.shortName) }
            + [(commit.sha, "commit \(commit.shortSha)")]

        ForEach(localBranches + remoteBranches) { ref in
            Button("Checkout branch \(ref.shortName)") { onAction(.checkoutBranch(ref)) }
        }
        Button("Checkout this commit (detached)") { onAction(.checkoutCommit(commit)) }
        Divider()
        Button("Create new branch here…") { onAction(.createBranch(commit)) }
        Button("Create new tag here…") { onAction(.createTag(commit)) }
        Divider()
        Menu("Merge into \(current)") {
            ForEach(targets, id: \.target) { t in
                Button(t.label) { onAction(.merge(target: t.target, label: t.label)) }
            }
        }
        Menu("Rebase \(current) on") {
            ForEach(targets, id: \.target) { t in
                Button(t.label) { onAction(.rebase(target: t.target, label: t.label)) }
            }
        }
        Button("Cherry-pick this commit") { onAction(.cherryPick(commit)) }
        Button("Revert this commit") { onAction(.revert(commit)) }
        Button("Reset \(current) to here…") { onAction(.reset(commit)) }
        if !localBranches.isEmpty || !remoteBranches.isEmpty || !tags.isEmpty {
            Divider()
            ForEach(localBranches + remoteBranches) { ref in
                Button("Delete branch \(ref.shortName)…") { onAction(.deleteBranch(ref)) }
            }
            ForEach(tags) { ref in
                Button("Delete tag \(ref.shortName)…") { onAction(.deleteTag(ref)) }
            }
        }
        Divider()
        Button("Copy SHA") { copy(commit.sha) }
        Button("Copy short SHA") { copy(commit.shortSha) }
        Button("Copy subject") { copy(commit.subject) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Artificial top row for uncommitted changes, like Git Extensions' "Working directory" row.
struct WorkingTreeRow: View {
    @Bindable var model: RepoModel
    let graphWidth: CGFloat

    var body: some View {
        let isSelected = model.selectedSha == RepoModel.workingTreeId
        HStack(spacing: 0) {
            Canvas { context, size in
                let x = GraphStyle.x(0)
                let r = GraphStyle.nodeRadius
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height / 2))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.gray), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                let circle = Path(ellipseIn: CGRect(x: x - r, y: size.height / 2 - r, width: r * 2, height: r * 2))
                context.fill(circle, with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(circle, with: .color(.gray), lineWidth: 2)
            }
            .frame(width: graphWidth, height: GraphStyle.rowHeight)
            Text("Uncommitted changes")
                .italic()
            Text("  \(model.status.staged.count) staged, \(model.status.unstaged.count) unstaged")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .frame(height: GraphStyle.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSha = RepoModel.workingTreeId }
    }
}

struct RefBadge: View {
    let text: String
    let kind: RefKind

    private var color: Color {
        switch kind {
        case .head: .orange
        case .localBranch: .green
        case .remoteBranch: .purple
        case .tag: .yellow
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if kind == .tag { Image(systemName: "tag.fill").font(.system(size: 8)) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.8), lineWidth: 1))
        .fixedSize()
    }
}
