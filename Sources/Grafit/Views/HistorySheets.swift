import SwiftUI

// MARK: - Stash

struct StashSheet: View {
    let changes: Int
    let onStash: (_ message: String, _ includeUntracked: Bool, _ keepIndex: Bool) -> Void
    let dismiss: () -> Void

    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash changes").font(.title2.bold())
            Text("\(changes) changed file(s) will be saved and removed from the working tree.")
                .foregroundStyle(.secondary)
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle("Include untracked files", isOn: $includeUntracked)
            Toggle("Keep staged changes in the index", isOn: $keepIndex)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Stash", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        dismiss()
        onStash(message.trimmingCharacters(in: .whitespacesAndNewlines), includeUntracked, keepIndex)
    }
}

// MARK: - Conflicts

/// Lists conflicted files and resolves them with ours/theirs, the merge tool, or by marking them resolved.
struct ConflictsSheet: View {
    @Bindable var model: RepoModel
    let dismiss: () -> Void

    @State private var selected: FileChange.ID?
    @State private var content = ""
    @State private var working: String?
    @State private var error: String?

    private var conflicts: [FileChange] { model.conflicts }
    private var file: FileChange? { conflicts.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolve conflicts").font(.title2.bold())
                    Text(model.pendingOperation ?? "")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            if conflicts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("All conflicts are resolved.").font(.headline)
                    Text("Continue the \(model.pendingOperation?.lowercased().replacingOccurrences(of: " in progress", with: "") ?? "operation") to finish.")
                        .foregroundStyle(.secondary)
                    if let op = model.pendingOperation {
                        Button("Continue") {
                            dismiss()
                            Task { await model.perform("Continuing…") { try await model.repo.continueOperation(op) } }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(conflicts, selection: $selected) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            FileChangeRow(file: file)
                            Text(describe(file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    VStack(spacing: 0) {
                        actions
                        Divider()
                        ConflictTextView(text: content)
                    }
                    .frame(minWidth: 420)
                }
            }
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 520, idealHeight: 720)
        .task { await model.refreshStatus(); selectFirst() }
        .task(id: selected) { load() }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Use ours") { run("Taking ours…") { try await model.repo.resolve($0, using: .ours) } }
                .help("Keep the version from the current branch (during a rebase: the branch you rebase onto)")
            Button("Use theirs") { run("Taking theirs…") { try await model.repo.resolve($0, using: .theirs) } }
                .help("Keep the incoming version (during a rebase: your commit being replayed)")
            Button("Merge tool") { run("Waiting for merge tool…") { _ = try await model.repo.runMergeTool($0.path) } }
                .help("git mergetool — set the tool in Settings → General")
            Button("Editor") {
                if let file { NSWorkspace.shared.open(model.repo.url.appendingPathComponent(file.path)) }
            }
            Spacer()
            Button("Mark as resolved") { run("Staging…") { try await model.repo.markResolved([$0.path]) } }
                .buttonStyle(.borderedProminent)
                .help("Stage the file as it is now in the working tree")
        }
        .controlSize(.small)
        .disabled(file == nil || working != nil)
        .padding(8)
    }

    private func describe(_ file: FileChange) -> String {
        switch file.conflictCode {
        case "UU": "both modified"
        case "AA": "both added"
        case "DU": "deleted by us"
        case "UD": "deleted by them"
        case "AU": "added by us"
        case "UA": "added by them"
        case "DD": "both deleted"
        default: "conflict"
        }
    }

    private func selectFirst() {
        if file == nil { selected = conflicts.first?.id }
    }

    private func load() {
        guard let file else { content = ""; return }
        let exists = FileManager.default.fileExists(atPath: model.repo.url.appendingPathComponent(file.path).path)
        content = exists
            ? model.repo.workingFile(file.path)
            : "(\(describe(file)) — choose ours or theirs)"
    }

    private func run(_ label: String, _ action: @escaping (FileChange) async throws -> Void) {
        guard let file else { return }
        working = label
        Task {
            defer { working = nil }
            do {
                try await action(file)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await model.refreshStatus()
            selected = nil
            selectFirst()
            load()
        }
    }
}

/// Working-tree file with conflict markers highlighted (ours green, theirs blue).
struct ConflictTextView: View {
    let text: String

