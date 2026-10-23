import AppKit
import SwiftUI

enum RepoSheet: Identifiable {
    case commit
    case input(InputRequest)
    case confirm(ConfirmRequest)
    case reset(Commit)
    case stash
    case conflicts
    case rebase(RebaseRequest)
    case reword(Commit, message: String, pushedTo: [String])

    var id: String {
        switch self {
        case .commit: "commit"
        case .input(let r): "input-\(r.title)"
        case .confirm(let r): "confirm-\(r.title)"
        case .reset(let c): "reset-\(c.sha)"
        case .stash: "stash"
        case .conflicts: "conflicts"
        case .rebase(let r): "rebase-\(r.base ?? "root")"
        case .reword(let c, _, _): "reword-\(c.sha)"
        }
    }
}

struct RepoView: View {
    @Bindable var model: RepoModel
    let onClose: () -> Void

    @State private var sheet: RepoSheet?
    @State private var showOutput = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, onAction: handle)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if let op = model.pendingOperation {
                    operationBanner(op)
                }
                VSplitView {
                    CommitListView(model: model, onAction: handle)
                        .frame(minHeight: 150, idealHeight: 450)
                    detailPane
                        .frame(minHeight: 150, idealHeight: 350)
                }
                statusBar
            }
        }
        .toolbar { toolbar }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter commits")
        .sheet(item: $sheet) { sheet in
            sheetView(sheet)
        }
        .alert("Git error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await runDebugAction() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reload() }
        }
        .focusedSceneValue(\.repoActions, RepoActions(
            refresh: { Task { await model.reload() } },
            commit: { sheet = .commit },
            fetch: { fetch() },
            pull: { pull(rebase: nil) },
            push: { push(force: false) },
            close: onClose
        ))
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.selectedSha == RepoModel.workingTreeId {
            WorkingTreeSummary(model: model, openCommit: { sheet = .commit })
        } else if let commit = model.selectedCommit {
            CommitDetailView(model: model, commit: commit)
        } else {
            Text(model.isLoading ? "Loading…" : "No commit selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func operationBanner(_ op: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(op).fontWeight(.semibold)
            Text(model.conflicts.isEmpty
                 ? "No conflicts left — continue to finish."
                 : "\(model.conflicts.count) conflicted file(s).")
                .foregroundStyle(.secondary)
            Spacer()
            if !model.conflicts.isEmpty {
                Button("Resolve conflicts…") { sheet = .conflicts }
                    .buttonStyle(.borderedProminent)
            }
            Button("Commit dialog…") { sheet = .commit }
            Button("Continue") {
                Task { await model.perform("Continuing…") { try await model.repo.continueOperation(op) } }
            }
            Button("Abort", role: .destructive) {
                Task { await model.perform("Aborting…") { try await model.repo.abortOperation(op) } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let output = model.lastOutput {
                Button {
                    showOutput.toggle()
                } label: {
                    Text(output.split(separator: "\n").last.map(String.init) ?? output)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOutput) {
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .frame(width: 520, height: 260)
                }
            }
            Spacer()
            Text(model.currentBranch.map { "On \($0)" } ?? "Detached HEAD")
            Text("· \(model.commits.count) commits")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { sheet = .commit } label: {
                Label(model.status.totalCount > 0 ? "Commit (\(model.status.totalCount))" : "Commit",
                      systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("Commit (⌘K)")
            Menu {
                Button("Stash changes…") { sheet = .stash }
                    .disabled(model.status.totalCount == 0)
                if let latest = model.stashes.first {
                    Divider()
                    Button("Pop \(latest.name): \(latest.message)") { handle(.stashApply(latest, pop: true)) }
                    Button("Apply \(latest.name)") { handle(.stashApply(latest, pop: false)) }
                }
            } label: {
                Label(model.stashes.isEmpty ? "Stash" : "Stash (\(model.stashes.count))", systemImage: "tray.and.arrow.down")
            } primaryAction: {
                if model.status.totalCount > 0 { sheet = .stash }
            }
            .help("Stash uncommitted changes; stashes are listed in the sidebar")
            Button { fetch() } label: { Label("Fetch", systemImage: "arrow.down.circle") }
                .help("Fetch all remotes (⇧⌘F)")
            Menu {
                Button("Pull (merge)") { pull(rebase: false) }
                Button("Pull (rebase)") { pull(rebase: true) }
                Divider()
                Button("Fetch all") { fetch() }
            } label: {
                Label("Pull", systemImage: "arrow.down.to.line")
            } primaryAction: {
                pull(rebase: nil)
            }
            .help("Pull (⇧⌘L)")
            Menu {
                Button("Push") { push(force: false) }
                Button("Force push (with lease)…") {
                    sheet = .confirm(ConfirmRequest(
                        title: "Force push \(model.currentBranch ?? "")?",
                        message: "Remote commits not present locally will be overwritten (git push --force-with-lease).",
                        confirmLabel: "Force push", destructive: true
                    ) { _ in push(force: true) })
                }
            } label: {
                Label("Push", systemImage: "arrow.up.to.line")
            } primaryAction: {
                push(force: false)
            }
            .help("Push (⇧⌘P)")
            if model.isLoading || model.busyMessage != nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: RepoSheet) -> some View {
        switch sheet {
        case .commit:
            CommitDialog(model: model) { self.sheet = nil }
        case .input(let request):
            InputSheet(request: request) { self.sheet = nil }
        case .confirm(let request):
            ConfirmSheet(request: request) { self.sheet = nil }
        case .reset(let commit):
            ResetSheet(commit: commit, branch: model.currentBranch) { mode in
                Task { await model.perform("Resetting…") { try await model.repo.reset(to: commit.sha, mode: mode) } }
            } dismiss: { self.sheet = nil }
        case .stash:
            StashSheet(changes: model.status.totalCount) { message, untracked, keepIndex in
                Task {
                    await model.perform("Stashing…") {
                        try await model.repo.stash(message: message, includeUntracked: untracked, keepIndex: keepIndex)
                    }
                }
            } dismiss: { self.sheet = nil }
        case .conflicts:
            ConflictsSheet(model: model) { self.sheet = nil }
        case .rebase(let request):
            InteractiveRebaseSheet(request: request, branch: model.currentBranch ?? "HEAD") { final in
                Task {
                    await model.perform("Rebasing…") {
                        try await model.repo.interactiveRebase(base: final.base, steps: final.steps)
                    }
                }
            } dismiss: { self.sheet = nil }
        case .reword(let commit, let message, let pushedTo):
            RewordSheet(commit: commit, message: message, pushedTo: pushedTo) { newMessage in
                Task { await model.perform("Rewording…") { try await model.repo.reword(commit.sha, message: newMessage) } }
            } dismiss: { self.sheet = nil }
        }
    }

    /// GITEXMAC_DEBUG_ACTION opens a dialog on launch (development / screenshots):
    /// commit, stash, conflicts, rebase, reword, clone, settings.
    private func runDebugAction() async {
        guard let action = ProcessInfo.processInfo.environment["GITEXMAC_DEBUG_ACTION"] else { return }
        while model.commits.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let commits = model.commits
        switch action {
        case "commit": sheet = .commit
        case "stash": sheet = .stash
        case "conflicts": sheet = .conflicts
        case "rebase": handle(.interactiveRebase(commits[min(3, commits.count - 1)]))
        case "reword": handle(.reword(commits[min(1, commits.count - 1)]))
        case "clone": TabsModel.shared.showClone = true
        case "settings": openSettings()
        default: break
        }
    }

    // MARK: - Remote operations

    private func fetch() {
        Task { await model.perform("Fetching…") { try await model.repo.fetch() } }
    }

    private func pull(rebase: Bool?) {
        Task { await model.perform("Pulling…") { try await model.repo.pull(rebase: rebase) } }
    }

    private func push(force: Bool) {
        guard let branch = model.currentBranch else {
            model.errorMessage = "You are not on a branch (detached HEAD)."
            return
        }
        Task {
            let hasUpstream = await model.repo.hasUpstream(branch: branch)
            await model.perform("Pushing \(branch)…") {
                try await model.repo.push(branch: branch, setUpstream: !hasUpstream, force: force)
            }
        }
    }

    // MARK: - Commit actions

    private func handle(_ action: CommitAction) {
        let repo = model.repo
        let current = model.currentBranch ?? "HEAD"
        switch action {
        case .checkoutBranch(let ref):
            Task {
                await model.perform("Checking out \(ref.shortName)…") {
                    ref.kind == .remoteBranch
                        ? try await repo.checkoutRemoteBranch(ref)
                        : try await repo.checkout(ref.shortName)
                }
            }
        case .checkoutCommit(let commit):
            sheet = .confirm(ConfirmRequest(
                title: "Checkout \(commit.shortSha)?",
                message: "You will be in 'detached HEAD' state. Create a branch if you want to keep new commits.",
                confirmLabel: "Checkout"
            ) { _ in
                Task { await model.perform("Checking out…") { try await repo.checkout(commit.sha) } }
            })
        case .createBranch(let commit):
            sheet = .input(InputRequest(
                title: "Create branch",
                prompt: "New branch at \(commit.shortSha) — \(commit.subject)",
                placeholder: "feature/my-branch",
                toggleLabel: "Checkout after create",
                toggleDefault: true
            ) { name, checkout, _ in
                Task { await model.perform("Creating branch…") { try await repo.createBranch(name, at: commit.sha, checkout: checkout) } }
            })
        case .createTag(let commit):
            sheet = .input(InputRequest(
                title: "Create tag",
                prompt: "New tag at \(commit.shortSha) — \(commit.subject)",
                placeholder: "v1.0.0",
                messageLabel: "Message (optional, creates an annotated tag)"
            ) { name, _, message in
                Task { await model.perform("Creating tag…") { try await repo.createTag(name, at: commit.sha, message: message) } }
            })
        case .merge(let target, let label):
            sheet = .confirm(ConfirmRequest(
                title: "Merge \(label) into \(current)?",
                message: "git merge \(label)",
                confirmLabel: "Merge",
                toggleLabel: "No fast-forward (always create a merge commit)"
            ) { noFF in
                Task { await model.perform("Merging…") { try await repo.merge(target, noFastForward: noFF) } }
            })
        case .rebase(let target, let label):
            sheet = .confirm(ConfirmRequest(
                title: "Rebase \(current) on \(label)?",
                message: "Commits of \(current) will be rewritten on top of \(label).",
                confirmLabel: "Rebase"
            ) { _ in
                Task { await model.perform("Rebasing…") { try await repo.rebase(onto: target) } }
            })
        case .cherryPick(let commit):
            sheet = .confirm(ConfirmRequest(
                title: "Cherry-pick \(commit.shortSha) onto \(current)?",
                message: commit.subject,
                confirmLabel: "Cherry-pick"
            ) { _ in
                Task { await model.perform("Cherry-picking…") { try await repo.cherryPick(commit.sha, isMerge: commit.isMerge) } }
            })
        case .revert(let commit):
            sheet = .confirm(ConfirmRequest(
                title: "Revert \(commit.shortSha)?",
                message: "A new commit undoing \"\(commit.subject)\" will be created on \(current).",
                confirmLabel: "Revert"
            ) { _ in
                Task { await model.perform("Reverting…") { try await repo.revert(commit.sha, isMerge: commit.isMerge) } }
            })
        case .reset(let commit):
            sheet = .reset(commit)
        case .deleteBranch(let ref):
            if ref.kind == .remoteBranch {
                sheet = .confirm(ConfirmRequest(
                    title: "Delete remote branch \(ref.shortName)?",
                    message: "The branch will be deleted on the remote '\(ref.remoteName ?? "")'.",
                    confirmLabel: "Delete", destructive: true
                ) { _ in
                    Task { await model.perform("Deleting remote branch…") { try await repo.deleteRemoteBranch(ref) } }
                })
            } else {
                sheet = .confirm(ConfirmRequest(
                    title: "Delete branch \(ref.shortName)?",
                    message: "The branch label is removed; commits stay reachable only if other refs point to them.",
                    confirmLabel: "Delete", destructive: true,
                    toggleLabel: "Force delete (even if not merged)"
                ) { force in
                    Task { await model.perform("Deleting branch…") { try await repo.deleteBranch(ref.shortName, force: force) } }
                })
            }
        case .reword(let commit):
            Task {
                guard await repo.isAncestorOfHead(commit.sha) else {
                    model.errorMessage = "\(commit.shortSha) is not part of \(current). Check out its branch first."
                    return
                }
                let message = (try? await repo.fullMessage(sha: commit.sha))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? commit.subject
                let pushed = await repo.remoteBranchesContaining(commit.sha)
                sheet = .reword(commit, message: message, pushedTo: pushed)
            }
        case .interactiveRebase(let commit):
            Task {
                guard await repo.isAncestorOfHead(commit.sha) else {
                    model.errorMessage = "\(commit.shortSha) is not part of \(current). Check out its branch first."
                    return
                }
                do {
                    let (base, commits) = try await repo.commitsForRebase(from: commit.sha)
                    if commits.contains(where: \.isMerge) {
                        model.errorMessage = "The commits from \(commit.shortSha) to HEAD include merge commits. Interactive rebase would flatten them, so start from a commit after the last merge."
                        return
                    }
                    let pushed = await repo.remoteBranchesContaining(commit.sha)
                    sheet = .rebase(RebaseRequest(
                        base: base,
                        steps: commits.map { RebaseStep(commit: $0, message: $0.subject) },
                        pushedTo: pushed))
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
        case .stashApply(let stash, let pop):
            Task { await model.perform(pop ? "Popping stash…" : "Applying stash…") { try await repo.stashApply(stash, pop: pop) } }
        case .stashDrop(let stash):
            sheet = .confirm(ConfirmRequest(
                title: "Drop \(stash.name)?",
                message: "\"\(stash.message)\" will be deleted.",
                confirmLabel: "Drop", destructive: true
            ) { _ in
                Task { await model.perform("Dropping stash…") { try await repo.stashDrop(stash) } }
            })
        case .deleteTag(let ref):
            sheet = .confirm(ConfirmRequest(
                title: "Delete tag \(ref.shortName)?",
                message: "The tag is deleted locally only.",
                confirmLabel: "Delete", destructive: true
            ) { _ in
                Task { await model.perform("Deleting tag…") { try await repo.deleteTag(ref.shortName) } }
            })
        }
    }
}

/// Bottom pane when the "Uncommitted changes" row is selected.
struct WorkingTreeSummary: View {
    @Bindable var model: RepoModel
    let openCommit: () -> Void

    @State private var selected: String?
    @State private var diff = ParsedDiff.empty

    private var entries: [(id: String, file: FileChange, source: DiffSource)] {
        model.status.unstaged.map { ("u" + $0.id, $0, DiffSource.unstaged) }
            + model.status.staged.map { ("s" + $0.id, $0, DiffSource.staged) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    Section("Unstaged") {
                        ForEach(model.status.unstaged) { FileChangeRow(file: $0).tag("u" + $0.id) }
                    }
                    Section("Staged") {
                        ForEach(model.status.staged) { FileChangeRow(file: $0).tag("s" + $0.id) }
                    }
                }
                Button("Open commit dialog…", action: openCommit)
                    .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 320)
            DiffView(diff: diff)
                .frame(minWidth: 300)
        }
        .task(id: selected) {
            guard let entry = entries.first(where: { $0.id == selected }) else {
                diff = .empty
                return
            }
            diff = ParsedDiff((try? await model.repo.diff(for: entry.file, source: entry.source)) ?? "")
        }
    }
}
