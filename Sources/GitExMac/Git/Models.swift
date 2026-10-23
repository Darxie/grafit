import Foundation

struct Commit: Identifiable, Hashable {
    let sha: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let commitDate: Date
    let subject: String

    var id: String { sha }
    var shortSha: String { String(sha.prefix(8)) }
    var isMerge: Bool { parents.count > 1 }
}

enum RefKind: Int, Comparable {
    case head, localBranch, remoteBranch, tag, stash, other

    static func < (lhs: RefKind, rhs: RefKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct GitRef: Identifiable, Hashable {
    let fullName: String
    let target: String
    let kind: RefKind

    var id: String { fullName }

    var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/", "refs/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }

    /// For remote branches: "origin/feature" -> remote "origin", branch "feature".
    var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return shortName.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    var remoteBranchName: String? {
        guard kind == .remoteBranch else { return nil }
        let parts = shortName.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

enum ChangeKind: String {
    case added = "A", modified = "M", deleted = "D", renamed = "R", copied = "C"
    case typeChanged = "T", unmerged = "U", untracked = "?", unknown = "X"

    init(code: Character) {
        self = ChangeKind(rawValue: String(code)) ?? .unknown
    }

    var label: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "!"
        case .untracked: "?"
        case .unknown: "·"
        }
    }
}

struct FileChange: Identifiable, Hashable {
    let path: String
    let oldPath: String?
    let kind: ChangeKind

    var id: String { (oldPath ?? "") + "\u{0}" + path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct WorkingStatus {
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []

    var totalCount: Int {
        Set(staged.map(\.path)).union(unstaged.map(\.path)).count
    }
}

enum ResetMode: String, CaseIterable {
    case soft, mixed, hard
}

/// Which pair of trees a file diff compares.
enum DiffSource: Hashable {
    case commit(sha: String, parent: String?)
    case staged
    case unstaged
}
