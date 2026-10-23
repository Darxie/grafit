import XCTest
@testable import Grafit

/// Stash, conflicts, interactive rebase, reword, clone/init and config against real git repos.
final class HistoryTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grafit-hist-\(UUID().uuidString)")
        dir = root.appendingPathComponent("repo")
        try await GitRepository.initRepository(at: dir)
        repo = GitRepository(url: dir)
        try await repo.setConfig("user.name", "Test", scope: .local)
        try await repo.setConfig("user.email", "t@example.com", scope: .local)
        try await commitFile("a.txt", "one\n", "first")
        try await commitFile("a.txt", "one\ntwo\n", "second")
        try await commitFile("a.txt", "one\ntwo\nthree\n", "third")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commitFile(_ name: String, _ text: String, _ message: String) async throws {
        try write(name, text)
        try await repo.stage([name])
        _ = try await repo.commit(message: message, amend: false)
    }

    private func subjects() async throws -> [String] {
        try await repo.git.run(["log", "--format=%s"]).split(separator: "\n").map(String.init)
    }

    func testConfigReadWriteAndUnset() async throws {
        let initial = await repo.config("user.email", scope: .local)
        XCTAssertEqual(initial, "t@example.com")
        try await repo.setConfig("user.email", "new@example.com", scope: .local)
        let changed = await repo.config("user.email", scope: .local)
        XCTAssertEqual(changed, "new@example.com")
        try await repo.setConfig("user.email", "", scope: .local)
        let removed = await repo.config("user.email", scope: .local)
        XCTAssertNil(removed)
        try await repo.setConfig("user.email", "", scope: .local) // unsetting twice is fine
    }

    func testStashPushListApplyPopDrop() async throws {
        try write("a.txt", "changed\n")
        try write("new.txt", "untracked\n")
        _ = try await repo.stash(message: "wip one", includeUntracked: true, keepIndex: false)
        var status = try await repo.status()
        XCTAssertEqual(status.totalCount, 0)

        try write("a.txt", "changed again\n")
        _ = try await repo.stash(message: "wip two", includeUntracked: false, keepIndex: false)

        var stashes = await repo.stashes()
        XCTAssertEqual(stashes.map(\.message), ["wip two", "wip one"])
        XCTAssertEqual(stashes[1].name, "stash@{1}")
        let files = try await repo.changedFiles(sha: stashes[0].commit.sha, parent: stashes[0].commit.parents.first)
        XCTAssertEqual(files.map(\.path), ["a.txt"])

        _ = try await repo.stashDrop(stashes[0])
        stashes = await repo.stashes()
        XCTAssertEqual(stashes.map(\.message), ["wip one"])

        _ = try await repo.stashApply(stashes[0], pop: true)
        status = try await repo.status()
        XCTAssertEqual(Set(status.unstaged.map(\.path)), ["a.txt", "new.txt"])
        let stashesAfterPop = await repo.stashes()
        XCTAssertTrue(stashesAfterPop.isEmpty)
    }

    private func makeConflict() async throws {
        try await repo.git.run(["checkout", "-q", "-b", "other", "HEAD~1"])
        try await commitFile("a.txt", "one\ntwo\ntheirs\n", "theirs")
        try await repo.git.run(["checkout", "-q", "main"])
        do {
            _ = try await repo.merge("other", noFastForward: false)
            XCTFail("merge should conflict")
        } catch {}
    }

    func testResolveConflictWithTheirsThenContinue() async throws {
        try await makeConflict()
        var status = try await repo.status()
        let conflict = try XCTUnwrap(status.unstaged.first { $0.kind == .unmerged })
        XCTAssertEqual(conflict.conflictCode, "UU")
        XCTAssertTrue(repo.workingFile("a.txt").contains("<<<<<<<"))
        let pendingOperation = await repo.pendingOperation()
        XCTAssertEqual(pendingOperation, "Merge in progress")

        try await repo.resolve(conflict, using: .theirs)
        XCTAssertEqual(repo.workingFile("a.txt"), "one\ntwo\ntheirs\n")
        status = try await repo.status()
        XCTAssertFalse(status.unstaged.contains { $0.kind == .unmerged })

        _ = try await repo.continueOperation("Merge in progress")
        let pendingAfter = await repo.pendingOperation()
        XCTAssertNil(pendingAfter)
        let head = try await repo.log(limit: 1)
        XCTAssertTrue(head[0].isMerge)
    }

    func testResolveConflictWithOursAndAbort() async throws {
        try await makeConflict()
        let status = try await repo.status()
        let conflict = try XCTUnwrap(status.unstaged.first { $0.kind == .unmerged })
        try await repo.resolve(conflict, using: .ours)
        XCTAssertEqual(repo.workingFile("a.txt"), "one\ntwo\nthree\n")
        _ = try await repo.abortOperation("Merge in progress")
        let pending = await repo.pendingOperation()
        XCTAssertNil(pending)
    }

    func testRewordHeadAndOlderCommit() async throws {
        try write("staged.txt", "keep staged\n")
        try await repo.stage(["staged.txt"])

        let commits = try await repo.log(limit: 10)
        _ = try await repo.reword(commits[0].sha, message: "third (renamed)")
        var names = try await subjects()
        XCTAssertEqual(names, ["third (renamed)", "second", "first"])
        // Message-only amend must not swallow staged changes.
        let staged = try await repo.status().staged.map(\.path)
        XCTAssertEqual(staged, ["staged.txt"])

        let middle = try await repo.log(limit: 10)[1]
        _ = try await repo.reword(middle.sha, message: "second (renamed)\n\nwith body")
        names = try await subjects()
        XCTAssertEqual(names, ["third (renamed)", "second (renamed)", "first"])
        let body = try await repo.fullMessage(sha: try await repo.log(limit: 2)[1].sha)
        XCTAssertTrue(body.contains("with body"))
        // --autostash keeps staged work around the rebase.
        let stagedAfter = try await repo.status()
        XCTAssertEqual(stagedAfter.totalCount, 1)
    }

    func testInteractiveRebaseReorderSquashDrop() async throws {
        try await commitFile("b.txt", "b\n", "fourth")
        let first = try await repo.log(limit: 10).last!
        let (base, commits) = try await repo.commitsForRebase(from: first.sha)
        XCTAssertNil(base)
        XCTAssertEqual(commits.map(\.subject), ["first", "second", "third", "fourth"])

        // first, fourth (moved up), second + fixup third, drop nothing else
        var steps = commits.map { RebaseStep(commit: $0, message: $0.subject) }
        let fourth = steps.remove(at: 3)
        steps.insert(fourth, at: 1)
        steps[3].action = .fixup // "third" melds into "second"
        _ = try await repo.interactiveRebase(base: base, steps: steps)
        let afterReorder = try await subjects()
        XCTAssertEqual(afterReorder, ["second", "fourth", "first"])
        XCTAssertEqual(repo.workingFile("a.txt"), "one\ntwo\nthree\n")

        let again = try await repo.commitsForRebase(from: try await repo.log(limit: 10)[1].sha)
        XCTAssertEqual(again.commits.map(\.subject), ["fourth", "second"])
        var drop = again.commits.map { RebaseStep(commit: $0, message: $0.subject) }
        drop[0].action = .drop
        drop[1].action = .reword
        drop[1].message = "second + third"
        _ = try await repo.interactiveRebase(base: again.base, steps: drop)
        let afterDrop = try await subjects()
        XCTAssertEqual(afterDrop, ["second + third", "first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    func testCloneAndInit() async throws {
        let parent = root.appendingPathComponent("clones")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(GitRepository.folderName(forRemote: "git@github.com:org/my-repo.git"), "my-repo")
        XCTAssertEqual(GitRepository.folderName(forRemote: "https://github.com/org/other/"), "other")

        let cloned = try await GitRepository.clone(dir.path, into: parent, name: "copy")
        let clone = GitRepository(url: cloned)
        let clonedLog = try await clone.log(limit: 10)
        XCTAssertEqual(clonedLog.count, 3)
        let clonedBranch = await clone.currentBranch()
        XCTAssertEqual(clonedBranch, "main")

        try await clone.git.run(["remote", "set-head", "origin", "main"])
        let onRemote = await clone.remoteBranchesContaining(clonedLog[0].sha)
        XCTAssertEqual(onRemote, ["origin/main"])

        let fresh = root.appendingPathComponent("fresh/sub")
        try await GitRepository.initRepository(at: fresh)
        let top = await GitRepository.findTopLevel(of: fresh)
        XCTAssertEqual(top?.resolvingSymlinksInPath().path, fresh.resolvingSymlinksInPath().path)
        let freshBranch = await GitRepository(url: fresh).currentBranch()
        XCTAssertEqual(freshBranch, "main")
    }
}
