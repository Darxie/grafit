import AppKit
import SwiftUI

@main
struct GitExMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Git Extensions", for: String.self) { $path in
            RootView(path: $path)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            RepoCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply()
        scheduleDebugSnapshot()
    }

    /// GITEXMAC_SNAPSHOT=/path/prefix writes PNGs of all windows after a few seconds (for development).
    private func scheduleDebugSnapshot() {
        guard let prefix = ProcessInfo.processInfo.environment["GITEXMAC_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App-wide appearance; dark unless the user switched it off in the View menu.
enum Appearance {
    static let key = "darkMode"

    static var isDark: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    @MainActor
    static func apply() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// Recently opened repositories, most recent first.
enum RecentRepos {
    private static let key = "recentRepositories"

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    static func add(_ path: String) {
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(20)), forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all.filter { $0 != path }, forKey: key)
    }

    /// Path passed on the command line (`GitExMac.app/Contents/MacOS/GitExMac /path/to/repo`).
    static var launchArgument: String? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let first = args.first else { return nil }
        return URL(fileURLWithPath: first).standardizedFileURL.path
    }
}

@MainActor
func chooseRepositoryFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a git repository"
    return panel.runModal() == .OK ? panel.url : nil
}

struct RootView: View {
    @Binding var path: String?
    @State private var model: RepoModel?
    @State private var openError: String?

    var body: some View {
        Group {
            if let model {
                RepoView(model: model, onClose: { path = nil })
                    .navigationTitle(model.name)
                    .navigationSubtitle(model.repo.url.path)
            } else {
                WelcomeView(open: { open($0) }, error: openError)
                    .navigationTitle("Git Extensions")
            }
        }
        .task(id: path) {
            await load()
        }
    }

    private func open(_ url: URL) {
        Task {
            guard let top = await GitRepository.findTopLevel(of: url) else {
                openError = "\(url.path) is not a git repository."
                return
            }
            openError = nil
            path = top.path
        }
    }

    private func load() async {
        if path == nil, model == nil, let arg = RecentRepos.launchArgument, !LaunchState.consumedArgument {
            LaunchState.consumedArgument = true
            open(URL(fileURLWithPath: arg))
            return
        }
        guard let path else {
            model = nil
            return
        }
        if model?.repo.url.path == path { return }
        RecentRepos.add(path)
        let newModel = RepoModel(url: URL(fileURLWithPath: path))
        model = newModel
        await newModel.reload()
    }
}

@MainActor
enum LaunchState {
    static var consumedArgument = false
}

// MARK: - Menu commands

struct FocusedRepoKey: FocusedValueKey {
    typealias Value = RepoActions
}

extension FocusedValues {
    var repoActions: RepoActions? {
        get { self[FocusedRepoKey.self] }
        set { self[FocusedRepoKey.self] = newValue }
    }
}

/// Actions the focused repository window exposes to the menu bar.
struct RepoActions {
    let refresh: () -> Void
    let commit: () -> Void
    let fetch: () -> Void
    let pull: () -> Void
    let push: () -> Void
    let close: () -> Void
}

struct RepoCommands: Commands {
    @FocusedValue(\.repoActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Appearance.key) private var darkMode = true

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Dark Mode", isOn: $darkMode)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .onChange(of: darkMode) { _, _ in Appearance.apply() }
        }
        CommandGroup(after: .newItem) {
            Button("Open Repository…") {
                if let url = chooseRepositoryFolder() {
                    Task {
                        if let top = await GitRepository.findTopLevel(of: url) {
                            openWindow(value: top.path)
                        }
                    }
                }
            }
            .keyboardShortcut("o")
            Button("Close Repository") { actions?.close() }
                .disabled(actions == nil)
        }
        CommandMenu("Repository") {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
            Divider()
            Button("Commit…") { actions?.commit() }
                .keyboardShortcut("k")
            Divider()
            Button("Fetch") { actions?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Pull") { actions?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Push") { actions?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