    private enum Region { case normal, ours, base, theirs }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        GeometryReader { geo in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                let regions = Self.regions(lines)
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i].isEmpty ? " " : lines[i])
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(Self.isMarker(lines[i]) ? .bold : .regular)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minWidth: geo.size.width, alignment: .leading)
                        .frame(height: 17)
                        .background(color(regions[i], marker: Self.isMarker(lines[i])))
                }
            }
            .padding(.vertical, 4)
        }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private static func isMarker(_ line: String) -> Bool {
        line.hasPrefix("<<<<<<<") || line.hasPrefix("=======") || line.hasPrefix(">>>>>>>") || line.hasPrefix("|||||||")
    }

    private static func regions(_ lines: [String]) -> [Region] {
        var region = Region.normal
        return lines.map { line in
            if line.hasPrefix("<<<<<<<") { region = .ours; return .ours }
            if line.hasPrefix("|||||||") { region = .base; return .base }
            if line.hasPrefix("=======") { region = .theirs; return .theirs }
            if line.hasPrefix(">>>>>>>") { defer { region = .normal }; return .theirs }
            return region
        }
    }

    private func color(_ region: Region, marker: Bool) -> Color {
        let alpha = marker ? 0.35 : 0.16
        switch region {
        case .normal: return .clear
        case .ours: return Color.green.opacity(alpha)
        case .base: return Color.gray.opacity(alpha)
        case .theirs: return Color.blue.opacity(alpha)
        }
    }
}

// MARK: - Interactive rebase

struct RebaseRequest {
    let base: String?
    var steps: [RebaseStep]
    let pushedTo: [String]
}

/// Git Extensions-style interactive rebase: choose an action per commit, drag to reorder.
struct InteractiveRebaseSheet: View {
    @State var request: RebaseRequest
    let branch: String
    let onStart: (RebaseRequest) -> Void
    let dismiss: () -> Void

    private var invalidReason: String? {
        let kept = request.steps.filter { $0.action != .drop }
        if let first = kept.first, first.action == .squash || first.action == .fixup {
            return "The first commit can't be squashed or fixed up — there is nothing before it to meld into."
        }
        if request.steps.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A reworded commit needs a message."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interactive rebase of \(branch)").font(.title2.bold())
            Text("Oldest commit on top. Drag rows to reorder, pick an action per commit.")
                .foregroundStyle(.secondary)
            if !request.pushedTo.isEmpty {
                Label("Some of these commits are already on \(request.pushedTo.prefix(3).joined(separator: ", ")). You'll need to force push afterwards.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            List {
                ForEach($request.steps) { $step in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Picker("", selection: $step.action) {
                            ForEach(RebaseAction.allCases) { action in
                                Text(action.rawValue).tag(action)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .help(step.action.help)
                        Text(step.commit.shortSha)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if step.action == .reword {
                            TextField("New message", text: $step.message, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Text(step.commit.subject)
                                .lineLimit(1)
                                .strikethrough(step.action == .drop)
                                .foregroundStyle(step.action == .drop ? .secondary : .primary)
                        }
                        Spacer()
                        Text(step.commit.authorName).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { request.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 260)
            if let invalidReason {
                Text(invalidReason).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("Uncommitted changes are stashed and restored automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Start rebase") {
                    dismiss()
                    onStart(request)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(invalidReason != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 600)
    }
}

// MARK: - Edit commit message

struct RewordSheet: View {
    let commit: Commit
    @State var message: String
    let pushedTo: [String]
    let onSave: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit commit message").font(.title2.bold())
            Text("\(commit.shortSha) · \(commit.authorName)").foregroundStyle(.secondary)
            if !pushedTo.isEmpty {
                Label("This commit is already on \(pushedTo.prefix(3).joined(separator: ", ")). You'll need to force push afterwards.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            TextEditor(text: $message)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .frame(minHeight: 160)
            HStack {
                Text("Later commits are rewritten (new SHAs).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save") {
                    dismiss()
                    onSave(message.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 380)
    }
}
