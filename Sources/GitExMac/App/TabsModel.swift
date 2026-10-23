import AppKit
import Observation

extension RepoModel: Identifiable {
    nonisolated var id: String { repo.url.path }
}

/// Open repositories shown as tabs in the main window. The list is persisted,
/// so the same repositories are open again after a restart.
@MainActor
@Observable
final class TabsModel {
    static let shared = TabsModel()

    private static let tabsKey = "openTabs"
    private static let selectedKey = "selectedTab"

    private(set) var tabs: [RepoModel] = []
    private(set) var selectedId: String?
    var openError: String?

    var selected: RepoModel? { tabs.first { $0.id == selectedId } }

    private init() {
        let paths = (UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        tabs = paths.map { RepoModel(url: URL(fileURLWithPath: $0)) }
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        selectedId = tabs.contains { $0.id == saved } ? saved : tabs.first?.id

        Task {
            if let arg = RecentRepos.launchArgument {
                await open(URL(fileURLWithPath: arg))
            }
            await selected?.reload()
            await refreshSummaries()
        }
    }

    // MARK: - Opening and closing

    func open(_ url: URL) async {
        guard let top = await GitRepository.findTopLevel(of: url) else {
            openError = "\(url.path) is not a git repository."
            return
        }
        openError = nil
        RecentRepos.add(top.path)
        if tabs.contains(where: { $0.id == top.path }) {
            select(top.path)
            return
        }
        let model = RepoModel(url: top)
        let insertAt = tabs.firstIndex { $0.id == selectedId }.map { $0 + 1 } ?? tabs.count
        tabs.insert(model, at: insertAt)
        selectedId = model.id
        persist()
        await model.reload()
    }

    func openWithPanel() {
        guard let url = chooseRepositoryFolder() else { return }
        Task { await open(url) }
    }

    func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedId == id {
            selectedId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            if let selected { Task { await selected.reload() } }
        }
        persist()
    }

    func closeOthers(_ id: String) {
        tabs.removeAll { $0.id != id }
        select(id)
        persist()
    }

    // MARK: - Selection and order

    func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if selectedId != id {
            selectedId = id
            persist()
        }
        if let selected { Task { await selected.reload() } }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    func selectNext(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedId } ?? 0
        select(index: (current + offset + tabs.count) % tabs.count)
    }

    /// Moves the tab `id` to the position of `target` (drag and drop).
    func move(_ id: String, to target: String) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        persist()
    }

    // MARK: - Background refresh

    /// Updates branch and change count of every tab (cheap: status + symbolic-ref).
    func refreshSummaries() async {
        for tab in tabs {
            await tab.refreshSummary()
        }
    }

    private func persist() {
        UserDefaults.standard.set(tabs.map(\.id), forKey: Self.tabsKey)
        UserDefaults.standard.set(selectedId, forKey: Self.selectedKey)
    }
}
