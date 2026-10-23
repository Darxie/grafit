import XCTest
@testable import GitExMac

final class GitExMacTests: XCTestCase {
    private var dir: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitexmac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = GitRepository(url: dir)
        try await repo.git.run(["init", "-q", "-b", "main"])
        try await repo.git.run(["config", "user.name", "Test"])
        try await repo.git.run(["config", "user.email", "t@example.com"])
        try "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(["f.txt"])
        _ = try await repo.commit(message: "initial", amend: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws {
        try text.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    }

    private let file = FileChange(path: "f.txt", oldPath: nil, kind: .modified)

    func testStageAndUnstageSelectedLines() async throws {
        try write("a\nB\nc\nd\ne\nf\ng\nh\nI\nj\nk\n")
        let unstaged = ParsedDiff(try await repo.diff(for: file, source: .unstaged, contextLines: 1))

        // Stage only the change of line "b" -> "B".
        let ids = Set(unstaged.lines.filter { $0.isChange && ($0.text == "b" || $0.text == "B") }.map(\.id))
        let patch = try XCTUnwrap(unstaged.partialPatch(selected: ids, reverse: false))
        try await repo.apply(patch: patch, cached: true, reverse: false)

        let staged = try await repo.diff(for: file, source: .staged)
        XCTAssertTrue(staged.contains("+B"))
        XCTAssertFalse(staged.contains("+I"))
        XCTAssertFalse(staged.contains("+k"))

        // Stage only the added "k" line (unselected "i" -> "I" must stay unstaged).
        let rest = ParsedDiff(try await repo.diff(for: file, source: .unstaged, contextLines: 1))
        let kId = Set(rest.lines.filter { $0.kind == .added && $0.text == "k" }.map(\.id))
        try await repo.apply(patch: XCTUnwrap(rest.partialPatch(selected: kId, reverse: false)), cached: true, reverse: false)
        let staged2 = try await repo.diff(for: file, source: .staged)
        XCTAssertTrue(staged2.contains("+k"))
        XCTAssertFalse(staged2.contains("+I"))

        // Unstage the "B" change again.
        let stagedDiff = ParsedDiff(staged2)
        let bIds = Set(stagedDiff.lines.filter { $0.isChange && ($0.text == "b" || $0.text == "B") }.map(\.id))
        try await repo.apply(patch: XCTUnwrap(stagedDiff.partialPatch(selected: bIds, reverse: true)), cached: true, reverse: true)
        let staged3 = try await repo.diff(for: file, source: .staged)
        XCTAssertFalse(staged3.contains("+B"))
        XCTAssertTrue(staged3.contains("+k"))

        // Working tree is untouched by index operations.
        let content = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content, "a\nB\nc\nd\ne\nf\ng\nh\nI\nj\nk\n")
    }

    func testDiscardSelectedLines() async throws {
        try write("a\nB\nc\nd\ne\nf\ng\nh\nI\nj\n")
        let diff = ParsedDiff(try await repo.diff(for: file, source: .unstaged))
        let ids = Set(diff.lines.filter { $0.isChange && ($0.text == "i" || $0.text == "I") }.map(\.id))
        try await repo.apply(patch: XCTUnwrap(diff.partialPatch(selected: ids, reverse: true)), cached: false, reverse: true)
        let content = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content, "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\n")
    }

    func testStatusAndLogWithMerge() async throws {
        try await repo.git.run(["checkout", "-q", "-b", "feature"])
        try write("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nfeature\n")
        _ = try await repo.git.run(["commit", "-qam", "feature work"])
        try await repo.git.run(["checkout", "-q", "main"])
        try "x\n".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(["other.txt"])
        _ = try await repo.commit(message: "main work", amend: false)
        _ = try await repo.merge("feature", noFastForward: true)

        let commits = try await repo.log(limit: 100)
        XCTAssertEqual(commits.count, 4)
        XCTAssertTrue(commits[0].isMerge)

        let rows = GraphLayout.layout(commits)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].nodeLane, 0)
        XCTAssertEqual(rows.map(\.laneCount).max(), 2)
        XCTAssertEqual(rows.last?.nodeLane, 0)

        let refs = try await repo.refs()
        XCTAssertEqual(Set(refs.map(\.shortName)), ["main", "feature"])

        try "y\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try write("changed\n")
        let status = try await repo.status()
        XCTAssertEqual(Set(status.unstaged.map(\.kind)), [.modified, .untracked])
        XCTAssertTrue(status.staged.isEmpty)

        let files = try await repo.changedFiles(sha: commits[0].sha, parent: commits[0].parents[0])
        XCTAssertEqual(files.map(\.path), ["f.txt"])
    }
}

final class RefTreeTests: XCTestCase {
    func testGroupsBranchesIntoFolders() {
        let names = ["main", "feature/login", "feature/ui/dark", "bugfix/crash", "develop"]
        let refs = names.map { GitRef(fullName: "refs/heads/\($0)", target: "x", kind: .localBranch) }
        let tree = RefNode.tree(refs, idPrefix: "local:") { $0.shortName }

        XCTAssertEqual(tree.map(\.name), ["bugfix", "feature", "develop", "main"])
        let feature = tree[1]
        XCTAssertTrue(feature.isFolder)
        XCTAssertEqual(feature.id, "local:feature/")
        XCTAssertEqual(feature.leafCount, 2)
        XCTAssertEqual(feature.children.map(\.name), ["ui", "login"])
        XCTAssertEqual(feature.children[0].children.first?.ref?.shortName, "feature/ui/dark")
    }
}

final class TagTreeTests: XCTestCase {
    func testVersionTagsSortNewestFirst() {
        let names = ["4.0.0", "4.10.0", "4.2.1", "5.0.0"]
        let refs = names.map { GitRef(fullName: "refs/tags/\($0)", target: "x", kind: .tag) }
        let tree = RefNode.tree(refs, idPrefix: "tag:", descending: true) { $0.shortName }
        XCTAssertEqual(tree.map(\.name), ["5.0.0", "4.10.0", "4.2.1", "4.0.0"])
    }
}
