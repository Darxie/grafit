import Foundation

/// Thin, stateless wrapper around git commands for one repository.
struct GitRepository {
    let url: URL
    let git: GitRunner

    init(url: URL) {
        self.url = url
        self.git = GitRunner(workingDirectory: url)
    }

    static func findTopLevel(of url: URL) async -> URL? {
        let runner = GitRunner(workingDirectory: url)
        guard let out = try? await runner.run(["rev-parse", "--show-toplevel"]) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // MARK: - Reading

    func log(limit: Int) async throws -> [Commit] {
        let format = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ct", "%s"].joined(separator: "%x1f") + "%x1e"
        let out = try await git.run([
            "log", "--branches", "--remotes", "--tags", "HEAD",
            "--topo-order", "--max-count=\(limit)", "--format=\(format)",
        ], okStatuses: [0, 128])
        return out.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { return nil }
            return Commit(
                sha: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                authorDate: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                committerName: String(fields[5]),
                commitDate: Date(timeIntervalSince1970: TimeInterval(fields[6]) ?? 0),
                subject: fields[7...].joined(separator: "\u{1f}")
            )
        }
    }

    func refs() async throws -> [GitRef] {
        let out = try await git.run([
            "for-each-ref", "--format=%(objectname)%1f%(*objectname)%1f%(refname)",
            "refs/heads", "refs/remotes", "refs/tags",
        ])
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { return nil }
            let name = f[2]
            if name.hasSuffix("/HEAD") && name.hasPrefix("refs/remotes/") { return nil }
            let kind: RefKind
            if name.hasPrefix("refs/heads/") { kind = .localBranch }
            else if name.hasPrefix("refs/remotes/") { kind = .remoteBranch }
            else if name.hasPrefix("refs/tags/") { kind = .tag }
            else { kind = .other }
            // Annotated tags point to a tag object; the peeled commit is in *objectname.
            return GitRef(fullName: name, target: f[1].isEmpty ? f[0] : f[1], kind: kind)
        }
    }

    func headSha() async -> String? {
        let out = try? await git.run(["rev-parse", "--verify", "-q", "HEAD"])
        let sha = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sha.isEmpty ? nil : sha
    }

    func currentBranch() async -> String? {
        let out = try? await git.run(["symbolic-ref", "-q", "--short", "HEAD"])
        let name = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Short description of an in-progress operation (merge, rebase, ...), if any.
    func pendingOperation() async -> String? {
        guard let gitDirOut = try? await git.run(["rev-parse", "--absolute-git-dir"]) else { return nil }
        let gitDir = URL(fileURLWithPath: gitDirOut.trimmingCharacters(in: .whitespacesAndNewlines))
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("rebase-merge", "Rebase in progress"),
            ("rebase-apply", "Rebase in progress"),
            ("MERGE_HEAD", "Merge in progress"),
            ("CHERRY_PICK_HEAD", "Cherry-pick in progress"),
            ("REVERT_HEAD", "Revert in progress"),
        ]
        for (file, label) in checks where fm.fileExists(atPath: gitDir.appendingPathComponent(file).path) {
            return label
        }
        return nil
    }

    func status() async throws -> WorkingStatus {
        let data = try await git.runData(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let entries = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result = WorkingStatus()
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            i += 1
            guard entry.count >= 4 else { continue }
            let chars = Array(entry)
            let x = chars[0], y = chars[1]
            let path = String(chars[3...])
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                oldPath = i < entries.count ? entries[i] : nil
                i += 1
            }
            if x == "?" {
                result.unstaged.append(FileChange(path: path, oldPath: nil, kind: .untracked))
                continue
            }
            if x == "!" { continue }
            let conflicted = x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
            if conflicted {
                result.unstaged.append(FileChange(path: path, oldPath: nil, kind: .unmerged))
                continue
            }
            if x != " " {
                result.staged.append(FileChange(path: path, oldPath: oldPath, kind: ChangeKind(code: x)))
            }
            if y != " " {
                result.unstaged.append(FileChange(path: path, oldPath: nil, kind: ChangeKind(code: y)))
            }
        }
        return result
    }

    func changedFiles(sha: String, parent: String?) async throws -> [FileChange] {
        var args = ["diff-tree", "-r", "-M", "--name-status", "-z", "--no-commit-id"]
        if let parent { args += [parent, sha] } else { args += ["--root", sha] }
        let data = try await git.runData(args)
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [FileChange] = []
        var i = 0
        while i < parts.count {
            let code = parts[i]
            i += 1
            guard let first = code.first, i < parts.count else { continue }
            if first == "R" || first == "C" {
                guard i + 1 < parts.count else { break }
                files.append(FileChange(path: parts[i + 1], oldPath: parts[i], kind: ChangeKind(code: first)))
                i += 2
            } else {
                files.append(FileChange(path: parts[i], oldPath: nil, kind: ChangeKind(code: first)))
                i += 1
            }
        }
        return files
    }

    func diff(for file: FileChange, source: DiffSource, contextLines: Int = 3) async throws -> String {
        var paths = [file.path]
        if let old = file.oldPath { paths.insert(old, at: 0) }
        let common = ["-M", "--no-ext-diff", "-U\(contextLines)"]
        switch source {
        case .commit(let sha, let parent?):
            return try await git.run(["diff"] + common + [parent, sha, "--"] + paths)
        case .commit(let sha, nil):
            return try await git.run(["diff-tree", "-p", "--root"] + common + [sha, "--"] + paths)
        case .staged:
            return try await git.run(["diff", "--cached"] + common + ["--"] + paths)
        case .unstaged:
            if file.kind == .untracked {
                return try await git.run(["diff", "--no-index"] + common + ["--", "/dev/null", file.path], okStatuses: [0, 1])
            }
            return try await git.run(["diff"] + common + ["--"] + paths)
        }
    }

    func fullMessage(sha: String) async throws -> String {
        try await git.run(["log", "-1", "--format=%B", sha])
    }

    func commitDetails(sha: String) async throws -> String {
        try await git.run(["log", "-1", "--format=%an <%ae>%n%aD%n%cn <%ce>%n%cD", sha])
    }

    func containingBranches(sha: String) async -> [String] {
        let out = (try? await git.run(["branch", "-a", "--contains", sha, "--format=%(refname:short)"])) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    // MARK: - Index / working tree

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["add", "-A", "--"] + paths)
    }

    func unstage(_ paths: [String], hasHead: Bool) async throws {
        guard !paths.isEmpty else { return }
        if hasHead {
            try await git.run(["reset", "-q", "HEAD", "--"] + paths)
        } else {
            try await git.run(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    func discard(_ files: [FileChange]) async throws {
        let untracked = files.filter { $0.kind == .untracked }.map(\.path)
        let tracked = files.filter { $0.kind != .untracked }.map(\.path)
        if !tracked.isEmpty {
            try await git.run(["checkout", "--"] + tracked)
        }
        if !untracked.isEmpty {
            try await git.run(["clean", "-f", "-q", "--"] + untracked)
        }
    }

    /// Applies a (partial) patch to the index or working tree.
    func apply(patch: String, cached: Bool, reverse: Bool) async throws {
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        args.append("-")
        try await git.run(args, input: Data(patch.utf8))
    }

    func commit(message: String, amend: Bool) async throws -> String {
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        return try await git.run(args, input: Data(message.utf8))
    }

    // MARK: - Branch / history operations

    func checkout(_ target: String) async throws -> String {
        try await git.run(["checkout", target])
    }

    func checkoutRemoteBranch(_ ref: GitRef) async throws -> String {
        guard let local = ref.remoteBranchName else { return "" }
        let localExists = (try? await git.run(["show-ref", "--verify", "-q", "refs/heads/\(local)"])) != nil
        if localExists {
            return try await git.run(["checkout", local])
        }
        return try await git.run(["checkout", "-b", local, "--track", ref.shortName])
    }

    func createBranch(_ name: String, at sha: String, checkout: Bool) async throws -> String {
        if checkout {
            return try await git.run(["checkout", "-b", name, sha])
        }
        return try await git.run(["branch", name, sha])
    }

    func deleteBranch(_ name: String, force: Bool) async throws -> String {
        try await git.run(["branch", force ? "-D" : "-d", name])
    }

    func deleteRemoteBranch(_ ref: GitRef) async throws -> String {
        guard let remote = ref.remoteName, let branch = ref.remoteBranchName else { return "" }
        return try await git.run(["push", remote, "--delete", branch])
    }

    func createTag(_ name: String, at sha: String, message: String?) async throws -> String {
        if let message, !message.isEmpty {
            return try await git.run(["tag", "-a", name, "-m", message, sha])
        }
        return try await git.run(["tag", name, sha])
    }

    func deleteTag(_ name: String) async throws -> String {
        try await git.run(["tag", "-d", name])
    }

    func merge(_ target: String, noFastForward: Bool) async throws -> String {
        var args = ["merge"]
        if noFastForward { args.append("--no-ff") }
        args.append(target)
        return try await git.run(args)
    }

    func rebase(onto target: String) async throws -> String {
        try await git.run(["rebase", target])
    }

    func cherryPick(_ sha: String, isMerge: Bool) async throws -> String {
        var args = ["cherry-pick"]
        if isMerge { args += ["-m", "1"] }
        args.append(sha)
        return try await git.run(args)
    }

    func revert(_ sha: String, isMerge: Bool) async throws -> String {
        var args = ["revert", "--no-edit"]
        if isMerge { args += ["-m", "1"] }
        args.append(sha)
        return try await git.run(args)
    }

    func reset(to sha: String, mode: ResetMode) async throws -> String {
        try await git.run(["reset", "--\(mode.rawValue)", sha])
    }

    func abortOperation(_ operation: String) async throws -> String {
        let command: String
        if operation.hasPrefix("Rebase") { command = "rebase" }
        else if operation.hasPrefix("Cherry") { command = "cherry-pick" }
        else if operation.hasPrefix("Revert") { command = "revert" }
        else { command = "merge" }
        return try await git.run([command, "--abort"])
    }

    func continueOperation(_ operation: String) async throws -> String {
        let command: String
        if operation.hasPrefix("Rebase") { command = "rebase" }
        else if operation.hasPrefix("Cherry") { command = "cherry-pick" }
        else if operation.hasPrefix("Revert") { command = "revert" }
        else { return try await git.run(["commit", "--no-edit"]) }
        return try await git.run(["-c", "core.editor=true", command, "--continue"])
    }

    // MARK: - Remotes

    func fetch() async throws -> String {
        try await git.run(["fetch", "--all", "--prune"])
    }

    func pull(rebase: Bool) async throws -> String {
        try await git.run(["pull", rebase ? "--rebase" : "--no-rebase"])
    }

    func push(branch: String, setUpstream: Bool, force: Bool) async throws -> String {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if setUpstream { args += ["-u", "origin", branch] }
        return try await git.run(args)
    }

    func hasUpstream(branch: String) async -> Bool {
        (try? await git.run(["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"])) != nil
    }
}
