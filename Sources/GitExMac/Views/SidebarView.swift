import SwiftUI

/// A folder ("feature", "bugfix", ...) or a ref in the sidebar tree, built by splitting ref names on "/".
struct RefNode: Identifiable {
    let id: String
    let name: String
    var ref: GitRef?
    var children: [RefNode] = []

    var isFolder: Bool { ref == nil }
    var leafCount: Int { isFolder ? children.reduce(0) { $0 + $1.leafCount } : 1 }

    static func tree(_ refs: [GitRef], idPrefix: String, name: (GitRef) -> String) -> [RefNode] {
        build(refs.map { (name($0).split(separator: "/").map(String.init), $0) }, idPrefix: idPrefix)
    }

    private static func build(_ items: [(components: [String], ref: GitRef)], idPrefix: String) -> [RefNode] {
        var folders: [String: [(components: [String], ref: GitRef)]] = [:]
        var leaves: [RefNode] = []
        for item in items {
            guard let first = item.components.first else { continue }
            if item.components.count == 1 {
                leaves.append(RefNode(id: idPrefix + first, name: first, ref: item.ref))
            } else {
                folders[first, default: []].append((Array(item.components.dropFirst()), item.ref))
            }
        }
        let folderNodes = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            RefNode(id: idPrefix + key + "/", name: key, ref: nil,
                    children: build(folders[key]!, idPrefix: idPrefix + key + "/"))
        }
        return folderNodes + leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Left panel with branches, remotes and tags (Git Extensions' "repo objects tree").
/// Branch names with "/" are grouped into collapsible folders (feature/, bugfix/, release/, ...).
struct SidebarView: View {
    @Bindable var model: RepoModel
    let onAction: (CommitAction) -> Void

    @State private var expanded: Set<String> = []
    @State private var filter = ""
    @AppStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false

    private var expansionKey: String { "sidebar.expanded:" + model.repo.url.path }

    private func matches(_ ref: GitRef) -> Bool {
        filter.isEmpty || ref.shortName.localizedCaseInsensitiveContains(filter)
    }

    private var localTree: [RefNode] {
        RefNode.tree(model.localBranches.filter(matches), idPrefix: "local:") { $0.shortName }
    }

    private var remoteTrees: [(name: String, nodes: [RefNode])] {
        Dictionary(grouping: model.remoteBranches.filter(matches)) { $0.remoteName ?? "" }
            .map { remote, refs in
                (remote, RefNode.tree(refs, idPrefix: "remote:\(remote)/") { $0.remoteBranchName ?? $0.shortName })
            }
            .sorted { $0.name < $1.name }
    }

    private var tagTree: [RefNode] {
        RefNode.tree(model.tags.filter(matches), idPrefix: "tag:") { $0.shortName }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            List {
                Section("Branches", isExpanded: $branchesExpanded) {
                    nodes(localTree)
                }
                if !remoteTrees.isEmpty {
                    Section("Remotes", isExpanded: $remotesExpanded) {
                        ForEach(remoteTrees, id: \.name) { remote in
                            folder(RefNode(id: "remote:\(remote.name)", name: remote.name, ref: nil, children: remote.nodes),
                                   icon: "network")
                        }
                    }
                }
                if !tagTree.isEmpty {
                    Section("Tags", isExpanded: $tagsExpanded) {
                        nodes(tagTree)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear {
            expanded = Set(UserDefaults.standard.stringArray(forKey: expansionKey) ?? [])
            expandCurrentBranch()
        }
        .onChange(of: model.currentBranch) { _, _ in expandCurrentBranch() }
        .onChange(of: expanded) { _, value in
            UserDefaults.standard.set(Array(value), forKey: expansionKey)
        }
    }

    private func expandCurrentBranch() {
        guard let branch = model.currentBranch else { return }
        var path = "local:"
        for component in branch.split(separator: "/").dropLast() {
            path += component + "/"
            expanded.insert(path)
        }
    }

    // MARK: - Tree rendering

    private func nodes(_ nodes: [RefNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if node.isFolder {
                folder(node, icon: "folder")
            } else if let ref = node.ref {
                refRow(ref, label: node.name)
            }
        })
    }

    private func folder(_ node: RefNode, icon: String) -> AnyView {
        // While filtering, show everything that matches without needing to expand.
        let isExpanded = Binding(
            get: { !filter.isEmpty || expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
        return AnyView(DisclosureGroup(isExpanded: isExpanded) {
            nodes(node.children)
        } label: {
            HStack {
                Label(node.name, systemImage: icon)
                Spacer()
                Text("\(node.leafCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        })
    }

    private func refRow(_ ref: GitRef, label: String) -> some View {
        let isCurrent = ref.kind == .localBranch && ref.shortName == model.currentBranch
        let icon: String
        switch ref.kind {
        case .tag: icon = "tag"
        case .remoteBranch: icon = "cloud"
        default: icon = "arrow.triangle.branch"
        }
        return Label {
            Text(label)
                .fontWeight(isCurrent ? .bold : .regular)
                .lineLimit(1)
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : icon)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .help(ref.shortName)
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
