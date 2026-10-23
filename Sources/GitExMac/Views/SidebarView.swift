import SwiftUI

/// Left panel with branches, remotes and tags (Git Extensions' "repo objects tree").
struct SidebarView: View {
    @Bindable var model: RepoModel
    let onAction: (CommitAction) -> Void

    private var remotes: [(name: String, branches: [GitRef])] {
        Dictionary(grouping: model.remoteBranches) { $0.remoteName ?? "" }
            .map { ($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section("Branches") {
                ForEach(model.localBranches) { ref in
                    refRow(ref, icon: "arrow.triangle.branch",
                           isCurrent: ref.shortName == model.currentBranch)
                }
            }
            ForEach(remotes, id: \.name) { remote in
                Section("Remote: \(remote.name)") {
                    ForEach(remote.branches) { ref in
                        refRow(ref, icon: "cloud", label: ref.remoteBranchName ?? ref.shortName)
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { ref in
                        refRow(ref, icon: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func refRow(_ ref: GitRef, icon: String, label: String? = nil, isCurrent: Bool = false) -> some View {
        Label {
            Text(label ?? ref.shortName)
                .fontWeight(isCurrent ? .bold : .regular)
                .lineLimit(1)
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : icon)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if ref.kind != .tag && !isCurrent { onAction(.checkoutBranch(ref)) }
        }
        .simultaneousGesture(TapGesture().onEnded { model.selectedSha = ref.target })
        .contextMenu {
            if ref.kind != .tag {
                Button("Checkout") { onAction(.checkoutBranch(ref)) }
                    .disabled(isCurrent)
            }
            if !isCurrent {
                Button("Merge into \(model.currentBranch ?? "HEAD")") {
                    onAction(.merge(target: ref.shortName, label: ref.shortName))
                }
                Button("Rebase \(model.currentBranch ?? "HEAD") on this") {
                    onAction(.rebase(target: ref.shortName, label: ref.shortName))
                }
            }
            if let commit = model.commits.first(where: { $0.sha == ref.target }) {
                Button("Create branch here…") { onAction(.createBranch(commit)) }
            }
            Divider()
            if ref.kind == .tag {
                Button("Delete tag…") { onAction(.deleteTag(ref)) }
            } else if !isCurrent {
                Button("Delete branch…") { onAction(.deleteBranch(ref)) }
            }
        }
    }
}
