import SwiftUI

/// Commit dialog modelled on Git Extensions' FormCommit:
/// unstaged files, staged files, diff with line staging, and the message box.
struct CommitDialog: View {
    @Bindable var model: RepoModel
    let dismiss: () -> Void

    @State private var unstagedSelection = Set<FileChange.ID>()
    @State private var stagedSelection = Set<FileChange.ID>()
    @State private var diff = ParsedDiff.empty
    @State private var diffSource: DiffSource = .unstaged
    @State private var lineSelection = Set<Int>()
    @State private var message = ""
    @State private var amend = false
    @State private var pushAfterCommit = false
    @State private var error: String?
    @State private var working = false
    @State private var confirmDiscardFiles = false
    @State private var confirmDiscardLines = false
    @State private var identity = ""

    private var unstaged: [FileChange] { model.status.unstaged }
    private var staged: [FileChange] { model.status.staged }

    private var focusedFile: FileChange? {
        switch diffSource {
        case .staged: staged.first { stagedSelection.contains($0.id) }
        default: unstaged.first { unstagedSelection.contains($0.id) }
        }
    }

    private var canCommit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!staged.isEmpty || !unstaged.isEmpty || amend)
            && !working
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                fileLists
                    .frame(minWidth: 280, idealWidth: 380, maxWidth: 600)
                VSplitView {
                    VStack(spacing: 0) {
                        diffToolbar
                        Divider()
                        DiffView(diff: diff, selection: $lineSelection, placeholder: "Select a file")
                    }
                    .frame(minHeight: 200, idealHeight: 480)
                    messageEditor
                        .frame(minHeight: 160, idealHeight: 220)
                }
                .frame(minWidth: 500)
            }
        }
        .frame(minWidth: 1000, idealWidth: 1300, minHeight: 650, idealHeight: 850)
        .task {
            await model.refreshStatus()
            selectFirstIfNeeded()
            let name = await model.repo.config("user.name") ?? ""
            let email = await model.repo.config("user.email") ?? ""
            identity = name.isEmpty && email.isEmpty ? "" : "as \(name) <\(email)>"
        }
        .onChange(of: unstagedSelection) { _, new in
            if !new.isEmpty { stagedSelection = []; diffSource = .unstaged }
            Task { await loadDiff() }
        }
        .onChange(of: stagedSelection) { _, new in
            if !new.isEmpty { unstagedSelection = []; diffSource = .staged }
            Task { await loadDiff() }
        }
        .onChange(of: amend) { _, isOn in
            guard isOn, message.isEmpty, let head = model.headSha else { return }
            Task {
                message = ((try? await model.repo.fullMessage(sha: head)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .confirmationDialog("Discard changes in \(unstagedSelection.count) file(s)?",
                            isPresented: $confirmDiscardFiles) {
            Button("Discard", role: .destructive) { discardSelectedFiles() }
        } message: {
            Text("Uncommitted changes will be lost. Untracked files will be deleted.")
        }
        .confirmationDialog("Discard selected lines?", isPresented: $confirmDiscardLines) {
            Button("Discard", role: .destructive) { applyLines(cached: false, reverse: true) }
        } message: {
            Text("These working tree changes will be lost.")
        }
    }

    // MARK: - File lists

    private var fileLists: some View {
        VSplitView {
            VStack(spacing: 0) {
                listHeader("Unstaged changes", count: unstaged.count) {
                    Button { stage(unstaged) } label: { Label("Stage all", systemImage: "arrow.down.to.line") }
                        .disabled(unstaged.isEmpty)
                }
                List(unstaged, selection: $unstagedSelection) { file in
                    FileChangeRow(file: file)
                }
                .contextMenu(forSelectionType: FileChange.ID.self) { ids in
                    Button("Stage") { stage(unstaged.filter { ids.contains($0.id) }) }
                    Button("Discard changes…", role: .destructive) {
                        unstagedSelection = ids
                        confirmDiscardFiles = true
                    }
                    Divider()
                    Button("Show in Finder") { reveal(unstaged.first { ids.contains($0.id) }) }
                } primaryAction: { ids in
                    stage(unstaged.filter { ids.contains($0.id) })
                }
                HStack {
                    Button { stage(unstaged.filter { unstagedSelection.contains($0.id) }) } label: {
                        Label("Stage", systemImage: "arrow.down")
                    }
                    .disabled(unstagedSelection.isEmpty)
                    Button(role: .destructive) { confirmDiscardFiles = true } label: {
                        Label("Discard", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(unstagedSelection.isEmpty)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minHeight: 150)

            VStack(spacing: 0) {
                listHeader("Staged changes", count: staged.count) {
                    Button { unstage(staged) } label: { Label("Unstage all", systemImage: "arrow.up.to.line") }
                        .disabled(staged.isEmpty)
                }
                List(staged, selection: $stagedSelection) { file in
                    FileChangeRow(file: file)
                }
                .contextMenu(forSelectionType: FileChange.ID.self) { ids in
                    Button("Unstage") { unstage(staged.filter { ids.contains($0.id) }) }
                } primaryAction: { ids in
                    unstage(staged.filter { ids.contains($0.id) })
                }
                HStack {
                    Button { unstage(staged.filter { stagedSelection.contains($0.id) }) } label: {
                        Label("Unstage", systemImage: "arrow.up")
                    }
                    .disabled(stagedSelection.isEmpty)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minHeight: 150)
        }
    }

    private func listHeader<Trailing: View>(_ title: String, count: Int, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            trailing()
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Diff toolbar

    private var diffToolbar: some View {
        HStack(spacing: 8) {
            if let file = focusedFile {
                FileChangeRow(file: file)
            } else {
                Text("No file selected").foregroundStyle(.secondary)
            }
            Spacer()
            if !lineSelection.isEmpty {
                Text("\(lineSelection.count) line(s)").foregroundStyle(.secondary).font(.caption)
            }
            if diffSource == .unstaged {
                Button("Stage lines") { applyLines(cached: true, reverse: false) }
                    .disabled(lineSelection.isEmpty || focusedFile?.kind == .unmerged)
                Button("Discard lines…") { confirmDiscardLines = true }
                    .disabled(lineSelection.isEmpty || focusedFile?.kind == .untracked)
            } else {
                Button("Unstage lines") { applyLines(cached: true, reverse: true) }
                    .disabled(lineSelection.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    // MARK: - Message

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Commit message").font(.headline)
                Spacer()
                Text(identity.isEmpty ? "No identity set — see Settings (⌘,)" : identity)
                    .foregroundStyle(identity.isEmpty ? .red : .secondary)
                    .help("Author and committer; change in Settings → Identity")
                if let branch = model.currentBranch {
                    Text("on \(branch)").foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $message)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if !model.conflicts.isEmpty {
                Label("\(model.conflicts.count) file(s) still have merge conflicts. Resolve them (or stage the fixed files) before committing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error {
                ScrollView {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 60)
            }
            HStack {
                Toggle("Amend last commit", isOn: $amend)
                Toggle("Push after commit", isOn: $pushAfterCommit)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(staged.isEmpty && !amend ? "Stage all & Commit" : (amend ? "Amend" : "Commit")) {
                    commit()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func selectFirstIfNeeded() {
        if unstagedSelection.isEmpty && stagedSelection.isEmpty {
            if let first = unstaged.first { unstagedSelection = [first.id] }
            else if let first = staged.first { stagedSelection = [first.id] }
        }
    }

    private func loadDiff() async {
        lineSelection = []
        guard let file = focusedFile else {
            diff = .empty
            return
        }
        let source = diffSource
        let text = (try? await model.repo.diff(for: file, source: source)) ?? ""
        if source == diffSource && file.id == focusedFile?.id {
            diff = ParsedDiff(text)
        }
    }

    /// Runs an index operation, refreshes status, and keeps the selection sensible.
    private func run(_ operation: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await operation()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            let previousPath = focusedFile?.path
            let previousSource = diffSource
            await model.refreshStatus()
            // Prune selections of files that moved to the other list.
            unstagedSelection = unstagedSelection.filter { id in unstaged.contains { $0.id == id } }
            stagedSelection = stagedSelection.filter { id in staged.contains { $0.id == id } }
            if unstagedSelection.isEmpty && stagedSelection.isEmpty {
                // Stay on the same file if it still has changes on the same side (line staging).
                if previousSource == .unstaged, let f = unstaged.first(where: { $0.path == previousPath }) {
                    unstagedSelection = [f.id]
                } else if previousSource == .staged, let f = staged.first(where: { $0.path == previousPath }) {
                    stagedSelection = [f.id]
                } else {
                    selectFirstIfNeeded()
                }
            }
            await loadDiff()
        }
    }

    private func stage(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        run { try await model.repo.stage(files.map(\.path)) }
    }

    private func unstage(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        let paths = files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        let hasHead = model.headSha != nil
        run { try await model.repo.unstage(paths, hasHead: hasHead) }
    }

    private func discardSelectedFiles() {
        let files = unstaged.filter { unstagedSelection.contains($0.id) }
        run { try await model.repo.discard(files) }
    }

    private func applyLines(cached: Bool, reverse: Bool) {
        guard let patch = diff.partialPatch(selected: lineSelection, reverse: reverse) else { return }
        run { try await model.repo.apply(patch: patch, cached: cached, reverse: reverse) }
    }

    private func reveal(_ file: FileChange?) {
        guard let file else { return }
        let url = model.repo.url.appendingPathComponent(file.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func commit() {
        let text = message
        let isAmend = amend
        let stageAll = staged.isEmpty && !amend
        let push = pushAfterCommit
        working = true
        Task {
            defer { working = false }
            do {
                if stageAll {
                    try await model.repo.git.run(["add", "-A"])
                }
                _ = try await model.repo.commit(message: text, amend: isAmend)
                if push, let branch = model.currentBranch {
                    let hasUpstream = await model.repo.hasUpstream(branch: branch)
                    _ = try await model.repo.push(branch: branch, setUpstream: !hasUpstream, force: false)
                }
                await model.reload()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                await model.refreshStatus()
            }
        }
    }
}
