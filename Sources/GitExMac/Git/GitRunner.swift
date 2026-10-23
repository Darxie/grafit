import Foundation

struct GitError: LocalizedError {
    let command: String
    let output: String
    let status: Int32

    var errorDescription: String? {
        "git \(command) failed (\(status)):\n\(output)"
    }
}

/// Runs the git CLI in a working directory, same approach as Git Extensions.
struct GitRunner {
    let workingDirectory: URL

    static var gitPath: String {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }

    @discardableResult
    func run(_ args: [String], input: Data? = nil, okStatuses: Set<Int32> = [0]) async throws -> String {
        let data = try await runData(args, input: input, okStatuses: okStatuses)
        return String(decoding: data, as: UTF8.self)
    }

    func runData(_ args: [String], input: Data? = nil, okStatuses: Set<Int32> = [0]) async throws -> Data {
        let dir = workingDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.runBlocking(args, in: dir, input: input, okStatuses: okStatuses))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(_ args: [String], in dir: URL, input: Data?, okStatuses: Set<Int32>) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitRunner.gitPath)
        process.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=never"] + args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C.UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = inPipe

        try process.run()
        if let input {
            inPipe.fileHandleForWriting.write(input)
        }
        try? inPipe.fileHandleForWriting.close()

        // Read both pipes concurrently so large outputs don't deadlock.
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()

        if !okStatuses.contains(process.terminationStatus) {
            let message = String(decoding: errData.isEmpty ? outData : errData, as: UTF8.self)
            throw GitError(command: args.joined(separator: " "),
                           output: message.trimmingCharacters(in: .whitespacesAndNewlines),
                           status: process.terminationStatus)
        }
        return outData
    }
}
