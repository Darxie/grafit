import SwiftUI

/// Bottom pane: changed files + diff, or commit info, for the selected commit.
struct CommitDetailView: View {
    @Bindable var model: RepoModel
    let commit: Commit

    enum Tab: String, CaseIterable { case diff = "Diff", info = "Commit" }

    @AppStorage("detailTab") private var tab: Tab = .diff
    @State private var parentIndex = 0
    @State private var files: [FileChange] = []
    @State private var selectedFile: FileChange.ID?
    @State private var diff = ParsedDiff.empty
    @State private var message = ""
    @State private var details: [String] = []
    @State private var containedIn: [String] = []

    private var parent: String? {
        commit.parents.isEmpty ? nil : commit.parents[min(parentIndex, commit.parents.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if commit.isMerge && tab == .diff {
                    Picker("Compare with", selection: $parentIndex) {
                        ForEach(commit.parents.indices, id: \.self) { i in
                            Text("Parent \(i + 1) (\(commit.parents[i].prefix(8)))").tag(i)
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Text(commit.subject)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()

            switch tab {
            case .diff:
                HSplitView {
                    List(files, selection: $selectedFile) { file in
                        FileChangeRow(file: file)
                    }
                    .frame(minWidth: 200, idealWidth: 320)
                    DiffView(diff: diff)
                        .frame(minWidth: 300)
                }
            case .info:
                infoView
            }
        }
        .task(id: "\(commit.sha)-\(parentIndex)") { await loadFiles() }
        .task(id: commit.sha) { await loadInfo() }
        .onChange(of: selectedFile) { _, _ in Task { await loadDiff() } }
        .onChange(of: commit.sha) { _, _ in parentIndex = 0 }
    }

    private var infoView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    infoRow("Commit", commit.sha)
                    if details.count >= 4 {
                        infoRow("Author", details[0])
                        infoRow("Date", details[1])
                        infoRow("Committer", details[2])
                        infoRow("Commit date", details[3])
                    }
                    GridRow {
                        Text("Parents").foregroundStyle(.secondary)
                        HStack {
                            ForEach(commit.parents, id: \.self) { p in
                                Button(String(p.prefix(10))) { model.selectedSha = p }
                                    .buttonStyle(.link)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    if !containedIn.isEmpty {
                        infoRow("Contained in", containedIn.joined(separator: ", "))
                    }
                }
                Divider()
                Text(message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func loadFiles() async {
        let loaded = (try? await model.repo.changedFiles(sha: commit.sha, parent: parent)) ?? []
        files = loaded
        if selectedFile == nil || !loaded.contains(where: { $0.id == selectedFile }) {
            selectedFile = loaded.first?.id
        }
        await loadDiff()
    }

    private func loadDiff() async {
        guard let file = files.first(where: { $0.id == selectedFile }) else {
            diff = .empty
            return
        }
        let text = (try? await model.repo.diff(for: file, source: .commit(sha: commit.sha, parent: parent))) ?? ""
        diff = ParsedDiff(text)
    }

    private func loadInfo() async {
        message = (try? await model.repo.fullMessage(sha: commit.sha)) ?? commit.subject
        details = ((try? await model.repo.commitDetails(sha: commit.sha)) ?? "")
            .split(separator: "\n").map(String.init)
        containedIn = await model.repo.containingBranches(sha: commit.sha)
    }
}
