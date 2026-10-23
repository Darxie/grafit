import Foundation
import Observation

/// State of one open repository window.
@MainActor
@Observable
final class RepoModel {
    let repo: GitRepository
    var name: String { repo.url.lastPathComponent }

    var commits: [Commit] = []
    var graph: [GraphRow] = []
    var refs: [GitRef] = []
    var refsBySha: [String: [GitRef]] = [:]
    var headSha: String?
    var currentBranch: String?
    var pendingOperation: String?
    var status = WorkingStatus()

    var selectedSha: String?
    var isLoading = false
    var busyMessage: String?
    var errorMessage: String?
    var lastOutput: String?

    var commitLimit = 5000
    var filterText = ""

    static let workingTreeId = "__working_tree__"

    init(url: URL) {
        repo = GitRepository(url: url)
    }

    var selectedCommit: Commit? {
        guard let selectedSha, selectedSha != Self.workingTreeId else { return nil }
        return commits.first { $0.sha == selectedSha }
    }

    var localBranches: [GitRef] { refs.filter { $0.kind == .localBranch }.sorted { $0.shortName < $1.shortName } }
    var remoteBranches: [GitRef] { refs.filter { $0.kind == .remoteBranch }.sorted { $0.shortName < $1.shortName } }
    var tags: [GitRef] { refs.filter { $0.kind == .tag }.sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedDescending } }

    /// Indices into `commits` that match the filter (all when empty).
    var visibleIndices: [Int] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(commits.indices) }
        return commits.indices.filter { i in
            let c = commits[i]
            return c.subject.lowercased().contains(query)
                || c.authorName.lowercased().contains(query)
                || c.sha.hasPrefix(query)
                || (refsBySha[c.sha]?.contains { $0.shortName.lowercased().contains(query) } ?? false)
        }
    }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        async let commitsTask = repo.log(limit: commitLimit)
        async let refsTask = repo.refs()
        async let headTask = repo.headSha()
        async let branchTask = repo.currentBranch()
        async let statusTask = repo.status()
        async let opTask = repo.pendingOperation()

        do {
            let newCommits = try await commitsTask
            let newRefs = try await refsTask
            headSha = await headTask
            currentBranch = await branchTask
            pendingOperation = await opTask
            status = (try? await statusTask) ?? WorkingStatus()

            if newCommits.map(\.sha) != commits.map(\.sha) {
                commits = newCommits
                graph = GraphLayout.layout(newCommits)
            }
            refs = newRefs
            refsBySha = Dictionary(grouping: newRefs, by: \.target)
            let keepWorkingTree = selectedSha == Self.workingTreeId && status.totalCount > 0
            if !keepWorkingTree && (selectedSha == nil || !commits.contains(where: { $0.sha == selectedSha })) {
                selectedSha = headSha ?? commits.first?.sha
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Branch, working tree status and pending operation only (for inactive tabs).
    func refreshSummary() async {
        currentBranch = await repo.currentBranch()
        await refreshStatus()
    }

    func refreshStatus() async {
        status = (try? await repo.status()) ?? status
        pendingOperation = await repo.pendingOperation()
    }

    // MARK: - Running commands

    /// Runs a mutating git operation, shows errors, then reloads.
    func perform(_ message: String, _ operation: @escaping () async throws -> String) async {
        busyMessage = message
        defer { busyMessage = nil }
        do {
            let output = try await operation()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            lastOutput = trimmed.isEmpty ? nil : trimmed
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }
}
