import AppKit
import SwiftUI

/// Repository tabs: name, current branch and number of changed files per tab.
struct TabBarView: View {
    @Bindable var tabs: TabsModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, model in
                            RepoTab(model: model,
                                    index: index,
                                    isSelected: model.id == tabs.selectedId,
                                    tabs: tabs)
                                .id(model.id)
                            Divider().frame(height: 26)
                        }
                    }
                }
                .onChange(of: tabs.selectedId) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            newTabMenu
        }
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var newTabMenu: some View {
        Menu {
            Button("Open Repository…") { tabs.openWithPanel() }
            Button("Clone Repository…") { tabs.showClone = true }
            Button("New Repository…") { tabs.initWithPanel() }
            let openIds = Set(tabs.tabs.map(\.id))
            let recent = RecentRepos.all.filter { !openIds.contains($0) }.prefix(12)
            if !recent.isEmpty {
                Divider()
                Section("Recent") {
                    ForEach(Array(recent), id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            Task { await tabs.open(URL(fileURLWithPath: path)) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Open a repository in a new tab (⌘T)")
    }
}

private struct RepoTab: View {
    let model: RepoModel
    let index: Int
    let isSelected: Bool
    let tabs: TabsModel

    @State private var hovering = false

    private var changes: Int { model.status.totalCount }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let op = model.pendingOperation {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help(op)
                    }
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(model.currentBranch ?? "detached HEAD")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if changes > 0 {
                Text("\(changes)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
                    .help("\(changes) changed file(s)")
            }
            Button {
                tabs.close(model.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 150, maxWidth: 240, minHeight: 40, maxHeight: 40)
        .background(isSelected
                    ? Color(nsColor: .controlBackgroundColor)
                    : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(model.id) }
        .help(model.repo.url.path + (index < 9 ? "  (⌘\(index + 1))" : ""))
        .draggable(model.id)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            tabs.move(id, to: model.id)
            return true
        }
        .contextMenu {
            Button("Close Tab") { tabs.close(model.id) }
            Button("Close Other Tabs") { tabs.closeOthers(model.id) }
                .disabled(tabs.tabs.count < 2)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.repo.url])
            }
            Button("Open in Terminal") {
                NSWorkspace.shared.open([model.repo.url],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.repo.url.path, forType: .string)
            }
        }
    }
}
